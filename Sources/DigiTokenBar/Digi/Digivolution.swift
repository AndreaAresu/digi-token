import Foundation

/// Picks what a partner becomes at each rung.
///
/// Pokémon evolution is a line: Charmander only ever becomes Charmeleon. Digimon
/// digivolution is a graph with conditions, and the reference data carries that
/// graph, so the branch a partner takes can genuinely depend on how the tamer
/// worked. That is the whole reason this app is Digimon and not Pokémon.
enum Digivolution {
    struct Result: Sendable {
        let entry: DigimonEntry
        let isXAntibody: Bool
        /// Why this branch was taken, shown to the tamer after the fact.
        let reason: String
        /// Whether a compass or graded egg was actually spent on this step.
        var consumedField: Bool = false
    }

    /// Hatches a DigiEgg into a Baby I form.
    static func hatch(seed: UInt64, profile: CareProfile) -> Result? {
        let pool = DigiDex.shared.entries(stage: .babyI)
        guard !pool.isEmpty else { return nil }
        var rng = SplitMix64(seed: seed)
        let entry = pool[Int(rng.next() % UInt64(pool.count))]
        return Result(entry: entry, isXAntibody: false, reason: "hatched")
    }

    /// Advances one rung.
    ///
    /// Determinism is deliberate: the same seed, the same current form and the
    /// same care profile always produce the same partner, so relaunching the app
    /// cannot be used to reroll an outcome you did not like.
    static func next(
        from current: DigimonEntry,
        to stage: DigiStage,
        seed: UInt64,
        profile: CareProfile,
        wantsXAntibody: Bool,
        preferredField: String? = nil
    ) -> Result? {
        let dex = DigiDex.shared
        var reason = "canon line"

        var pool = current.next
            .compactMap { dex.entry($0) }
            .filter { $0.stageLabel == stage && !$0.side }

        // The evolution graph is canon, not gameplay-complete: plenty of forms
        // simply have no recorded route to the next rung. Rather than dead-end
        // the partner, fall back to the same Digital World field, then to the
        // same attribute, then to the stage at large.
        if pool.isEmpty {
            let sameField = dex.entries(stage: stage).filter {
                !Set($0.fields).isDisjoint(with: Set(current.fields))
            }
            if !sameField.isEmpty {
                pool = sameField
                reason = "field affinity"
            }
        }
        if pool.isEmpty {
            let sameAttribute = dex.entries(stage: stage).filter {
                $0.attribute == current.attribute
            }
            if !sameAttribute.isEmpty {
                pool = sameAttribute
                reason = "attribute affinity"
            }
        }
        if pool.isEmpty {
            pool = dex.entries(stage: stage)
            reason = "wild branch"
        }
        guard !pool.isEmpty else { return nil }

        // Honour the X roll only if the pool can actually satisfy it.
        var rng = SplitMix64(seed: seed &* 0x2545_F491 &+ UInt64(stage.rawValue) &+ UInt64(current.id))
        let xPool = pool.filter(\.x)
        var isX = false
        if wantsXAntibody, !xPool.isEmpty {
            pool = xPool
            isX = true
            reason = "X-Antibody"
        } else if !wantsXAntibody {
            let nonX = pool.filter { !$0.x }
            if !nonX.isEmpty { pool = nonX }
        }

        // A compass narrows the pool rather than merely weighting it. You are
        // buying a direction, not a lottery ticket — paying and then watching the
        // roll ignore you would be the worst of both designs. It still only
        // counts when the pool can honour it, so the purchase is never burned on
        // a rung whose candidates carry no field data at all.
        let honouredField = preferredField.flatMap { field in
            pool.contains { $0.fields.contains(field) } ? field : nil
        }
        if let honouredField {
            pool = pool.filter { $0.fields.contains(honouredField) }
        }

        let scored = pool.map {
            (entry: $0, weight: score(
                $0, current: current, profile: profile, preferredField: honouredField
            ))
        }
        let picked = weightedPick(scored, using: &rng) ?? pool[0]

        if let honouredField, picked.fields.contains(honouredField) {
            reason = "compass: \(honouredField)"
        } else if reason == "canon line", picked.attribute == profile.attribute {
            reason = "\(profile.attribute.rawValue) alignment"
        }
        return Result(
            entry: picked,
            isXAntibody: isX || picked.x,
            reason: reason,
            consumedField: honouredField != nil
        )
    }

