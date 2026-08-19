import Foundation

/// How the tamer has been working, expressed in the terms a Digimon V-Pet uses.
///
/// This is the part that makes the app worth having rather than a token counter
/// with a mascot: the *shape* of your usage picks the branch, not just the size.
struct CareProfile: Sendable, Codable, Hashable {
    /// Windows pushed to the limit, plus days the partner went unfed.
    var careMistakes: Int = 0
    /// 10 (lean) ... 99 (heavy). Derived from how much context you re-send
    /// rather than reuse: a tamer who lets the cache work keeps a light partner.
    var weight: Int = 40
    /// 0 ... 100. Showing up consistently, not intensely.
    var discipline: Int = 0
    /// Distinct sessions — Digimon's "training" counter.
    var effort: Int = 0
    /// Share of tokens burned between 22:00 and 06:00.
    var nocturnal: Double = 0
    /// Consecutive active days.
    var streak: Int = 0
    var attribute: DigiAttribute = .free

    var isLean: Bool { weight < 40 }
    var isHeavy: Bool { weight > 65 }
}

enum CareEngine {
    /// Neglect is judged over the recent past only.
    ///
    /// Counting every idle day since the first log ever written would bury a new
    /// partner under its tamer's entire history — a fresh DigiTama would hatch
    /// already neglected. Two weeks is long enough to notice a lapse and short
    /// enough to forgive one.
    static let neglectWindowDays = 14

    /// Idle days inside the window that are forgiven before any count. Nobody
    /// codes seven days a week, and a partner that punishes weekends is a
    /// partner nobody keeps.
    static let neglectGraceDays = 4

    /// A window has to clear this floor before its size can be called overwork,
    /// no matter how it compares to the tamer's own history.
    static let overworkFloor = 2_000_000

    static func profile(
        from snapshot: UsageSnapshot,
        events: [UsageEvent],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> CareProfile {
        var profile = CareProfile()
        let providers = snapshot.detected
        guard !providers.isEmpty else { return profile }

        let allTime = snapshot.combinedAllTime
        let activeDays = Set(providers.flatMap(\.activeDays).map { calendar.startOfDay(for: $0) })
        profile.streak = UsageAggregator.streak(
            activeDays: Array(activeDays), now: now, calendar: calendar
        )
        profile.effort = providers.reduce(0) { $0 + $1.sessionCount }

        // Weight: re-sending context is "overfeeding". A high cache-read share
        // means the tamer works efficiently and the partner stays lean.
        if allTime.total > 0 {
            let cacheShare = Double(allTime.cacheRead) / Double(allTime.total)
            profile.weight = Int((10 + (1 - cacheShare) * 89).rounded())
        }

        // Discipline rewards consistency over volume.
        let recentDays = activeDays.filter { now.timeIntervalSince($0) < 30 * 86400 }.count
        profile.discipline = min(100, profile.streak * 8 + recentDays * 2)

        // Care mistakes: windows run into the ground, plus recent idle days.
        let blocks = providers.flatMap(\.recentBlocks)
        profile.careMistakes = overworkedWindows(blocks) + neglectedDays(
            activeDays: activeDays, now: now, calendar: calendar
        )

        // Night work. Tokens, not turns — a 3am marathon should register.
        var nightTokens = 0
        var totalTokens = 0
        for event in events {
            let hour = calendar.component(.hour, from: event.timestamp)
            totalTokens += event.counts.billable
            if hour >= 22 || hour < 6 { nightTokens += event.counts.billable }
        }
        if totalTokens > 0 {
            profile.nocturnal = Double(nightTokens) / Double(totalTokens)
        }

        profile.attribute = attribute(for: profile)
        return profile
    }

    /// Idle days inside the recent window, past the grace allowance.
    ///
    /// Only the window matters: a tamer who worked every day this fortnight has
    /// a healthy partner regardless of the months of silence before it.
    static func neglectedDays(
        activeDays: Set<Date>, now: Date, calendar: Calendar
    ) -> Int {
        let today = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(
            byAdding: .day, value: -(neglectWindowDays - 1), to: today
        ) else { return 0 }

        let worked = activeDays.filter { $0 >= windowStart && $0 <= today }.count
        let idle = neglectWindowDays - worked
        return max(0, idle - neglectGraceDays)
    }

    /// Windows the tamer ran into the ground.
    ///
    /// "Too much" only means anything relative to how this tamer normally works,
    /// so the bar is set from their own median window and then held above an
    /// absolute floor — otherwise a light user's busiest afternoon would be
    /// scored as a binge.
    static func overworkedWindows(_ blocks: [UsageBlock]) -> Int {
        let sizes = blocks.map(\.counts.billable).filter { $0 > 0 }.sorted()
        guard sizes.count >= 4 else { return 0 }
        let median = sizes[sizes.count / 2]
        let bar = max(overworkFloor, median * 3)
        return sizes.filter { $0 > bar }.count
    }

    /// Which alignment the tamer's habits point at.
    ///
    /// Vaccine is the disciplined, efficient tamer; Virus is the nocturnal one
    /// who runs windows into the ground; Data is the steady middle. Free is what
    /// you get before there is enough signal to say.
    static func attribute(for profile: CareProfile) -> DigiAttribute {
        // Saturating, so a tamer with ten mistakes and one with forty are both
        // simply "neglectful" instead of the count running away with the score.
        let neglect = min(1.0, Double(profile.careMistakes) / 8.0)

        var scores: [DigiAttribute: Double] = [:]

        scores[.vaccine] = Double(profile.discipline) / 100 * 2
            + (profile.isLean ? 1.0 : 0)
            - neglect * 1.5

        // Neglect counts toward Virus but cannot carry it alone: a tamer who
        // simply had a quiet fortnight is not a Virus tamer, they are a tamer we
        // do not know much about yet — which is what Free is for. Virus needs a
        // second signal, night work or a context-heavy style, to win.
        scores[.virus] = profile.nocturnal * 2.0
            + neglect * 1.0
            + (profile.isHeavy ? 0.8 : 0)

        scores[.data] = 1.0
            + (profile.effort > 40 ? 0.8 : 0)
            + ((40...65).contains(profile.weight) ? 0.7 : 0)
            - abs(Double(profile.discipline) - 50) / 100

        scores[.free] = 0.9

        let best = scores.max { $0.value < $1.value }
        return best?.key ?? .free
    }

    /// Odds of an X-Antibody form at a digivolution.
    ///
    /// Digimon's answer to a shiny, except it is real canon data rather than a
    /// palette swap. Consistency improves it; burning tokens does not.
    static func xAntibodyChance(profile: CareProfile, hasCharm: Bool) -> Double {
        let base = 1.0 / 128.0
        let disciplineBonus = Double(profile.discipline) / 100 * 0.012
        let charm = hasCharm ? 3.0 : 1.0
        return min(0.25, (base + disciplineBonus) * charm)
    }
}
