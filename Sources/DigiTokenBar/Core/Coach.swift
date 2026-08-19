import Foundation

/// One thing worth changing, with the measurement that says so.
///
/// Every piece of advice carries the figure that triggered it, and none is
/// emitted unless that figure crosses a threshold. Advice that cannot point at
/// a number is a horoscope, and a partner app that lectures its tamer about
/// habits it has not measured is worse than one that says nothing.
struct Advice: Sendable, Hashable, Identifiable {
    let id: String
    /// What to do, in a few words.
    let title: String
    /// Why it is worth doing.
    let detail: String
    /// The measurement behind it, always shown so the claim is checkable.
    let evidence: String
    /// Ordering only — higher first.
    let severity: Int
}

/// What the coach measured, whether or not it had anything to advise.
///
/// The basis is reported even when nothing fires, so "no advice" reads as a
/// clean bill of health with numbers attached rather than as a broken feature.
struct CoachReport: Sendable {
    var advice: [Advice] = []
    /// True when there is too little history for any of it to mean anything.
    var isTooEarly = false
    var sessions = 0
    var billable = 0
    /// Share of everything sent that came back off the cache, 0...1.
    var cacheShare = 0.0
    /// Cache tokens read per cache token written.
    var amortisation = 0.0
    /// Billable tokens in the median session.
    var medianSession = 0
    /// Model id carrying the largest share of estimated cost.
    var topModel: String?
}

/// Reads the same events the partner grows on and says where the money goes.
///
/// Deliberately not a Digimon feature: it makes no reference to the partner and
/// derives nothing from the care profile. What it reports is true whether or not
/// anyone is raising anything.
enum Coach {
    // MARK: - Gates

    /// Below this there is no habit to describe, only a handful of sessions.
    static let minSessions = 5
    static let minBillable = 500_000

    // MARK: - Thresholds
    //
    // Calibrated against the real logs on a working machine rather than picked
    // for roundness. The reference profile — 97% cache share, 43x amortisation,
    // a 400K median session — has to come out clean, or the coach is crying
    // wolf at exactly the tamer it should be leaving alone.

    /// Cache share below this means context is being re-sent rather than reused.
    static let cacheShareFloor = 0.60

    /// Reads per write below this means the cache is not paying for itself.
    ///
    /// A cache write costs 1.25x a fresh input token and a read costs 0.1x, so
    /// break-even is under one read per write. The bar sits well above that: it
    /// should only fire when the pattern is clearly wrong, not when it is
    /// merely tight.
    static let amortisationFloor = 2.0

    /// Cache writes have to be at least this much of the bill before their
    /// amortisation is worth commenting on at all.
    static let cacheWriteShareBar = 0.25

    /// A median session smaller than this is over before the context it built
    /// can be reused.
    static let shortSessionBar = 50_000

    /// Paired with the bar above: short sessions only matter when most of the
    /// spend went on building context.
    static let heavyWriteShare = 0.50

    /// Cost share above which one model is carrying the bill.
    static let costConcentrationBar = 0.70

    /// A model has to be at least this many times cheaper to count as the
    /// cheaper alternative that is going unused.
    static let cheaperMultiple = 3.0

    /// Token share below which those cheaper models are effectively idle.
    static let idleTierBar = 0.15

    // MARK: - Report

    static func report(events rawEvents: [UsageEvent]) -> CoachReport {
        var report = CoachReport()

        // The same assistant turn appears in every forked transcript that
        // contains it. Counting duplicates inflated model shares by 2.6x on the
        // machine this was calibrated against, so the dedup is not optional.
        var seen = Set<String>()
        let events = rawEvents.filter { seen.insert($0.dedupKey).inserted }
        guard !events.isEmpty else {
            report.isTooEarly = true
            return report
        }

        var totals = TokenCounts()
        var perSession: [String: Int] = [:]
        var perModel: [String: TokenCounts] = [:]
        for event in events {
            totals += event.counts
            perSession[event.sessionID, default: 0] += event.counts.billable
            perModel[event.model, default: TokenCounts()] += event.counts
        }

        report.sessions = perSession.count
        report.billable = totals.billable
        report.cacheShare = ratio(totals.cacheRead, totals.total)
        report.amortisation = totals.cacheCreation > 0
            ? Double(totals.cacheRead) / Double(totals.cacheCreation)
            : 0
        let sizes = perSession.values.sorted()
        report.medianSession = sizes.isEmpty ? 0 : sizes[sizes.count / 2]
        report.topModel = perModel
            .max { cost($0) < cost($1) }
            .map(\.key)

        guard report.sessions >= minSessions, report.billable >= minBillable else {
            report.isTooEarly = true
            return report
        }

        var advice: [Advice] = []
        if let item = cacheReuse(report) { advice.append(item) }
        if let item = cacheAmortisation(report, totals: totals) { advice.append(item) }
        if let item = sessionLength(report, totals: totals) { advice.append(item) }
        if let item = modelMix(perModel) { advice.append(item) }

        report.advice = advice.sorted { $0.severity > $1.severity }
        return report
    }

    // MARK: - Rules

