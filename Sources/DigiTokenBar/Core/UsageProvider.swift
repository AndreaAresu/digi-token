import Foundation

/// A source of local token usage.
///
/// Providers only ever read files the tool already wrote to disk. Nothing here
/// makes a network call or needs an API key — a new tool is added by writing one
/// conformance and appending it to `UsageMonitor`, never by branching on a tool
/// name in the aggregation or partner code.
protocol UsageProvider: Sendable {
    var id: ProviderID { get }

    /// Whether the tool looks installed on this machine.
    func isAvailable() -> Bool

    /// Usage events inside the cache's retention window. Anything older has been
    /// folded into `cache.archive`. Implementations use `ScanCache` so repeated
    /// calls only read the bytes appended since last time.
    func scan(cache: ScanCache) -> [UsageEvent]
}

/// Everything the aggregator still needs about events too old to keep one by one.
struct UsageArchive: Sendable, Codable {
    var counts = TokenCounts()
    var eventCount = 0
    /// Start-of-day stamps, which is all the streak calculation needs.
    var days: Set<Date> = []
    var sessions: Set<String> = []

    mutating func absorb(_ event: UsageEvent, calendar: Calendar) {
        counts += event.counts
        eventCount += 1
        days.insert(calendar.startOfDay(for: event.timestamp))
        sessions.insert(event.sessionID)
    }

    static func + (lhs: UsageArchive, rhs: UsageArchive) -> UsageArchive {
        UsageArchive(
            counts: lhs.counts + rhs.counts,
            eventCount: lhs.eventCount + rhs.eventCount,
            days: lhs.days.union(rhs.days),
            sessions: lhs.sessions.union(rhs.sessions)
        )
    }
}

/// Remembers how far into each log file we read, so a refresh costs only the
/// bytes the agent appended since last time.
///
/// Individual events are kept only inside a retention window. Beyond it they are
/// folded into an `UsageArchive`: all-time totals, active days and session
/// counts survive, but the cache stops growing without bound. A tamer a year
/// into daily use would otherwise be carrying a hundred-megabyte JSON file that
/// is rewritten on every refresh.
final class ScanCache: @unchecked Sendable {
    /// How long individual events are kept. Long enough for every rollup the UI
    /// shows (today, week, month) and for the care profile's window.
    static let retentionDays = 120

    private struct FileState: Codable {
        var offset: UInt64
        var size: Int64
        var modified: Date
        var archive = UsageArchive()
    }

    private struct StoredEvent: Codable {
        let timestamp: Date
        let model: String
        let counts: TokenCounts
        let dedupKey: String
        let sessionID: String
        let project: String?

        init(_ event: UsageEvent) {
            timestamp = event.timestamp
            model = event.model
            counts = event.counts
            dedupKey = event.dedupKey
            sessionID = event.sessionID
            project = event.project
        }

        var event: UsageEvent {
            UsageEvent(
                timestamp: timestamp, model: model, counts: counts,
                dedupKey: dedupKey, sessionID: sessionID, project: project
            )
        }
    }

    private struct Payload: Codable {
        var files: [String: FileState]
        var events: [String: [StoredEvent]]
    }

    private let lock = NSLock()
    private var files: [String: FileState] = [:]
    private var events: [String: [StoredEvent]] = [:]
    private let url: URL
    private let calendar: Calendar

    init(url: URL, calendar: Calendar = .current) {
        self.url = url
        self.calendar = calendar
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return }
        files = payload.files
        events = payload.events
    }

    /// Aggregated totals for everything older than the retention window.
    var archive: UsageArchive {
        lock.lock(); defer { lock.unlock() }
        return files.values.reduce(UsageArchive()) { $0 + $1.archive }
    }

    /// Byte offset to resume `path` from. Returns 0 when the file shrank or was
    /// replaced — a truncated log means our cached events no longer describe it.
    func resumeOffset(for path: String) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        guard let state = files[path] else { return 0 }
        if currentSize(path) < state.size {
            files[path] = nil
            events[path] = nil
            return 0
        }
        return state.offset
    }

    /// Retained events already known for `path` from earlier scans.
    func cachedEvents(for path: String) -> [UsageEvent] {
        lock.lock(); defer { lock.unlock() }
        return events[path]?.map(\.event) ?? []
    }

    func record(path: String, offset: UInt64, newEvents: [UsageEvent]) {
        lock.lock(); defer { lock.unlock() }
        var state = files[path] ?? FileState(offset: 0, size: 0, modified: Date())
        state.offset = offset
        state.size = currentSize(path)
        state.modified = Date()
        files[path] = state
        events[path, default: []].append(contentsOf: newEvents.map(StoredEvent.init))
        prune(path)
    }

    /// Whether `path` changed since we last recorded it — lets a provider skip
    /// opening files entirely on a refresh where nothing happened.
    func isUnchanged(path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let state = files[path] else { return false }
        return currentSize(path) == state.size
    }

    /// Moves events past the retention window into the file's archive.
    /// Callers already hold the lock.
    private func prune(_ path: String) {
        guard var stored = events[path], !stored.isEmpty else { return }
        guard let cutoff = calendar.date(
            byAdding: .day, value: -Self.retentionDays, to: Date()
        ) else { return }
        guard stored.contains(where: { $0.timestamp < cutoff }) else { return }

        var state = files[path] ?? FileState(offset: 0, size: 0, modified: Date())
        var kept: [StoredEvent] = []
        kept.reserveCapacity(stored.count)
        for item in stored where item.timestamp >= cutoff {
            kept.append(item)
        }
        for item in stored where item.timestamp < cutoff {
            state.archive.absorb(item.event, calendar: calendar)
        }
        stored = kept
        events[path] = stored
        files[path] = state
    }

    private func currentSize(_ path: String) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Drops files that no longer exist, so a deleted project stops costing disk.
    func forgetMissingFiles() {
        lock.lock(); defer { lock.unlock() }
        for path in files.keys where !FileManager.default.fileExists(atPath: path) {
            // The totals still belong in the all-time figure even though the log
            // is gone, so the archive is merged into a tombstone rather than lost.
            if let state = files[path], state.archive.eventCount > 0 {
                var tombstone = files[Self.tombstoneKey]
                    ?? FileState(offset: 0, size: 0, modified: Date())
                tombstone.archive = tombstone.archive + state.archive
                files[Self.tombstoneKey] = tombstone
            }
            files[path] = nil
            events[path] = nil
        }
    }

    /// Real keys are absolute paths, so a name without a leading slash cannot
    /// collide with one.
    private static let tombstoneKey = "__deleted__"

    func persist() {
        lock.lock()
        let payload = Payload(files: files, events: events)
        lock.unlock()
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
