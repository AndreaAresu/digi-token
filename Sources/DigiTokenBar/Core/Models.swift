import Foundation

/// Raw token counts for a single assistant turn, kept separate because the
/// partner's growth reads them differently: cached reads are cheap and signal an
/// efficient tamer, fresh input is expensive and makes the partner gain weight.
struct TokenCounts: Sendable, Hashable, Codable {
    var input: Int = 0
    var output: Int = 0
    var cacheCreation: Int = 0
    var cacheRead: Int = 0
    /// The share of `cacheCreation` written with a one-hour TTL, which bills at
    /// twice the input rate instead of 1.25×. A subset, never an addition — it
    /// stays out of `total` and `billable` for exactly that reason.
    var cacheCreation1h: Int = 0

    /// What the provider actually billed against the context window.
    var total: Int { input + output + cacheCreation + cacheRead }

    /// Tokens that cost full price — the ones that feed digivolution.
    var billable: Int { input + output + cacheCreation }

    /// Cache writes on the cheaper five-minute TTL.
    var cacheCreation5m: Int { max(0, cacheCreation - cacheCreation1h) }

    init(
        input: Int = 0, output: Int = 0, cacheCreation: Int = 0,
        cacheRead: Int = 0, cacheCreation1h: Int = 0
    ) {
        self.input = input
        self.output = output
        self.cacheCreation = cacheCreation
        self.cacheRead = cacheRead
        self.cacheCreation1h = cacheCreation1h
    }

    /// Decoded field by field: these are persisted inside the scan cache, and a
    /// cache that will not decode takes the all-time archive down with it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decodeIfPresent(Int.self, forKey: .input) ?? 0
        output = try c.decodeIfPresent(Int.self, forKey: .output) ?? 0
        cacheCreation = try c.decodeIfPresent(Int.self, forKey: .cacheCreation) ?? 0
        cacheRead = try c.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
        cacheCreation1h = try c.decodeIfPresent(Int.self, forKey: .cacheCreation1h) ?? 0
    }

    static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheCreation: lhs.cacheCreation + rhs.cacheCreation,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheCreation1h: lhs.cacheCreation1h + rhs.cacheCreation1h
        )
    }

    static func += (lhs: inout TokenCounts, rhs: TokenCounts) { lhs = lhs + rhs }
}

/// One assistant response read out of a local log. The `dedupKey` matters:
/// agents rewrite and fork their transcripts, so the same response shows up in
/// several files and must only be counted once.
struct UsageEvent: Sendable, Hashable {
    let timestamp: Date
    let model: String
    let counts: TokenCounts
    let dedupKey: String
    let sessionID: String
    /// The directory the agent was working in, where the tool records it.
    /// Codex only names it in separate header records, so the provider fills
    /// this in after parsing rather than at construction.
    var project: String?
}

/// An AI coding tool we can read usage from.
enum ProviderID: String, Sendable, Codable, CaseIterable {
    case claudeCode = "claude_code"
    case codex

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// A rate-limit window. Claude and Codex both meter on a rolling 5-hour block;
/// the partner treats a window that hits the cap as overwork and one that is
/// opened then abandoned as neglect.
struct UsageBlock: Sendable, Hashable {
    let start: Date
    let end: Date
    var counts: TokenCounts
    var lastActivity: Date

    var isActive: Bool { Date() < end }
    var elapsed: TimeInterval { min(Date(), end).timeIntervalSince(start) }
    var remaining: TimeInterval { max(0, end.timeIntervalSince(Date())) }

    /// Tokens per hour over the elapsed portion of the window.
    var burnRate: Double {
        let hours = max(elapsed / 3600, 1.0 / 60)
        return Double(counts.billable) / hours
    }

    /// Where the window lands if the current burn rate holds to the end.
    var projectedTotal: Int {
        guard isActive else { return counts.billable }
        return counts.billable + Int(burnRate * remaining / 3600)
    }
}

/// A rate-limit window, exactly as the tool itself recorded it.
///
/// Nothing here is derived from token counts. Neither tool publishes its quota
/// in tokens, so a "78% of your limit" the app worked out for itself would be a
/// number nobody could check — which is the one thing this app does not do. A
/// window appears only when the tool wrote it down, and stays absent otherwise.
struct RateWindow: Sendable, Hashable, Codable {
    /// How the tool names it — `five_hour`, `weekly`, and so on.
    var kind: String
    /// Share of the allowance used, 0...1, when the tool reports a gauge.
    var usedFraction: Double?
    /// Window length in minutes, when reported.
    var minutes: Int?
    /// When the window rolls over.
    var resetsAt: Date?
    /// True when this is a refusal the tool recorded rather than a gauge —
    /// the limit was actually hit, not merely approached.
    var blocked = false
    /// When the tool wrote this down. A gauge is only as current as its record,
    /// and saying so is the difference between a reading and a guess.
    var observedAt: Date?
    /// True when the reset time was worked out rather than reported — it is
    /// shown with a "~" and, crucially, is never used to decide whether the
    /// reading still counts. A derived time that is ten minutes early would
    /// otherwise blank a perfectly good gauge.
    var resetIsApproximate = false
    /// A name from the tool where it knows a better one than the window length
    /// gives — a weekly limit that applies to one model only, say. Naming stays
    /// with the provider so the pane never has to know whose window it is.
    var title: String?

