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
    private(set) var wallet = Wallet()
    /// Days a Streak Freeze has already covered.
    private(set) var frozenDays: Set<Date> = []
    /// An affinity bought for the *next* egg, applied when it hatches.
    private(set) var nextEggField: String?
    /// Cards other tamers have handed over, newest first.
    private(set) var friends: [TamerCard] = []
    var pendingEvent: DigivolutionEvent?

    /// Called after any change the UI should redraw for. AppKit does not observe
    /// anything on its own, so the store says explicitly when it moved.
    var onChange: (() -> Void)?

    /// Fired once per digivolution, at the moment it happens. `pendingEvent`
    /// lingers until the tamer dismisses the banner, so it cannot be used to
    /// drive a notification without repeating it on every refresh.
    var onDigivolution: ((DigivolutionEvent) -> Void)?

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
        /// Optional because it is recomputed from usage on every refresh, so a
        /// save missing it loses nothing — and a required field here would make
        /// the whole save unreadable the next time `CareProfile` gains a
        /// property.
        var profile: CareProfile?
        var wallet: Wallet?
        var frozenDays: [Date]?
        var nextEggField: String?
        var friends: [TamerCard]?
    }

    init(storeURL: URL = PartnerStore.defaultURL) {
        self.storeURL = storeURL
        let data = try? Data(contentsOf: storeURL)

        // A save that exists but cannot be read must never be silently replaced
        // — that is weeks of someone's partner. Keep a copy before starting over
        // so the loss is recoverable rather than absolute.
        if let data, (try? JSONDecoder().decode(SaveFile.self, from: data)) == nil {
            let backup = storeURL.deletingLastPathComponent().appendingPathComponent(
                "partner.unreadable-\(Int(Date().timeIntervalSince1970)).json"
            )
            try? data.write(to: backup, options: .atomic)
        }

        if let data,
           let save = try? JSONDecoder().decode(SaveFile.self, from: data) {
            partner = save.partner
            collection = save.collection
            seenDigimon = Set(save.seenDigimon)
            seenXAntibody = Set(save.seenXAntibody)
            baseline = save.baseline
            hasBaseline = save.hasBaseline
            profile = save.profile ?? CareProfile()
            wallet = save.wallet ?? Wallet()
            frozenDays = Set(save.frozenDays ?? [])
            nextEggField = save.nextEggField
            friends = save.friends ?? []
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
        let allTimeBillable = snapshot.combinedAllTime.billable

        // The wallet counts work done since the app was installed, which is the
        // same starting line the partner uses. Adopting it rather than anchoring
        // fresh means an existing tamer does not find an empty balance next to a
        // partner that has clearly been growing for weeks.
        if !wallet.hasBaseline, hasBaseline {
            wallet.baseline = baseline
            wallet.hasBaseline = true
        }
        wallet.update(allTimeBillable: allTimeBillable)
        // Charges follow the same meter as the currency: work done since
        // install, never elapsed time.
        wallet.dna.accrue(earned: wallet.earned)
        spendStreakFreezesIfNeeded(snapshot: snapshot)

        profile = CareEngine.profile(from: snapshot, events: events, frozenDays: frozenDays)

        let allTime = allTimeBillable
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

    /// Consumes held Streak Freezes on idle days, the way Duolingo's do: bought
    /// ahead of the lapse, spent automatically when it happens, never applied in
    /// hindsight by the tamer.
    private func spendStreakFreezesIfNeeded(snapshot: UsageSnapshot) {
        let stock = wallet.stock(of: .streakFreeze)
        guard stock > 0 else { return }

        let calendar = Calendar.current
        let activeDays = Set(
            snapshot.detected.flatMap(\.activeDays).map { calendar.startOfDay(for: $0) }
        )
        let days = CareEngine.daysToFreeze(
            activeDays: activeDays, alreadyFrozen: frozenDays, available: stock
        )
        guard !days.isEmpty else { return }

        frozenDays.formUnion(days)
        wallet.inventory[.streakFreeze] = stock - days.count
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
            // A Graded DigiTama's affinity rides along with the hatchling; only
            // a third of Baby I forms carry field data, so it is honoured at the
            // first digivolution that can rather than at the hatch itself.
            if let field = nextEggField {
                partner.preferredField = field
                nextEggField = nil
            }
            record(result.entry, isX: false)
            let event = DigivolutionEvent(
                from: "DigiTama", to: result.entry, stage: .babyI,
                isXAntibody: false, reason: "hatched", date: Date()
            )
            pendingEvent = event
            onDigivolution?(event)
            return
        }

        // Several rungs can fall due at once after a long gap between refreshes,
        // or after the tamer switches to a quicker growth pace.
        let pace = Settings.shared.growthPace
        while let nextStage = partner.stage.next,
              partner.tokens >= GrowthCurve.requirement(for: nextStage, pace: pace),
              let current = partner.entry {
            var rng = SplitMix64(seed: partner.seed &+ UInt64(nextStage.rawValue) &* 7919)
            let roll = Double(rng.next() >> 11) / Double(1 << 53)
            // A vial does not improve the odds, it settles them — it was bought
            // before this branch was known, which is the whole point.
            let wantsX = partner.xVialActive
                || roll < CareEngine.xAntibodyChance(profile: profile, hasCharm: false)

            guard let result = Digivolution.next(
                from: current, to: nextStage, seed: partner.seed,
                profile: profile, wantsXAntibody: wantsX,
                preferredField: partner.preferredField
            ) else { break }

            partner.digimonID = result.entry.id
            partner.stage = nextStage
            partner.isXAntibody = partner.isXAntibody || result.isXAntibody
            partner.xVialActive = false
            if result.consumedField { partner.preferredField = nil }
            partner.lineage.append(result.entry.id)
            partner.digivolutionDates.append(Date())
            record(result.entry, isX: result.isXAntibody)

            let event = DigivolutionEvent(
                from: current.name, to: result.entry, stage: nextStage,
                isXAntibody: result.isXAntibody, reason: result.reason, date: Date()
            )
            pendingEvent = event
            onDigivolution?(event)
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

    // MARK: - Shop

    enum PurchaseResult: Equatable {
        case bought
        case tooExpensive
        case notApplicable(String)
    }

    /// Buys one item. `field` is required by the compass and the graded egg.
    @discardableResult
    func purchase(_ id: ShopItemID, field: String? = nil) -> PurchaseResult {
        let item = ShopItem.item(id)
        guard wallet.canAfford(item) else { return .tooExpensive }
        if item.needsField, field == nil { return .notApplicable("Pick a field first.") }

        switch id {
        case .streakFreeze:
            wallet.inventory[.streakFreeze, default: 0] += 1

        case .fieldCompass:
            guard !partner.isEgg else {
                return .notApplicable("Your DigiTama has to hatch before it can be pointed anywhere.")
            }
            partner.preferredField = field

        case .xVial:
            guard !partner.isEgg else {
                return .notApplicable("Wait for the egg to hatch — there is no digivolution to affect yet.")
            }
            guard partner.stage.next != nil else {
                return .notApplicable("\(partner.displayName) is already at the top of the ladder.")
            }
            partner.xVialActive = true

        case .gradedEgg:
            nextEggField = field

        case .dnaCharge:
            guard !wallet.dna.isFull else {
                return .notApplicable(
                    "Your DNA charge is already full at \(DNACharge.cap). Spend one on a Jogress first."
                )
            }
            wallet.dna.stock += 1
        }

        wallet.spent += item.price
        save()
        onChange?()
        return .bought
    }

    /// What the shop should say is currently in effect.
    var activeEffects: [String] {
        var effects: [String] = [dnaChargeSummary]
        if let field = partner.preferredField {
            effects.append("Compass pointing at \(field)")
        }
        if partner.xVialActive {
            effects.append("X-Antibody vial primed for the next digivolution")
        }
        if let field = nextEggField {
            effects.append("Next DigiTama graded toward \(field)")
        }
        let stock = wallet.stock(of: .streakFreeze)
        if stock > 0 {
            effects.append("\(stock) Streak Freeze\(stock == 1 ? "" : "s") in reserve")
        }
        if !frozenDays.isEmpty {
            effects.append("\(frozenDays.count) day\(frozenDays.count == 1 ? "" : "s") frozen so far")
        }
        return effects
    }

    /// The charge meter in one line, always shown: it is standing state rather
    /// than a temporary effect, and a tamer about to fuse needs to know where it
    /// stands before they pick a partner to spend.
    var dnaChargeSummary: String {
        let dna = wallet.dna
        let head = "DNA charge \(dna.stock)/\(DNACharge.cap)"
        return dna.isFull
            ? "\(head) — full"
            : "\(head) · \(TokenFormatter.short(dna.tokensToNext)) to the next"
    }

    /// Re-checks the ladder without a new usage scan. Needed when the growth
    /// pace changes, since the thresholds move under a partner that has not
    /// earned a single extra token.
    func reevaluate() {
        advanceIfEarned()
        save()
        onChange?()
    }

    func rename(_ name: String) {
        partner.nickname = name.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    /// Fuses two collected partners. The result joins the collection as a form
    /// neither line reached on its own.
    ///
    /// Reports why it did not happen rather than returning nil for three
    /// different reasons — the pane has to be able to say which one it was.
    @discardableResult
    func jogress(_ a: Partner, _ b: Partner) -> JogressResult {
        guard let result = Digivolution.jogress(a, b) else { return .noRoute }
        // Spent only once the fusion is known to be possible, and before either
        // partner is removed below.
        guard wallet.dna.spend() else { return .noCharge }
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
        onChange?()
        return .fused(result.entry.name)
    }

    // MARK: - Tamer cards

    /// Why an import or a fusion did not happen, in terms the pane can show.
    enum CardResult: Equatable {
        case imported(String)
        case ownCard
        case stillAnEgg
        case rejected(TamerCardCodec.DecodeError)
    }

    enum JogressResult: Equatable {
        case fused(String)
        case notInCollection
        case noRoute
        /// The fusion is possible, the meter is empty. Checked before anything
        /// is consumed, so a tamer never loses a partner to a failed Jogress.
        case noCharge
    }

    /// The card for the current partner, or nil while it is still an egg —
    /// there is nothing to show off and nothing to fuse with yet.
    func myCard(name: String) -> TamerCard? {
        guard let entry = partner.entry else { return nil }
        return TamerCard(
            tamer: name.isEmpty ? "Tamer" : name,
            seed: partner.seed,
            digimonID: entry.id,
            stage: partner.stage,
            isXAntibody: partner.isXAntibody,
            lineage: partner.lineage,
            nickname: partner.nickname,
            tokens: partner.tokens,
            attribute: profile.attribute,
            streak: profile.streak,
            careMistakes: profile.careMistakes,
            dexSeen: seenDigimon.count,
            dexTotal: DigiDex.shared.all.count
        )
    }

    /// Takes a pasted card in.
    ///
    /// Re-importing a friend whose partner has since digivolved replaces their
    /// old card rather than adding a second one, so the list stays a list of
    /// people rather than a log of every form they have passed through.
    @discardableResult
    func importCard(_ raw: String) -> CardResult {
        let card: TamerCard
        do {
            card = try TamerCardCodec.decode(raw)
        } catch let error as TamerCardCodec.DecodeError {
            return .rejected(error)
        } catch {
            return .rejected(.unreadable)
        }

        // Fusing with yourself is not a Jogress, and a seed that matches one of
        // your own partners is either your own card or a copy of it.
        let mine = [partner.seed] + collection.map(\.seed)
        guard !mine.contains(card.seed) else { return .ownCard }
        guard card.entry != nil else { return .stillAnEgg }

        friends.removeAll { $0.id == card.id }
        friends.insert(card, at: 0)
        save()
        onChange?()
        return .imported(card.tamer)
    }

    func forgetFriend(_ card: TamerCard) {
        friends.removeAll { $0.id == card.id }
        save()
        onChange?()
    }

    /// Jogress across two tamers.
    ///
    /// Mirrors the local fusion deliberately: it spends one of *your* graduated
    /// partners and leaves the visitor untouched. Their card is a photograph,
    /// not a transfer of custody — nothing this app does should be able to
    /// consume something on someone else's machine.
    ///
    /// The outcome is seeded from both partners, so importing the same card
    /// twice and fusing the same partner cannot be used to reroll a form the
    /// tamer did not like.
    @discardableResult
    func jogress(_ mine: Partner, with card: TamerCard) -> JogressResult {
        guard collection.contains(where: { $0.id == mine.id }) else { return .notInCollection }
        guard let result = Digivolution.jogress(mine, card.partner) else { return .noRoute }
        // Checked before the partner is removed below: an empty meter must cost
        // nothing, least of all a graduated partner.
        guard wallet.dna.spend() else { return .noCharge }

        var fused = Partner(seed: mine.seed ^ card.seed)
        fused.digimonID = result.entry.id
        fused.stage = result.entry.stageLabel ?? .ultimate
        fused.isXAntibody = result.isXAntibody
        fused.lineage = mine.lineage + card.lineage + [result.entry.id]
        fused.hatchedAt = Date()
        fused.retiredAt = Date()
        fused.nickname = "Jogress · \(card.tamer)"
        collection.removeAll { $0.id == mine.id }
        collection.append(fused)
        record(result.entry, isX: result.isXAntibody)
        save()
        onChange?()
        return .fused(result.entry.name)
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
            baseline: baseline, hasBaseline: hasBaseline, profile: profile,
            wallet: wallet, frozenDays: Array(frozenDays), nextEggField: nextEggField,
            friends: friends
        )
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
