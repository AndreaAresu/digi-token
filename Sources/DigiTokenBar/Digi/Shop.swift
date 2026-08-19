import Foundation

/// What the shop sells.
///
/// One rule governs the catalogue: **an item may be bought in advance, never
/// applied in hindsight.** The digivolution engine is deterministic precisely so
/// that relaunching the app cannot reroll a result you disliked; an item that
/// undoes a care mistake or skips a rung would be that same trick wearing a
/// price tag. Everything here is bought before the outcome is known.
///
/// This is why there is no medicine that clears a care mistake and no candy that
/// skips a stage, however traditional both are.
enum ShopItemID: String, Codable, Sendable, CaseIterable {
    case streakFreeze
    case fieldCompass
    case xVial
    case gradedEgg
    case dnaCharge
}

struct ShopItem: Sendable, Identifiable {
    let id: ShopItemID
    let name: String
    let blurb: String
    let price: Int
    let symbol: String
    /// Whether buying it asks which Digital World field to aim at.
    let needsField: Bool
    /// Whether it is stocked in an inventory rather than applied immediately.
    let stockable: Bool

    static let catalogue: [ShopItem] = [
        ShopItem(
            id: .streakFreeze,
            name: "Streak Freeze",
            blurb: "Covers one idle day. Bought ahead, spent automatically, and always shown as frozen.",
            price: 150_000,
            symbol: "snowflake",
            needsField: false,
            stockable: true
        ),
        ShopItem(
            id: .fieldCompass,
            name: "Field Compass",
            blurb: "Points your partner's next digivolution at one Digital World field. Changes nothing about your record.",
            price: 400_000,
            symbol: "location.north.circle",
            needsField: true,
            stockable: false
        ),
        ShopItem(
            id: .xVial,
            name: "X-Antibody Vial",
            blurb: "Forces the X-Antibody roll at the next digivolution, if the branch has an X form at all.",
            price: 1_500_000,
            symbol: "testtube.2",
            needsField: false,
            stockable: false
        ),
        ShopItem(
            id: .dnaCharge,
            name: "DNA Charge",
            blurb: "Fuel for one Jogress. Three at most, and they build back up as you work.",
            price: 1_000_000,
            symbol: "bolt.horizontal.circle",
            needsField: false,
            stockable: true
        ),
        ShopItem(
            id: .gradedEgg,
            name: "Graded DigiTama",
            blurb: "Your next egg carries an affinity, honoured at its first digivolution that can.",
            price: 800_000,
            symbol: "oval.portrait",
            needsField: true,
            stockable: false
        ),
    ]

    static func item(_ id: ShopItemID) -> ShopItem {
        catalogue.first { $0.id == id } ?? catalogue[0]
    }
}

/// Fuel for a Jogress.
///
/// A DNA Digivolution is the one thing in the app that fuses two finished
/// partners, and it used to be a button with nothing behind it. A charge gives
/// it a cost that is paid in the same currency as everything else here: work.
///
/// Charges come back with **tokens, never with the clock**. A meter that
/// refilled overnight would hand out fusions for waiting, and waiting is the
/// one thing this app cannot see you do. Three is the ceiling, so they cannot
/// be hoarded across months, and the meter stops while it is full rather than
/// banking progress against a charge nobody has spent.
///
/// Buying one in the shop is still buying ahead of an outcome: the fusion it
/// pays for has not happened yet, and the form it produces is seeded from both
/// partners. It clears no care mistake and rewrites no record.
struct DNACharge: Codable, Sendable {
    static let cap = 3

    /// Billable tokens per charge. Mega costs 8M, so raising one partner to
    /// graduation fills the meter about three times over — the charge is meant
    /// to pace fusions, not to stand in front of one already earned.
    static let tokensPerCharge = 2_500_000

    var stock = 0
    /// Billable tokens banked toward the next charge.
    var progress = 0
    /// The wallet's earned total at the last accrual, so the same tokens never
    /// count twice.
    var watermark = 0
    var hasWatermark = false

    init() {}

