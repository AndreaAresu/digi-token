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
