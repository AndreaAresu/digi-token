import Foundation

/// A digivolution that just happened, held until the UI has shown it.
struct DigivolutionEvent: Identifiable, Sendable {
    let id = UUID()
    let from: String
    let to: DigimonEntry
    let stage: DigiStage
    let isXAntibody: Bool
    let reason: String
    let date: Date
}

/// Owns the partner, the collection, and the rules that move one into the other.
@MainActor
final class PartnerStore {
    private(set) var partner: Partner
    private(set) var collection: [Partner] = []
    private(set) var profile = CareProfile()
    private(set) var seenDigimon: Set<Int> = []
    private(set) var seenXAntibody: Set<Int> = []
    var pendingEvent: DigivolutionEvent?

    /// Called after any change the UI should redraw for. AppKit does not observe
    /// anything on its own, so the store says explicitly when it moved.
    var onChange: (() -> Void)?

    /// All-time tokens at the moment the current partner was born. The partner's
    /// own total is the difference, so a fresh egg starts at zero without us
    /// having to rewrite history.
    private var baseline: Int = 0
    private var hasBaseline = false

    private let storeURL: URL

    struct SaveFile: Codable {
        var partner: Partner
        var collection: [Partner]
        var seenDigimon: [Int]
        var seenXAntibody: [Int]
        var baseline: Int
        var hasBaseline: Bool
        var profile: CareProfile
    }

    init(storeURL: URL = PartnerStore.defaultURL) {
        self.storeURL = storeURL
        if let data = try? Data(contentsOf: storeURL),
           let save = try? JSONDecoder().decode(SaveFile.self, from: data) {
            partner = save.partner
            collection = save.collection
            seenDigimon = Set(save.seenDigimon)
            seenXAntibody = Set(save.seenXAntibody)
            baseline = save.baseline
            hasBaseline = save.hasBaseline
            profile = save.profile
        } else {
            partner = Partner(seed: UInt64.random(in: 1...UInt64.max))
        }
    }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DigiTokenBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("partner.json")
    }

    // MARK: - Growth

    /// Feeds the latest usage to the partner and applies any rung it has earned.
    func apply(snapshot: UsageSnapshot, events: [UsageEvent]) {
        profile = CareEngine.profile(from: snapshot, events: events)

        let allTime = snapshot.combinedAllTime.billable
        // First run adopts whatever history is already on disk as the starting
        // line, so an existing user does not instantly jump to Ultimate.
        if !hasBaseline {
            baseline = allTime
            hasBaseline = true
        }
        // A shrinking all-time total means logs were pruned; re-anchor rather
        // than let the partner's total go negative.
        if allTime < baseline { baseline = allTime }

        partner.tokens = max(0, allTime - baseline)
        partner.careMistakes = profile.careMistakes

        advanceIfEarned()
        save()
        onChange?()
    }

    private func advanceIfEarned() {
        if partner.isEgg {
            guard partner.tokens >= GrowthCurve.eggHatch else { return }
            guard let result = Digivolution.hatch(seed: partner.seed, profile: profile) else { return }
            partner.digimonID = result.entry.id
            partner.stage = .babyI
            partner.hatchedAt = Date()
            partner.lineage = [result.entry.id]
            partner.digivolutionDates = [Date()]
            record(result.entry, isX: false)
            pendingEvent = DigivolutionEvent(
                from: "DigiTama", to: result.entry, stage: .babyI,
                isXAntibody: false, reason: "hatched", date: Date()
            )
            return
        }

        // Several rungs can fall due at once after a long gap between refreshes.
        while let nextStage = partner.stage.next,
              partner.tokens >= GrowthCurve.requirement(for: nextStage),
              let current = partner.entry {
            var rng = SplitMix64(seed: partner.seed &+ UInt64(nextStage.rawValue) &* 7919)
            let roll = Double(rng.next() >> 11) / Double(1 << 53)
            let wantsX = roll < CareEngine.xAntibodyChance(profile: profile, hasCharm: false)

            guard let result = Digivolution.next(
                from: current, to: nextStage, seed: partner.seed,
                profile: profile, wantsXAntibody: wantsX
            ) else { break }

            partner.digimonID = result.entry.id
            partner.stage = nextStage
            partner.isXAntibody = partner.isXAntibody || result.isXAntibody
            partner.lineage.append(result.entry.id)
            partner.digivolutionDates.append(Date())
            record(result.entry, isX: result.isXAntibody)

            pendingEvent = DigivolutionEvent(
                from: current.name, to: result.entry, stage: nextStage,
                isXAntibody: result.isXAntibody, reason: result.reason, date: Date()
            )
        }
    }

    private func record(_ entry: DigimonEntry, isX: Bool) {
        seenDigimon.insert(entry.id)
        if isX || entry.x { seenXAntibody.insert(entry.id) }
    }

    // MARK: - Lifecycle

    /// Retires the current partner into the collection and starts a fresh egg.
    /// Only offered at Ultimate — the point of the ladder is to finish it.
    func graduate() {
        guard !partner.isEgg else { return }
        var retired = partner
        retired.retiredAt = Date()
        collection.append(retired)
        partner = Partner(seed: UInt64.random(in: 1...UInt64.max))
        // Move the starting line up to everything spent so far, so the new egg
        // begins at zero rather than inheriting its predecessor's total.
        baseline += retired.tokens
        save()
        onChange?()
    }

    var canGraduate: Bool { partner.stage == .ultimate && !partner.isEgg }

    func rename(_ name: String) {
        partner.nickname = name.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    /// Fuses two collected partners. The result joins the collection as a form
    /// neither line reached on its own.
    @discardableResult
    func jogress(_ a: Partner, _ b: Partner) -> DigimonEntry? {
        guard let result = Digivolution.jogress(a, b) else { return nil }
        var fused = Partner(seed: a.seed ^ b.seed)
        fused.digimonID = result.entry.id
        fused.stage = result.entry.stageLabel ?? .ultimate
        fused.isXAntibody = result.isXAntibody
        fused.lineage = a.lineage + b.lineage + [result.entry.id]
        fused.hatchedAt = Date()
        fused.retiredAt = Date()
        fused.nickname = "Jogress"
        collection.removeAll { $0.id == a.id || $0.id == b.id }
        collection.append(fused)
        record(result.entry, isX: result.isXAntibody)
        save()
        return result.entry
    }

    var completion: Double {
        let total = DigiDex.shared.all.count
        guard total > 0 else { return 0 }
        return Double(seenDigimon.count) / Double(total)
    }

    func save() {
        let file = SaveFile(
            partner: partner, collection: collection,
            seenDigimon: Array(seenDigimon), seenXAntibody: Array(seenXAntibody),
            baseline: baseline, hasBaseline: hasBaseline, profile: profile
        )
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