    init(
        kind: String, usedFraction: Double? = nil, minutes: Int? = nil,
        resetsAt: Date? = nil, blocked: Bool = false, observedAt: Date? = nil,
        title: String? = nil, resetIsApproximate: Bool = false
    ) {
        self.resetIsApproximate = resetIsApproximate
        self.kind = kind
        self.usedFraction = usedFraction
        self.minutes = minutes
        self.resetsAt = resetsAt
        self.blocked = blocked
        self.observedAt = observedAt
        self.title = title
    }

    /// Decoded field by field: this is persisted in the scan cache, and a cache
    /// that will not decode takes the all-time archive down with it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        usedFraction = try c.decodeIfPresent(Double.self, forKey: .usedFraction)
        minutes = try c.decodeIfPresent(Int.self, forKey: .minutes)
        resetsAt = try c.decodeIfPresent(Date.self, forKey: .resetsAt)
        blocked = try c.decodeIfPresent(Bool.self, forKey: .blocked) ?? false
        observedAt = try c.decodeIfPresent(Date.self, forKey: .observedAt)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        resetIsApproximate = try c.decodeIfPresent(Bool.self, forKey: .resetIsApproximate) ?? false
    }

    /// A name for the window, taken from its length where the tool gave one so
    /// that a tool naming a window differently still reads correctly.
    var label: String {
        if let title { return title }
        return switch minutes {
        case .some(let m) where m <= 60: "\(m)-minute limit"
        case .some(let m) where m < 1_440: "\(m / 60)-hour limit"
        case .some(let m) where m == 1_440: "daily limit"
        case .some(let m) where m == 10_080: "weekly limit"
        case .some(let m): "\(m / 1_440)-day limit"
        case nil: kind.replacingOccurrences(of: "_", with: " ") + " limit"
        }
    }

    /// Whether the window it describes has not already rolled over.
    ///
    /// A reading with no reset time — a sampled gauge rather than a dated one —
    /// can only be trusted for as long as the window it measures. A five-hour
    /// figure written six hours ago describes a window that no longer exists,
    /// and drawing it would be worse than drawing nothing.
    func isCurrent(now: Date = Date()) -> Bool {
        if let resetsAt, !resetIsApproximate { return resetsAt > now }
        guard let observedAt, let minutes else { return true }
        return now.timeIntervalSince(observedAt) < Double(minutes) * 60
    }

    /// How old the reading is against the window it describes. A weekly figure
    /// from this morning is fresh; a five-hour figure from this morning is not.
    func age(now: Date = Date()) -> TimeInterval? {
        observedAt.map { now.timeIntervalSince($0) }
    }

    /// Whether the age is worth printing beside the figure. Proportional to the
    /// window, so the same rule serves a five-hour gauge and a monthly one.
    func isStale(now: Date = Date()) -> Bool {
        guard let age = age(now: now) else { return false }
        let window = Double(minutes ?? 300) * 60
        return age > max(window / 10, 15 * 60)
    }
}

/// One calendar day of work, including the empty ones.
///
/// The chart that reads these needs the gaps: a week off is part of the shape,
/// and a series that only carries the days you worked draws a straight line
/// through a fortnight of silence.
struct DayUsage: Sendable, Hashable, Identifiable {
    let date: Date
    var billable: Int

    var id: Date { date }
}

/// Where a slice of the tokens went. Agents record the directory they were
/// working in, so "which repo is costing me" is answerable from data we already
/// read — it just was not being shown anywhere.
struct ProjectUsage: Sendable, Hashable, Identifiable {
    let name: String
    var counts: TokenCounts
    var today: TokenCounts
    var lastActivity: Date?

    var id: String { name }
}

/// Everything we know about one tool right now.
struct ProviderUsage: Sendable {
    let provider: ProviderID
    var today = TokenCounts()
    var week = TokenCounts()
    var month = TokenCounts()
    var allTime = TokenCounts()
    var todayCost: Double = 0
    var monthCost: Double = 0
    var currentBlock: UsageBlock?
    var recentBlocks: [UsageBlock] = []
    /// Calendar days with at least one event, newest first — drives the streak.
    var activeDays: [Date] = []
    var sessionCount = 0
    var lastActivity: Date?
    /// Biggest consumers first.
    var projects: [ProjectUsage] = []
    /// What the tool last said about its own rate limits, if anything.
    var limits: [RateWindow] = []
    /// The busiest 5-hour window on record, which is the only ceiling the app
    /// can honestly compare today against: it is something that happened.
    var peakBlock = 0
    /// The busiest calendar week on record, same reasoning.
    var peakWeek = 0
    /// The last fortnight, oldest first, empty days included.
    var recentDays: [DayUsage] = []
}

/// The aggregate the UI and the partner engine both read.
struct UsageSnapshot: Sendable {
    var providers: [ProviderID: ProviderUsage] = [:]
    var generatedAt = Date()

    var detected: [ProviderUsage] {
        ProviderID.allCases.compactMap { providers[$0] }
    }

    var combinedToday: TokenCounts {
        detected.reduce(TokenCounts()) { $0 + $1.today }
    }

    var combinedAllTime: TokenCounts {
        detected.reduce(TokenCounts()) { $0 + $1.allTime }
    }

    var combinedTodayCost: Double {
        detected.reduce(0) { $0 + $1.todayCost }
    }

    var combinedMonthCost: Double {
        detected.reduce(0) { $0 + $1.monthCost }
    }

    var lastActivity: Date? {
        detected.compactMap(\.lastActivity).max()
    }
}
