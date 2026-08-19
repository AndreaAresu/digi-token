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

    func stock(of id: ShopItemID) -> Int { inventory[id] ?? 0 }
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