    /// Decoded field by field, like every other persisted type here.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stock = try container.decodeIfPresent(Int.self, forKey: .stock) ?? 0
        progress = try container.decodeIfPresent(Int.self, forKey: .progress) ?? 0
        watermark = try container.decodeIfPresent(Int.self, forKey: .watermark) ?? 0
        hasWatermark = try container.decodeIfPresent(Bool.self, forKey: .hasWatermark) ?? false
    }

    var isFull: Bool { stock >= Self.cap }
    var tokensToNext: Int { max(0, Self.tokensPerCharge - progress) }

    /// Banks the work done since the last call.
    ///
    /// A tamer who was already using the app when charges arrived has done the
    /// work; their first accrual counts all of it rather than starting them at
    /// zero. A wallet that re-anchors after logs are pruned moves the watermark
    /// down without paying twice for the same tokens.
    mutating func accrue(earned: Int) {
        defer {
            // Never downward. A wallet re-anchors when logs are pruned, and a
            // watermark that followed it down would pay a second time for the
            // tokens between the two.
            watermark = hasWatermark ? max(watermark, earned) : earned
            hasWatermark = true
        }
        let previous = hasWatermark ? watermark : 0
        guard earned > previous else { return }
        guard !isFull else {
            progress = 0
            return
        }
        progress += earned - previous
        while progress >= Self.tokensPerCharge, !isFull {
            progress -= Self.tokensPerCharge
            stock += 1
        }
        if isFull { progress = 0 }
    }

    mutating func spend() -> Bool {
        guard stock > 0 else { return false }
        stock -= 1
        return true
    }
}

/// The tamer's balance and stock.
///
/// Currency is billable tokens earned **since the app was installed** — not the
/// whole history sitting in the logs, which would hand a long-time user a
/// windfall on first launch. Spending never slows the partner: growth reads its
/// own total, so shopping is a budget, not a tax on progress.
struct Wallet: Codable, Sendable {
    var baseline: Int = 0
    var hasBaseline = false
    var spent: Int = 0
    var earned: Int = 0
    var inventory: [ShopItemID: Int] = [:]
    var dna = DNACharge()

    init() {}

    /// Decoded field by field, for the reason the whole project does it: the
    /// synthesized decoder calls `decode` for every non-optional property and
    /// ignores its default value, so adding `dna` would have made every wallet
    /// written before today undecodable. `SaveFile` holds the wallet, and a
    /// `SaveFile` that will not decode takes the partner with it — that has
    /// already cost someone weeks of raising once.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseline = try container.decodeIfPresent(Int.self, forKey: .baseline) ?? 0
        hasBaseline = try container.decodeIfPresent(Bool.self, forKey: .hasBaseline) ?? false
        spent = try container.decodeIfPresent(Int.self, forKey: .spent) ?? 0
        earned = try container.decodeIfPresent(Int.self, forKey: .earned) ?? 0
        inventory = try container.decodeIfPresent([ShopItemID: Int].self, forKey: .inventory) ?? [:]
        dna = try container.decodeIfPresent(DNACharge.self, forKey: .dna) ?? DNACharge()
    }

    var balance: Int { max(0, earned - spent) }

    mutating func update(allTimeBillable: Int) {
        if !hasBaseline {
            baseline = allTimeBillable
            hasBaseline = true
        }
        // Pruned or relocated logs can shrink the all-time total; re-anchor
        // rather than let the balance go negative.
        if allTimeBillable < baseline { baseline = allTimeBillable }
        earned = max(0, allTimeBillable - baseline)
    }

    func canAfford(_ item: ShopItem) -> Bool { balance >= item.price }

    /// Charges are counted by the meter that refills them rather than by the
    /// inventory, so the shop row shows the same number the Jogress spends.
    func stock(of id: ShopItemID) -> Int {
        id == .dnaCharge ? dna.stock : (inventory[id] ?? 0)
    }
}

/// The ten factions of the Digital World, as digi-api records them. Used by the
/// compass and the graded egg.
enum DigitalField {
    static let all = [
        "Nature Spirits",
        "Nightmare Soldiers",
        "Metal Empire",
        "Wind Guardians",
        "Virus Busters",
        "Deep Savers",
        "Dragon's Roar",
        "Dark Area",
        "Jungle Troopers",
        "Unknown",
    ]
}
