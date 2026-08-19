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

        let end = JSONLReader.stream(path: path, from: start) { line in
            guard let event = Self.parse(
                line: line, session: session, sequence: sequence, path: path
            ) else { return }
            sequence += 1
            fresh.append(event)
        }

        cache.record(path: path, offset: end, newEvents: fresh)
        return base + fresh
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
