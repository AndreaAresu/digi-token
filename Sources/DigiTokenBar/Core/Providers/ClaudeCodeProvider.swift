import Foundation

/// Reads Claude Code's local transcripts.
///
/// Every assistant turn is one `.jsonl` record carrying `message.usage`. The
/// same turn can appear in more than one file because Claude Code forks a
/// transcript when a conversation is resumed or rewound, so counting is keyed on
/// `requestId` + `message.id` rather than on file position.
struct ClaudeCodeProvider: UsageProvider {
    let id = ProviderID.claudeCode

    /// Config lives in `~/.claude` by default, `~/.config/claude` under XDG, and
    /// wherever `CLAUDE_CONFIG_DIR` points when the user moved it.
    static func projectRoots() -> [URL] {
        var roots: [URL] = []
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser

        if let configured = env["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            for part in configured.split(separator: ",") {
                let path = part.trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty else { continue }
                roots.append(URL(fileURLWithPath: NSString(string: path).expandingTildeInPath))
            }
        }
        roots.append(home.appendingPathComponent(".claude"))
        roots.append(home.appendingPathComponent(".config/claude"))

        var seen = Set<String>()
        return roots
            .map { $0.appendingPathComponent("projects") }
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func isAvailable() -> Bool { !Self.projectRoots().isEmpty }

    func scan(cache: ScanCache) -> [UsageEvent] {
        // Read every time rather than only on a backfill: `.claude.json` is
        // rewritten by the CLI on its own schedule, with no relation to the
        // transcripts this scan resumes through.
        for file in Self.configFiles() {
            guard let data = try? Data(contentsOf: file) else { continue }
            for window in Self.cachedUtilization(in: data) { cache.recordLimit(window) }
        }
        // The desktop app samples the same two windows every few minutes, which
        // is a great deal fresher than the CLI's cached copy. Both write the
        // same canonical ids, so the newest reading wins on its own.
        for file in Self.planUsageFiles() {
            guard let data = try? Data(contentsOf: file) else { continue }
            for window in Self.planUsage(in: data) { cache.recordLimit(window) }
        }

        var events: [UsageEvent] = []
        for root in Self.projectRoots() {
            for file in Self.transcripts(in: root) {
                events.append(contentsOf: scanFile(file, cache: cache))
            }
        }
        return events
    }

