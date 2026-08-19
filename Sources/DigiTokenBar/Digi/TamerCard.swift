import Foundation

/// A tamer and their partner, in a form that can be pasted into a chat window.
///
/// This is the only thing in the app that ever leaves the machine, and it leaves
/// only when the tamer copies it themselves. It carries no logs, no project
/// names, no token timings and no file paths — just the partner's identity, the
/// handful of figures a Jogress needs, and whatever name the tamer chose to put
/// on it.
struct TamerCard: Codable, Sendable, Hashable, Identifiable {
    /// Bumped only when a field the reader must understand changes meaning.
    /// Additions do not bump it: the decoder below tolerates them in both
    /// directions.
    static let currentVersion = 1

    var version = TamerCard.currentVersion
    var tamer: String
    var issuedAt = Date()

    // The partner, in enough detail to fuse with.
    var seed: UInt64
    var digimonID: Int
    var stage: DigiStage
    var isXAntibody: Bool
    var lineage: [Int]
    var nickname: String?
    var tokens: Int

    // The tamer, in enough detail to be worth showing off.
    var attribute: DigiAttribute
    var streak: Int
    var careMistakes: Int
    var dexSeen: Int
    var dexTotal: Int

    /// Cards are keyed by the partner they describe, so re-importing a friend's
    /// updated card replaces the old one instead of stacking up beside it.
    var id: String { "\(seed)-\(digimonID)" }

    var entry: DigimonEntry? { DigiDex.shared.entry(digimonID) }

    var displayName: String {
        if let nickname, !nickname.isEmpty { return nickname }
        return entry?.name ?? "DigiTama"
    }

    var completion: Double {
        dexTotal > 0 ? Double(dexSeen) / Double(dexTotal) : 0
    }

    /// The partner as this app models one, so a visiting card can go straight
    /// into `Digivolution.jogress` without a second code path for guests.
    var partner: Partner {
        var partner = Partner(seed: seed)
        partner.digimonID = digimonID
        partner.stage = stage
        partner.isXAntibody = isXAntibody
        partner.lineage = lineage
        partner.nickname = nickname
        partner.tokens = tokens
        return partner
    }

    init(
        tamer: String, seed: UInt64, digimonID: Int, stage: DigiStage,
        isXAntibody: Bool, lineage: [Int], nickname: String?, tokens: Int,
        attribute: DigiAttribute, streak: Int, careMistakes: Int,
        dexSeen: Int, dexTotal: Int, issuedAt: Date = Date()
    ) {
        self.tamer = tamer
        self.seed = seed
        self.digimonID = digimonID
        self.stage = stage
        self.isXAntibody = isXAntibody
        self.lineage = lineage
        self.nickname = nickname
        self.tokens = tokens
        self.attribute = attribute
        self.streak = streak
        self.careMistakes = careMistakes
        self.dexSeen = dexSeen
        self.dexTotal = dexTotal
        self.issuedAt = issuedAt
    }

    /// Decoded field by field, for the same reason every persisted type here is.
    ///
    /// A card is worse than a save file in one respect: it is written by a copy
    /// of the app the reader does not control. A friend on a newer build must
    /// not hand over something this version refuses outright, so every field
    /// past the ones a fusion actually needs is optional.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        tamer = try c.decodeIfPresent(String.self, forKey: .tamer) ?? "Tamer"
        issuedAt = try c.decodeIfPresent(Date.self, forKey: .issuedAt) ?? Date()
        seed = try c.decode(UInt64.self, forKey: .seed)
        digimonID = try c.decode(Int.self, forKey: .digimonID)
        stage = try c.decodeIfPresent(DigiStage.self, forKey: .stage) ?? .child
        isXAntibody = try c.decodeIfPresent(Bool.self, forKey: .isXAntibody) ?? false
        lineage = try c.decodeIfPresent([Int].self, forKey: .lineage) ?? []
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname)
        tokens = try c.decodeIfPresent(Int.self, forKey: .tokens) ?? 0
        attribute = try c.decodeIfPresent(DigiAttribute.self, forKey: .attribute) ?? .free
        streak = try c.decodeIfPresent(Int.self, forKey: .streak) ?? 0
        careMistakes = try c.decodeIfPresent(Int.self, forKey: .careMistakes) ?? 0
        dexSeen = try c.decodeIfPresent(Int.self, forKey: .dexSeen) ?? 0
        dexTotal = try c.decodeIfPresent(Int.self, forKey: .dexTotal) ?? 0
    }
}

/// Turns a card into something pasteable and back.
///
/// The wire format is `DTB1.<base64url payload>.<checksum>`. The checksum is
/// there because the transport is a chat window: codes get wrapped, truncated
/// and autocorrected, and the failure that matters is a damaged card decoding
/// into a *different* partner rather than into an error.
enum TamerCardCodec {
    static let prefix = "DTB1"

    enum DecodeError: Error, Equatable {
        case notACard
        case damaged
        case unreadable
        /// The card was written by a version whose meaning this build cannot
        /// vouch for.
        case tooNew(Int)
    }

    static func encode(_ card: TamerCard) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Stable ordering, so copying the same card twice produces the same
        // string and a tamer can see it did not change.
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(card) else { return "" }
        let payload = base64url(data)
        return "\(prefix).\(payload).\(checksum(payload))"
    }

    static func decode(_ raw: String) throws -> TamerCard {
        // Chat clients wrap long strings; rejoining is the difference between a
        // card that works and one the tamer has to hand-repair.
        let cleaned = raw.filter { !$0.isWhitespace }
        let parts = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].uppercased() == prefix else {
            throw DecodeError.notACard
        }
        let payload = String(parts[1])
        guard checksum(payload) == String(parts[2]).lowercased() else {
            throw DecodeError.damaged
        }
        guard let data = data(fromBase64url: payload) else { throw DecodeError.damaged }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let card = try? decoder.decode(TamerCard.self, from: data) else {
            throw DecodeError.unreadable
        }
        guard card.version <= TamerCard.currentVersion else {
            throw DecodeError.tooNew(card.version)
        }
        return card
    }

    // MARK: - Wire helpers

    /// Base64 without `+`, `/` or padding, so the code survives being pasted
    /// into a URL, a shell, or a chat client that linkifies punctuation.
    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func data(fromBase64url string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    /// FNV-1a, 32 bits. Not a security measure — nobody is defending anything
    /// here — just enough to catch a truncated or mangled paste.
    static func checksum(_ string: String) -> String {
        var hash: UInt32 = 0x811C_9DC5
        for byte in string.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return String(format: "%08x", hash)
    }
}