    /// Context re-sent instead of reused.
    private static func cacheReuse(_ report: CoachReport) -> Advice? {
        guard report.cacheShare < cacheShareFloor else { return nil }
        return Advice(
            id: "cache-reuse",
            title: "Let the cache carry more of the context",
            detail: """
                Most of what you send is arriving as fresh input rather than \
                coming back off the cache, and fresh input is the expensive \
                kind. Longer sessions over the same files, instead of new ones \
                that rebuild the same context, move tokens onto the cheap path.
                """,
            evidence: String(
                format: "cache covers %.0f%% of what you send — under %.0f%% is where it starts to cost",
                report.cacheShare * 100, cacheShareFloor * 100
            ),
            severity: 30
        )
    }

    /// Cache written and then abandoned before it pays back.
    private static func cacheAmortisation(_ report: CoachReport, totals: TokenCounts) -> Advice? {
        guard totals.cacheCreation > 0 else { return nil }
        let writeShare = ratio(totals.cacheCreation, totals.billable)
        guard writeShare >= cacheWriteShareBar else { return nil }
        guard report.amortisation < amortisationFloor else { return nil }
        return Advice(
            id: "cache-amortisation",
            title: "Your sessions end before the cache pays for itself",
            detail: """
                Writing the cache costs more than a plain input token; reading \
                it costs a fraction of one. That trade only comes out ahead if \
                a session goes on to read what it wrote. Yours are being \
                rebuilt more often than they are being used.
                """,
            evidence: String(
                format: "%.1f cache reads per write, and cache writes are %.0f%% of your billable spend",
                report.amortisation, writeShare * 100
            ),
            severity: 40
        )
    }

    /// Sessions too short for their own setup cost.
    private static func sessionLength(_ report: CoachReport, totals: TokenCounts) -> Advice? {
        guard report.medianSession < shortSessionBar else { return nil }
        let writeShare = ratio(totals.cacheCreation, totals.billable)
        // A small median on its own just means small tasks, which is fine. It
        // only costs anything when the spend went on building context that the
        // session then ended too early to use.
        guard writeShare > heavyWriteShare else { return nil }
        return Advice(
            id: "session-length",
            title: "Overhead is a large share of short sessions",
            detail: """
                Half your sessions finish under \
                \(TokenFormatter.short(report.medianSession)) billable tokens, \
                and most of that went on setting up context rather than on \
                work. Grouping related asks into one session amortises the \
                setup you are otherwise paying for each time.
                """,
            evidence: String(
                format: "median session %@ billable, %.0f%% of spend on building context",
                TokenFormatter.short(report.medianSession), writeShare * 100
            ),
            severity: 20
        )
    }

    /// One expensive model carrying work the cheaper ones in the mix never see.
    ///
    /// This deliberately stops at the split. Whether a given task needed the
    /// larger model is not in the logs, so the coach reports where the money
    /// sits and leaves the judgement to the person who wrote the prompts.
    private static func modelMix(_ perModel: [String: TokenCounts]) -> Advice? {
        guard perModel.count > 1 else { return nil }

        let totalCost = perModel.reduce(0.0) { $0 + cost(($1.key, $1.value)) }
        let totalBillable = perModel.values.reduce(0) { $0 + $1.billable }
        guard totalCost > 0, totalBillable > 0 else { return nil }

        guard let top = perModel.max(by: { cost($0) < cost($1) }) else { return nil }
        let topShare = cost(top) / totalCost
        guard topShare > costConcentrationBar else { return nil }

        // "Cheaper" is read off the price table rather than off model names, so
        // a new model needs no special case here to be understood.
        let topRate = ModelPricing.rate(for: top.key).input
        let cheaper = perModel.filter { model, _ in
            model != top.key && ModelPricing.rate(for: model).input * cheaperMultiple <= topRate
        }
        guard !cheaper.isEmpty else { return nil }

        let cheaperBillable = cheaper.values.reduce(0) { $0 + $1.billable }
        let cheaperShare = ratio(cheaperBillable, totalBillable)
        guard cheaperShare < idleTierBar else { return nil }

        let factor = topRate / max(0.01, cheaper.keys.map { ModelPricing.rate(for: $0).input }.min() ?? topRate)
        return Advice(
            id: "model-mix",
            title: "Almost everything is going to your most expensive model",
            detail: """
                You already have cheaper models configured and they are barely \
                used. Nothing in the logs says which of these tasks needed the \
                larger model — that part is your call — but this is where the \
                bill is, and it is the one lever that moves it without changing \
                how you work.
                """,
            evidence: String(
                format: "%@ is %.0f%% of estimated cost; models up to %.0fx cheaper handle %.0f%% of your tokens",
                top.key, topShare * 100, factor, cheaperShare * 100
            ),
            severity: 35
        )
    }

    // MARK: - Helpers

    private static func cost(_ entry: (key: String, value: TokenCounts)) -> Double {
        ModelPricing.cost(model: entry.key, counts: entry.value)
    }

    private static func ratio(_ part: Int, _ whole: Int) -> Double {
        whole > 0 ? Double(part) / Double(whole) : 0
    }
}
