import Foundation

/// A tamer's current partner, from DigiEgg to Ultimate.
struct Partner: Codable, Sendable, Identifiable, Hashable {
    var id: UUID = UUID()
    /// Fixed at hatch; every later branch choice derives from it, so the same
    /// partner raised the same way always walks the same line.
    var seed: UInt64
    var digimonID: Int?
    var stage: DigiStage = .babyI
    var hatchedAt: Date?
    var bornAt: Date = Date()
    /// Billable tokens credited to this partner since it hatched.
    var tokens: Int = 0
    var isXAntibody: Bool = false
    /// Every form this partner has taken, oldest first.
    var lineage: [Int] = []
    var digivolutionDates: [Date] = []
    var careMistakes: Int = 0
    /// Days on which the partner was fed at least one token.
    var caredDays: Int = 0
    var nickname: String?
    /// Set when a partner graduates into the DigiDex and a new egg takes over.
    var retiredAt: Date?

    /// A Digital World field to aim the next digivolution at, from a Field
    /// Compass or a Graded DigiTama. Carried forward rather than consumed
    /// blindly: many early stages have no field data at all, and a purchase
    /// should not evaporate on a rung that could never honour it.
    var preferredField: String?
    /// Set by an X-Antibody Vial, cleared the next time a digivolution resolves.
    var xVialActive: Bool = false

    init(seed: UInt64) { self.seed = seed }

    /// Decoded field by field so that adding a property never invalidates an
    /// existing save.
    ///
    /// Swift's synthesized decoder calls `decode` for every non-optional
    /// property and ignores its default value, so a save written before a new
    /// field existed fails to decode entirely — and a store that treats that as
    /// "no save" silently destroys a partner someone spent weeks raising. This
    /// has to stay hand-written for exactly that reason.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        seed = try c.decode(UInt64.self, forKey: .seed)
        digimonID = try c.decodeIfPresent(Int.self, forKey: .digimonID)
        stage = try c.decodeIfPresent(DigiStage.self, forKey: .stage) ?? .babyI
        hatchedAt = try c.decodeIfPresent(Date.self, forKey: .hatchedAt)
        bornAt = try c.decodeIfPresent(Date.self, forKey: .bornAt) ?? Date()
        tokens = try c.decodeIfPresent(Int.self, forKey: .tokens) ?? 0
        isXAntibody = try c.decodeIfPresent(Bool.self, forKey: .isXAntibody) ?? false
        lineage = try c.decodeIfPresent([Int].self, forKey: .lineage) ?? []
        digivolutionDates = try c.decodeIfPresent([Date].self, forKey: .digivolutionDates) ?? []
        careMistakes = try c.decodeIfPresent(Int.self, forKey: .careMistakes) ?? 0
        caredDays = try c.decodeIfPresent(Int.self, forKey: .caredDays) ?? 0
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname)
        retiredAt = try c.decodeIfPresent(Date.self, forKey: .retiredAt)
        preferredField = try c.decodeIfPresent(String.self, forKey: .preferredField)
        xVialActive = try c.decodeIfPresent(Bool.self, forKey: .xVialActive) ?? false
    }

    var isEgg: Bool { digimonID == nil }

    var entry: DigimonEntry? { digimonID.flatMap { DigiDex.shared.entry($0) } }

    var displayName: String {
        if let nickname, !nickname.isEmpty { return nickname }
        return entry?.name ?? "DigiTama"
    }

    var age: TimeInterval { Date().timeIntervalSince(bornAt) }

    var ageInDays: Int { Int(age / 86400) }
}

/// How fast the ladder should be walked.
///
/// Token spend varies by an order of magnitude between plans and working styles,
/// so a single fixed curve is either unreachable for a light user or trivial for
/// a heavy one. The pace is a multiplier on every threshold, and the tamer picks
/// the one that matches how much they actually use their agent.
enum GrowthPace: String, Codable, Sendable, CaseIterable {
    /// A modest plan, or an agent used a few days a week.
    case quick
    /// The default. Roughly a month to Mega at a steady daily habit.
    case standard
    /// Heavy daily use, where the standard curve would be over in a week.
    case marathon

    var multiplier: Double {
        switch self {
        case .quick: 0.5
        case .standard: 1
        case .marathon: 3
        }
    }

    var label: String {
        switch self {
        case .quick: "Light use"
        case .standard: "Regular use"
        case .marathon: "Heavy use"
        }
    }
}

/// Token cost of each rung.
///
/// Growth runs on *billable* tokens, so the curve never rewards re-sending
/// context you could have cached. The numbers below are set so that reaching
/// Mega is the *start* of the game — the collection and Jogress are the long
/// haul — rather than a months-long grind that most tamers never finish.
enum GrowthCurve {
    static let eggHatch = 20_000

    /// Baseline thresholds at `GrowthPace.standard`.
    private static func baseRequirement(for stage: DigiStage) -> Int {
        switch stage {
        case .babyI: 0
        case .babyII: 75_000
        case .child: 300_000
        case .adult: 1_000_000
        case .perfect: 3_000_000
        case .ultimate: 8_000_000
        }
    }

    static func requirement(for stage: DigiStage, pace: GrowthPace = .standard) -> Int {
        Int((Double(baseRequirement(for: stage)) * pace.multiplier).rounded())
    }

    /// Progress through the current rung, 0...1.
    static func progress(tokens: Int, stage: DigiStage, pace: GrowthPace = .standard) -> Double {
        guard let next = stage.next else { return 1 }
        let floorValue = requirement(for: stage, pace: pace)
        let ceilingValue = requirement(for: next, pace: pace)
        guard ceilingValue > floorValue else { return 1 }
        let span = Double(ceilingValue - floorValue)
        return min(1, max(0, Double(tokens - floorValue) / span))
    }

    static func tokensToNext(tokens: Int, stage: DigiStage, pace: GrowthPace = .standard) -> Int? {
        guard let next = stage.next else { return nil }
        return max(0, requirement(for: next, pace: pace) - tokens)
    }
}

/// Small deterministic PRNG so a partner's branch is reproducible from its seed.
/// Save-scumming by relaunching the app should not change what you get.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
