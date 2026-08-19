import Foundation

/// Raw token counts for a single assistant turn, kept separate because the
/// partner's growth reads them differently: cached reads are cheap and signal an
/// efficient tamer, fresh input is expensive and makes the partner gain weight.
struct TokenCounts: Sendable, Hashable, Codable {
    var input: Int = 0
    var output: Int = 0
    var cacheCreation: Int = 0
    var cacheRead: Int = 0

    /// What the provider actually billed against the context window.
    var total: Int { input + output + cacheCreation + cacheRead }

    /// Tokens that cost full price — the ones that feed digivolution.
    var billable: Int { input + output + cacheCreation }

    static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheCreation: lhs.cacheCreation + rhs.cacheCreation,
            cacheRead: lhs.cacheRead + rhs.cacheRead
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
