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

    /// Looks for what the tool says about its own rate limits, without touching
    /// the event scan's offsets.
    ///
    /// Only called when the cache has never seen one. Scanning is incremental,
    /// so a build that starts reading a new kind of record would otherwise show
    /// nothing at all until the tool happened to write another — days, for a
    /// record that only appears when a limit is actually hit.
    func backfillLimits(cache: ScanCache)
}

extension UsageProvider {
    /// Reads the tail of the most recently written logs and hands every line to
    /// `handler`.
    ///
    /// Bounded on purpose: this runs outside the incremental scan, so it pays
    /// for itself only if it stays cheap. A rate-limit reading older than the
    /// last few megabytes of transcript has been superseded or has already
    /// reset, which makes the tail the only part worth reading.
    func scanRecentTails(
        of files: [URL], newest: Int = 8, bytes: UInt64 = 512 * 1024,
        handler: (Data) -> Void
    ) {
        let recent = files
            .map { url -> (URL, Date, UInt64) in
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                return (
                    url,
                    (attrs?[.modificationDate] as? Date) ?? .distantPast,
                    (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
                )
            }
            .sorted { $0.1 > $1.1 }
            .prefix(newest)

        for (url, _, size) in recent {
            JSONLReader.stream(path: url.path, from: size > bytes ? size - bytes : 0, handler: handler)
        }
    }
}

/// Everything the aggregator still needs about events too old to keep one by one.
struct UsageArchive: Sendable, Codable {
    var counts = TokenCounts()
    var eventCount = 0
    /// Start-of-day stamps, which is all the streak calculation needs.
    var days: Set<Date> = []
    var sessions: Set<String> = []
    /// Per-project totals, so the breakdown still spans aged-out history.
    var projects: [String: TokenCounts] = [:]

    init() {}

    init(
        counts: TokenCounts, eventCount: Int, days: Set<Date>,
        sessions: Set<String>, projects: [String: TokenCounts]
    ) {
        self.counts = counts
        self.eventCount = eventCount
        self.days = days
        self.sessions = sessions
        self.projects = projects
    }

    /// Decoded leniently so that adding a field does not invalidate every cache
    /// written by an earlier version and force a full rescan.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        counts = try container.decodeIfPresent(TokenCounts.self, forKey: .counts) ?? TokenCounts()
        eventCount = try container.decodeIfPresent(Int.self, forKey: .eventCount) ?? 0
        days = try container.decodeIfPresent(Set<Date>.self, forKey: .days) ?? []
        sessions = try container.decodeIfPresent(Set<String>.self, forKey: .sessions) ?? []
        projects = try container.decodeIfPresent([String: TokenCounts].self, forKey: .projects) ?? [:]
    }

    mutating func absorb(_ event: UsageEvent, calendar: Calendar) {
        counts += event.counts
        eventCount += 1
        days.insert(calendar.startOfDay(for: event.timestamp))
        sessions.insert(event.sessionID)
        if let project = event.project {
            projects[project, default: TokenCounts()] += event.counts
        }
    }

    static func + (lhs: UsageArchive, rhs: UsageArchive) -> UsageArchive {
        var merged = lhs.projects
        for (name, counts) in rhs.projects {
            merged[name, default: TokenCounts()] += counts
        }
        return UsageArchive(
            counts: lhs.counts + rhs.counts,
            eventCount: lhs.eventCount + rhs.eventCount,
            days: lhs.days.union(rhs.days),
            sessions: lhs.sessions.union(rhs.sessions),
            projects: merged
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
        /// The working directory this log belongs to. Codex writes it in a
        /// header line, which an incremental resume skips past, so it has to be
        /// remembered rather than re-read.
        var project: String?

        init(offset: UInt64, size: Int64, modified: Date) {
            self.offset = offset
            self.size = size
            self.modified = modified
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            offset = try container.decode(UInt64.self, forKey: .offset)
            size = try container.decode(Int64.self, forKey: .size)
            modified = try container.decode(Date.self, forKey: .modified)
            archive = try container.decodeIfPresent(UsageArchive.self, forKey: .archive) ?? UsageArchive()
            project = try container.decodeIfPresent(String.self, forKey: .project)
        }
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
        var limits: [RateWindow] = []

        init(files: [String: FileState], events: [String: [StoredEvent]], limits: [RateWindow]) {
            self.files = files
            self.events = events
            self.limits = limits
        }

        /// Decoded field by field like everything else that is persisted here.
        /// A cache that fails to decode is not merely a rescan: the archive of
        /// everything older than the retention window lives in it, and that is
        /// the tamer's all-time total.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            files = try c.decodeIfPresent([String: FileState].self, forKey: .files) ?? [:]
            events = try c.decodeIfPresent([String: [StoredEvent]].self, forKey: .events) ?? [:]
            limits = try c.decodeIfPresent([RateWindow].self, forKey: .limits) ?? []
        }
    }

    private let lock = NSLock()
    private var files: [String: FileState] = [:]
    private var events: [String: [StoredEvent]] = [:]
    private var limits: [RateWindow] = []
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
        limits = payload.limits
    }

    /// The last thing each tool said about each of its rate-limit windows.
    ///
    /// Kept in the cache rather than recomputed, because scanning is incremental:
    /// a refresh that finds no new bytes reads no records, and the reading from
    /// an hour ago is still the most recent one the tool wrote.
    var knownLimits: [RateWindow] {
        lock.lock(); defer { lock.unlock() }
        return limits.sorted { ($0.minutes ?? .max) < ($1.minutes ?? .max) }
    }

    /// Records a window, the newest observation of it winning.
    ///
    /// Two readings are of the same window when they cover the same length of
    /// time and carry the same name — not merely when they share an id. One tool
    /// can describe its five-hour window in several files under several
    /// spellings, and a stored reading outlives the build that wrote it, so
    /// keying on the id alone leaves the same bar drawn twice from two sources
    /// of different ages.
    func recordLimit(_ window: RateWindow) {
        lock.lock(); defer { lock.unlock() }

        func isSameWindow(_ other: RateWindow) -> Bool {
            if other.kind == window.kind { return true }
            guard let minutes = window.minutes, other.minutes == minutes else { return false }
            return other.title == window.title
        }

        // Every match goes, not just the first: a cache written by an earlier
        // build can already hold two rows for one window, and replacing one of
        // them would leave the pane drawing the pair.
        let matches = limits.filter(isSameWindow)
        let newest = matches.compactMap(\.observedAt).max()
        if let newest, let observed = window.observedAt, observed < newest { return }
        limits.removeAll(where: isSameWindow)
        limits.append(window)
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

    /// The project a log file belongs to, learned on a previous pass.
    func projectHint(for path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return files[path]?.project
    }

    func setProjectHint(_ project: String, for path: String) {
        lock.lock(); defer { lock.unlock() }
        var state = files[path] ?? FileState(offset: 0, size: 0, modified: Date())
        state.project = project
        files[path] = state
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
        let payload = Payload(files: files, events: events, limits: limits)
        lock.unlock()
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
