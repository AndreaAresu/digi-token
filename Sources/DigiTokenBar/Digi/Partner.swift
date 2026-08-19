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

    var isEgg: Bool { digimonID == nil }

    var entry: DigimonEntry? { digimonID.flatMap { DigiDex.shared.entry($0) } }

    var displayName: String {
        if let nickname, !nickname.isEmpty { return nickname }
        return entry?.name ?? "DigiTama"
    }

    var age: TimeInterval { Date().timeIntervalSince(bornAt) }

    var ageInDays: Int { Int(age / 86400) }
}

/// Token cost of each rung.
///
/// Tuned so a heavy daily user reaches Ultimate in roughly two months and a
/// casual one still sees a digivolution in the first week — the curve has to
/// reward showing up more than it rewards burning tokens, or the app becomes an
/// argument for wasting money.
enum GrowthCurve {
    static let eggHatch = 20_000

    static func requirement(for stage: DigiStage) -> Int {
        switch stage {
        case .babyI: 0
        case .babyII: 120_000
        case .child: 600_000
        case .adult: 3_000_000
        case .perfect: 12_000_000
        case .ultimate: 40_000_000
        }
    }

    /// Progress through the current rung, 0...1.
    static func progress(tokens: Int, stage: DigiStage) -> Double {
        guard let next = stage.next else { return 1 }
        let floorValue = requirement(for: stage)
        let ceilingValue = requirement(for: next)
        guard ceilingValue > floorValue else { return 1 }
        let span = Double(ceilingValue - floorValue)
        return min(1, max(0, Double(tokens - floorValue) / span))
    }

    static func tokensToNext(tokens: Int, stage: DigiStage) -> Int? {
        guard let next = stage.next else { return nil }
        return max(0, requirement(for: next) - tokens)
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