    private static func transcripts(in root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            files.append(url)
        }
        return files
    }

    /// One id per window, whatever wrote it down.
    ///
    /// The five-hour window is reported by three different files in three
    /// different spellings — `session`, `five_hour`, `fh`. They are the same
    /// window, and if they arrive under different names the cache keeps three
    /// rows and the pane draws the same bar three times.
    static func canonicalKind(minutes: Int?, scope: String?, fallback: String) -> String {
        let base: String
        switch minutes {
        case 300: base = "claude_five_hour"
        case 10_080: base = "claude_seven_day"
        case .some(let m): base = "claude_\(m)"
        case nil: base = "claude_\(fallback)"
        }
        return scope.map { "\(base)_\($0)" } ?? base
    }

    /// The live plan-usage gauge, sampled by the Claude desktop app.
    ///
    /// `plan-usage-history.json` is a rolling log of samples — `fh` is the
    /// five-hour window's utilisation, `sd` the seven-day one, both as whole
    /// percentages, written roughly every quarter of an hour while the app is
    /// running. It is the same figure the app shows under "Plan usage limits",
    /// and it is far fresher than the CLI's cached copy, which is only rewritten
    /// when the CLI itself goes and fetches usage.
    ///
    /// Only the newest sample is used. The rest is history the app keeps for its
    /// own graph, and reading it would be reconstructing something the tool
    /// already draws.
    ///
    /// No reset time is recorded here, so freshness is judged by the age of the
    /// sample against the window it describes — see `RateWindow.isCurrent`.
    ///
    /// It is tempting to derive the reset from the samples: the utilisation
    /// falling between two of them marks a rollover, so the window would end
    /// five hours after that. It was tried against this machine's history and
    /// it is wrong. The last rollover in the file ran 100% → 0% between 04:02
    /// and 04:23, which puts the end of that window at 09:23 — while Claude
    /// itself was reporting the window resetting at about 13:58. Whatever the
    /// five-hour allowance is measured over, it is not a fixed block starting at
    /// the last reset, so nothing here pretends to know when it ends.
    static func planUsageFiles() -> [URL] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        return support
            .map { $0.appendingPathComponent("Claude/plan-usage-history.json") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func planUsage(in data: Data) -> [RateWindow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = root["samples"] as? [[String: Any]],
              let last = samples.last,
              let stamp = last["t"] as? Double,
              let used = last["u"] as? [String: Any]
        else { return [] }

        let observed = Date(timeIntervalSince1970: stamp / 1000)

        func window(_ key: String, minutes: Int) -> RateWindow? {
            guard let percent = used[key] as? Double ?? (used[key] as? Int).map(Double.init)
            else { return nil }
            return RateWindow(
                kind: canonicalKind(minutes: minutes, scope: nil, fallback: key),
                usedFraction: max(0, min(1, percent / 100)),
                minutes: minutes,
                resetsAt: nil,
                blocked: percent >= 100,
                observedAt: observed
            )
        }

        return [window("fh", minutes: 300), window("sd", minutes: 10_080)].compactMap { $0 }
    }

    /// Claude Code's own copy of what `/usage` shows: how much of the five-hour
    /// and weekly windows is used, and when each resets.
    ///
    /// It caches this in `~/.claude.json` under `cachedUsageUtilization`, which
    /// is the same figure the CLI prints — a real gauge, not an estimate, and
    /// still entirely on this machine. The transcripts carry nothing like it;
    /// they only record the moment a limit actually stopped a turn.
    ///
    /// The catch is freshness: the CLI refreshes this when it fetches usage, not
    /// on a timer, so a reading can be days old. `fetchedAtMs` is carried
    /// through as `observedAt` and every window keeps its own `resets_at`, so a
    /// stale one is shown as stale and an expired one is not shown at all.
    static func configFiles() -> [URL] {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        var files = [home.appendingPathComponent(".claude.json")]

        // A moved config dir keeps the file beside the directory it names.
        if let configured = env["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            for part in configured.split(separator: ",") {
                let path = part.trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty else { continue }
                let dir = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
                files.append(dir.appendingPathComponent(".claude.json"))
                files.append(dir.deletingLastPathComponent().appendingPathComponent(".claude.json"))
            }
        }

        var seen = Set<String>()
        return files
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Reads the cached utilization out of a `.claude.json` payload.
    ///
    /// Prefers the normalised `limits` array, which names each window and its
    /// scope, and falls back to the individual keys for versions that wrote only
    /// those. Windows the account does not have come through as null and are
    /// skipped rather than shown as zero — "0% used" and "no such limit" are
    /// different statements.
    static func cachedUtilization(in data: Data) -> [RateWindow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cached = root["cachedUsageUtilization"] as? [String: Any],
              let utilization = cached["utilization"] as? [String: Any]
        else { return [] }

        let observed = (cached["fetchedAtMs"] as? Double).map {
            Date(timeIntervalSince1970: $0 / 1000)
        }

        func window(
            kind: String, percent: Double, resets: String?, minutes: Int?, scope: String?
        ) -> RateWindow {
            RateWindow(
                kind: canonicalKind(minutes: minutes, scope: scope, fallback: kind),
                usedFraction: max(0, min(1, percent / 100)),
                minutes: minutes,
                resetsAt: resets.flatMap(TimestampParser.parse),
                blocked: percent >= 100,
                observedAt: observed,
                // Only when the tool says the window covers one model; the plain
                // windows are left to be named after their length.
                title: scope.map { "weekly limit · \($0.capitalized)" }
            )
        }

        if let limits = utilization["limits"] as? [[String: Any]], !limits.isEmpty {
            return limits.compactMap { entry in
                guard let percent = entry["percent"] as? Double ?? (entry["percent"] as? Int).map(Double.init)
                else { return nil }
                let kind = (entry["kind"] as? String) ?? "limit"
                let scope = entry["scope"] as? String
                return window(
                    kind: scope.map { "\(kind)_\($0)" } ?? kind,
                    percent: percent,
                    resets: entry["resets_at"] as? String,
                    minutes: Self.windowMinutes(forGroup: entry["group"] as? String, kind: kind),
                    scope: scope
                )
            }
        }

        return utilization.compactMap { key, value in
            guard let entry = value as? [String: Any],
                  let percent = entry["utilization"] as? Double
                    ?? (entry["utilization"] as? Int).map(Double.init)
            else { return nil }
            // `seven_day_opus` is the weekly window for one model; the suffix is
            // the scope the newer shape spells out.
            let scope = key.hasPrefix("seven_day_") ? String(key.dropFirst("seven_day_".count)) : nil
            return window(
                kind: key,
                percent: percent,
                resets: entry["resets_at"] as? String,
                minutes: Self.windowMinutes(for: key),
                scope: scope
            )
        }
        .sorted { ($0.minutes ?? .max) < ($1.minutes ?? .max) }
    }

    private static func windowMinutes(forGroup group: String?, kind: String) -> Int? {
        switch group ?? kind {
        case "session", "five_hour": 300
        case "weekly", "weekly_all", "seven_day": 10_080
        case "daily": 1_440
        default: windowMinutes(for: kind)
        }
    }

    func backfillLimits(cache: ScanCache) {
        let files = Self.projectRoots().flatMap { Self.transcripts(in: $0) }
        scanRecentTails(of: files) { line in
            if let window = Self.rateWindow(in: line) { cache.recordLimit(window) }
        }
    }

    private func scanFile(_ url: URL, cache: ScanCache) -> [UsageEvent] {
        let path = url.path
        let cached = cache.cachedEvents(for: path)
        if cache.isUnchanged(path: path) { return cached }

        let start = cache.resumeOffset(for: path)
        // A resume offset of 0 with cached events means the file was truncated
        // or replaced, so the cached events describe bytes that no longer exist.
        let base = start == 0 ? [] : cached

        var fresh: [UsageEvent] = []
        let end = JSONLReader.stream(path: path, from: start) { line in
            if let window = Self.rateWindow(in: line) { cache.recordLimit(window) }
            guard let event = Self.parse(line: line, fallbackSession: url.deletingPathExtension().lastPathComponent)
            else { return }
            fresh.append(event)
        }

        cache.record(path: path, offset: end, newEvents: fresh)
        return base + fresh
    }

    /// Claude Code records `quotaLimits` at the moment a limit actually stops a
    /// turn — the type of window, and when it clears.
    ///
    /// It is an event, not a gauge: unlike Codex, nothing in these logs says how
    /// much of the allowance is left while there is still some left. That is the
    /// honest shape of what is available, and the pane shows a refusal and its
    /// reset time rather than inventing a percentage to sit beside it.
    static func rateWindow(in line: Data) -> RateWindow? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let quota = object["quotaLimits"] as? [String: Any],
              let kind = quota["rateLimitType"] as? String
        else { return nil }

        let resets = (quota["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
            ?? (quota["resetsAt"] as? Int).map { Date(timeIntervalSince1970: Double($0)) }
        let observed = (object["timestamp"] as? String).flatMap(TimestampParser.parse)

        // Only a refusal is worth recording. A record saying the request went
        // through says nothing about how close to the edge it was.
        let status = (quota["status"] as? String) ?? "rejected"
        guard status != "allowed" else { return nil }

        return RateWindow(
            kind: kind,
            usedFraction: nil,
            minutes: Self.windowMinutes(for: kind),
            resetsAt: resets,
            blocked: true,
            observedAt: observed
        )
    }

    /// The window lengths Claude Code names, so the pane can call a `five_hour`
    /// limit a five-hour limit without every reader having to know the spelling.
    private static func windowMinutes(for kind: String) -> Int? {
        switch kind {
        case "five_hour": 300
        case "seven_day", "weekly": 10_080
        case "daily": 1_440
        default: nil
        }
    }

    static func parse(line: Data, fallbackSession: String) -> UsageEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        let counts = TokenCounts(
            input: usage["input_tokens"] as? Int ?? 0,
            output: usage["output_tokens"] as? Int ?? 0,
            cacheCreation: usage["cache_creation_input_tokens"] as? Int ?? 0,
            cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0
        )
        guard counts.total > 0 else { return nil }

        guard let stamp = object["timestamp"] as? String,
              let date = TimestampParser.parse(stamp)
        else { return nil }

        let requestID = object["requestId"] as? String
        let messageID = message["id"] as? String
        // Prefer the pair; a record missing both still gets a stable identity
        // from its uuid, which Claude Code preserves across transcript forks.
        let dedup: String
        if let requestID, let messageID {
            dedup = "\(requestID):\(messageID)"
        } else if let uuid = object["uuid"] as? String {
            dedup = uuid
        } else {
            return nil
        }

        return UsageEvent(
            timestamp: date,
            model: message["model"] as? String ?? "unknown",
            counts: counts,
            dedupKey: dedup,
            sessionID: object["sessionId"] as? String ?? fallbackSession,
            project: (object["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        )
    }
}
