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
            guard let event = Self.parse(line: line, fallbackSession: url.deletingPathExtension().lastPathComponent)
            else { return }
            fresh.append(event)
        }

        cache.record(path: path, offset: end, newEvents: fresh)
        return base + fresh
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
