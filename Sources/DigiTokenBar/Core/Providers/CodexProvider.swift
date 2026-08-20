import Foundation

/// Reads Codex CLI rollout logs from `~/.codex/sessions/YYYY/MM/DD/`.
///
/// Codex reports usage differently from Claude Code in two ways that matter:
/// `input_tokens` already *includes* the cached portion, and each `token_count`
/// event carries both a running total and the delta for the turn. We take the
/// delta and subtract the cached part so both providers mean the same thing by
/// "input".
struct CodexProvider: UsageProvider {
    let id = ProviderID.codex

    static func sessionRoots() -> [URL] {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots: [URL] = []
        if let configured = env["CODEX_HOME"], !configured.isEmpty {
            roots.append(URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath))
        }
        roots.append(home.appendingPathComponent(".codex"))

        var seen = Set<String>()
        return roots
            .map { $0.appendingPathComponent("sessions") }
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func isAvailable() -> Bool { !Self.sessionRoots().isEmpty }

    func scan(cache: ScanCache) -> [UsageEvent] {
        var events: [UsageEvent] = []
        for root in Self.sessionRoots() {
            guard let walker = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in walker where url.pathExtension == "jsonl" {
                events.append(contentsOf: scanFile(url, cache: cache))
            }
        }
        return events
    }

    func backfillLimits(cache: ScanCache) {
        var files: [URL] = []
        for root in Self.sessionRoots() {
            guard let walker = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                files.append(url)
            }
        }
        scanRecentTails(of: files) { line in
            for window in Self.rateWindows(in: line) { cache.recordLimit(window) }
        }
    }

    private func scanFile(_ url: URL, cache: ScanCache) -> [UsageEvent] {
        let path = url.path
        let cached = cache.cachedEvents(for: path)
        if cache.isUnchanged(path: path) { return cached }

        let start = cache.resumeOffset(for: path)
        let base = start == 0 ? [] : cached
        let session = url.deletingPathExtension().lastPathComponent

        // Two consecutive turns can bill identical token counts, so identity
        // comes from position in the file rather than from the values.
        var sequence = base.count
        var fresh: [UsageEvent] = []

        // Codex names the working directory in a header line and again in every
        // turn context, but never on the usage events themselves. We carry the
        // most recent one forward, seeded from the cache so a resumed scan that
        // starts mid-file still knows which project it is reading.
        var project = cache.projectHint(for: path)

        let end = JSONLReader.stream(path: path, from: start) { line in
            for window in Self.rateWindows(in: line) { cache.recordLimit(window) }
            if let directory = Self.workingDirectory(in: line) {
                project = URL(fileURLWithPath: directory).lastPathComponent
                if let project { cache.setProjectHint(project, for: path) }
                return
            }
            guard var event = Self.parse(
                line: line, session: session, sequence: sequence, path: path
            ) else { return }
            event.project = project
            sequence += 1
            fresh.append(event)
        }

        cache.record(path: path, offset: end, newEvents: fresh)
        return base + fresh
    }

    /// Pulls `cwd` out of a `session_meta` or `turn_context` record.
    static func workingDirectory(in line: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String,
              type == "session_meta" || type == "turn_context"
        else { return nil }

        // `session_meta` nests its fields under `payload`; `turn_context` does
        // in some versions and not in others.
        if let payload = object["payload"] as? [String: Any],
           let cwd = payload["cwd"] as? String, !cwd.isEmpty {
            return cwd
        }
        if let cwd = object["cwd"] as? String, !cwd.isEmpty { return cwd }
        return nil
    }

    /// Codex writes its own rate-limit state onto every `token_count` event:
    /// how much of each window is used, how long the window is, and when it
    /// rolls over. It is the tool's own reading, so the app can show a real
    /// gauge here rather than an estimate.
    ///
    /// `primary` and `secondary` are whatever the account has — a monthly
    /// allowance, a weekly one, both — so they are read positionally and named
    /// from `window_minutes` rather than assumed.
    static func rateWindows(in line: Data) -> [RateWindow] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let info = payload["info"] as? [String: Any] ?? payload as [String: Any]?,
              let limits = (info["rate_limits"] ?? payload["rate_limits"]) as? [String: Any]
        else { return [] }

        let observed = (object["timestamp"] as? String).flatMap(TimestampParser.parse)

        return ["primary", "secondary"].compactMap { slot -> RateWindow? in
            guard let window = limits[slot] as? [String: Any] else { return nil }
            let minutes = window["window_minutes"] as? Int
            // The kind has to be stable across observations or the cache would
            // keep two rows for the same window; the length is what identifies
            // it, with the slot as a fallback when the tool omits it.
            let kind = minutes.map { "codex_\($0)" } ?? "codex_\(slot)"
            guard let percent = window["used_percent"] as? Double else { return nil }
            return RateWindow(
                kind: kind,
                usedFraction: max(0, min(1, percent / 100)),
                minutes: minutes,
                resetsAt: (window["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                    ?? (window["resets_at"] as? Int).map { Date(timeIntervalSince1970: Double($0)) },
                blocked: percent >= 100,
                observedAt: observed
            )
        }
    }

    static func parse(line: Data, session: String, sequence: Int, path: String) -> UsageEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any]
        else { return nil }

        let rawInput = last["input_tokens"] as? Int ?? 0
        let cachedInput = last["cached_input_tokens"] as? Int ?? 0
        let counts = TokenCounts(
            input: max(0, rawInput - cachedInput),
            output: last["output_tokens"] as? Int ?? 0,
            cacheCreation: last["cache_write_input_tokens"] as? Int ?? 0,
            cacheRead: cachedInput
        )
        guard counts.total > 0 else { return nil }

        guard let stamp = object["timestamp"] as? String,
              let date = TimestampParser.parse(stamp)
        else { return nil }

        return UsageEvent(
            timestamp: date,
            model: (info["model"] as? String) ?? "codex",
            counts: counts,
            dedupKey: "\(path)#\(sequence)",
            sessionID: session,
            project: nil
        )
    }
}