    /// How well a candidate fits the tamer and the partner's lineage.
    static func score(
        _ candidate: DigimonEntry,
        current: DigimonEntry,
        profile: CareProfile,
        preferredField: String? = nil
    ) -> Double {
        var weight = 1.0

        // A compass pulls as hard as alignment does — it is a deliberate choice
        // the tamer paid for, not a nudge.
        if let preferredField, candidate.fields.contains(preferredField) { weight += 3.0 }

        // The tamer's habits pull hardest.
        if candidate.attribute == profile.attribute { weight += 3.0 }

        // Lineage continuity — staying inside the same Digital World field reads
        // as a coherent line rather than a random draw.
        let sharedFields = Set(candidate.fields).intersection(Set(current.fields)).count
        weight += Double(sharedFields) * 0.8

        let sharedTypes = Set(candidate.types).intersection(Set(current.types)).count
        weight += Double(sharedTypes) * 0.6

        // A partner kept lean and disciplined leans Vaccine; a neglected one
        // drifts toward Virus regardless of what the tamer would prefer.
        if profile.careMistakes >= 5, candidate.attribute == .virus { weight += 1.5 }
        if profile.careMistakes == 0, candidate.attribute == .vaccine { weight += 1.0 }

        return max(0.05, weight)
    }

    private static func weightedPick(
        _ items: [(entry: DigimonEntry, weight: Double)],
        using rng: inout SplitMix64
    ) -> DigimonEntry? {
        let total = items.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return items.first?.entry }
        // Map the generator onto [0, total) without the modulo bias that a plain
        // `next() % n` would introduce across very different weights.
        let roll = Double(rng.next() >> 11) / Double(1 << 53) * total
        var cursor = 0.0
        for item in items {
            cursor += item.weight
            if roll < cursor { return item.entry }
        }
        return items.last?.entry
    }

    /// Jogress — DNA Digivolution.
    ///
    /// Two graduated partners fuse into one form neither could reach alone.
    /// Pokémon has no equivalent, and it gives a long-running collection an
    /// actual endgame instead of a list that only grows.
    static func jogress(_ a: Partner, _ b: Partner) -> Result? {
        guard let left = a.entry, let right = b.entry else { return nil }
        guard let stage = [left.stageLabel, right.stageLabel].compactMap({ $0 }).max()
        else { return nil }
        // Fusing two partners aims one rung above the higher of the pair; a pair
        // already at the top fuses into another Ultimate rather than failing.
        let target = stage.next ?? .ultimate

        // Sorted, not merely collected: Swift seeds its hasher per process, so
        // iterating the intersection directly hands back a different order on
        // every launch — and with it a different fusion for the same pair. That
        // is precisely the reroll the rest of this file is built to prevent.
        let shared = Set(left.next).intersection(Set(right.next)).sorted()
        var pool = shared.compactMap { DigiDex.shared.entry($0) }.filter { $0.stageLabel == target }

        // Recorded fusions are rare in the reference data, so the same graceful
        // fallback the normal ladder uses applies here: shared fields first —
        // which is how the anime justifies most Jogress pairs anyway — then
        // either partner's attribute, then the stage at large. A pair the tamer
        // worked months to raise must never simply refuse to fuse.
        if pool.isEmpty {
            let fields = Set(left.fields).intersection(Set(right.fields))
            if !fields.isEmpty {
                pool = DigiDex.shared.entries(stage: target).filter {
                    !Set($0.fields).isDisjoint(with: fields)
                }
            }
        }
        if pool.isEmpty {
            let attributes: Set<DigiAttribute> = [left.attribute, right.attribute]
            pool = DigiDex.shared.entries(stage: target).filter {
                attributes.contains($0.attribute)
            }
        }
        if pool.isEmpty {
            pool = DigiDex.shared.entries(stage: target)
        }
        guard !pool.isEmpty else { return nil }

        var rng = SplitMix64(seed: a.seed ^ (b.seed &* 0x9E37_79B9))
        let picked = pool[Int(rng.next() % UInt64(pool.count))]
        return Result(
            entry: picked,
            isXAntibody: picked.x || (a.isXAntibody && b.isXAntibody),
            reason: "Jogress"
        )
    }
}
