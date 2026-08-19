import Compression
import Foundation

/// One entry of the bundled index.
///
/// Deliberately narrow: it holds only what the app reads. Reference-book
/// descriptions, attack lists and reverse-evolution edges are available from
/// digi-api but were 61% of the shipped file and were never displayed, so the
/// generator discards them.
struct DigimonEntry: Codable, Sendable, Hashable, Identifiable {
    let id: Int
    let name: String
    let stage: String
    let side: Bool
    let x: Bool
    let attrs: [String]
    let types: [String]
    let fields: [String]
    let img: String
    let next: [Int]

    var attribute: DigiAttribute {
        attrs.compactMap(DigiAttribute.init(raw:)).first ?? .free
    }

    var primaryField: String? { fields.first }

    /// The English release names most people know differ from the Japanese
    /// stage names the reference data uses.
    var stageLabel: DigiStage? { DigiStage(raw: stage) }
}

/// The canonical ladder a partner climbs. digi-api uses the Japanese naming;
/// we keep it as the source of truth and show the dub name alongside, because
/// "Champion" and "Adult" are the same rung and fans use both.
enum DigiStage: Int, Codable, Sendable, CaseIterable, Comparable {
    case babyI = 0
    case babyII
    case child
    case adult
    case perfect
    case ultimate

    init?(raw: String) {
        switch raw {
        case "Baby I": self = .babyI
        case "Baby II": self = .babyII
        case "Child": self = .child
        case "Adult": self = .adult
        case "Perfect": self = .perfect
        case "Ultimate": self = .ultimate
        default: return nil
        }
    }

    var rawName: String {
        switch self {
        case .babyI: "Baby I"
        case .babyII: "Baby II"
        case .child: "Child"
        case .adult: "Adult"
        case .perfect: "Perfect"
        case .ultimate: "Ultimate"
        }
    }

    /// The name used in the English dub, which most players recognise faster.
    var dubName: String {
        switch self {
        case .babyI: "Fresh"
        case .babyII: "In-Training"
        case .child: "Rookie"
        case .adult: "Champion"
        case .perfect: "Ultimate"
        case .ultimate: "Mega"
        }
    }

    var next: DigiStage? { DigiStage(rawValue: rawValue + 1) }

    static func < (lhs: DigiStage, rhs: DigiStage) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Digimon's rock-paper-scissors alignment. We reuse it as a read on *how* the
/// tamer works rather than as combat maths.
enum DigiAttribute: String, Codable, Sendable, CaseIterable {
    case vaccine = "Vaccine"
    case data = "Data"
    case virus = "Virus"
    case free = "Free"

    init?(raw: String) {
        switch raw {
        case "Vaccine": self = .vaccine
        case "Data": self = .data
        case "Virus": self = .virus
        case "Free", "Variable", "Unknown", "No Data": self = .free
        default: return nil
        }
    }

    var symbol: String {
        switch self {
        case .vaccine: "🛡"
        case .data: "◈"
        case .virus: "☠"
        case .free: "✳"
        }
    }
}

/// The bundled roster, loaded once.
///
/// Only data ships in the binary — names, stages, attributes and the evolution
/// graph. Artwork stays remote and is fetched on demand, which keeps the app
/// small and keeps us from redistributing Bandai's assets.
final class DigiDex: @unchecked Sendable {
    static let shared = DigiDex()

    private(set) var all: [DigimonEntry] = []
    private var byID: [Int: DigimonEntry] = [:]
    private var byStage: [DigiStage: [DigimonEntry]] = [:]
    /// How many forms list each id as a digivolution target.
    ///
    /// The `prior` edges were dropped from the shipped index because nothing
    /// read them; this rebuilds the same information from `next` at load, which
    /// costs one pass over 1,259 entries and keeps the file small.
    private var incoming: [Int: Int] = [:]

    private struct Payload: Codable {
        let version: Int
        let digimon: [DigimonEntry]
    }

    private init() {
        guard let url = DigiDex.indexURL(),
              let packed = try? Data(contentsOf: url),
              let data = DigiDex.inflate(packed),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            assertionFailure("digidex.bin missing or unreadable")
            return
        }
        all = payload.digimon
        byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        byStage = Dictionary(grouping: all.filter { !$0.side }) { $0.stageLabel ?? .child }
        for entry in all {
            for target in entry.next { incoming[target, default: 0] += 1 }
        }
    }

    /// The index lives in the app bundle's Resources when installed, and beside
    /// the sources when running from a checkout — so both `build-app.sh` output
    /// and a bare `swiftc` run find it without a package manager involved.
    private static func indexURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "digidex", withExtension: "bin") {
            return bundled
        }
        let fallbacks = [
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // Digi
                .deletingLastPathComponent()   // DigiTokenBar
                .appendingPathComponent("Resources/digidex.bin"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/DigiTokenBar/Resources/digidex.bin"),
        ]
        return fallbacks.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Expands the raw-DEFLATE index.
    ///
    /// The uncompressed index is 329 KB of JSON; deflated it is 51 KB, which is
    /// most of the app's download. `tools/build_index.py` writes raw DEFLATE
    /// with no zlib header precisely because that is what `COMPRESSION_ZLIB`
    /// expects.
    static func inflate(_ packed: Data) -> Data? {
        // Generous but bounded: the index is a known size and a corrupt file
        // should fail rather than be allowed to allocate without limit.
        let capacity = 4 << 20
        var output = Data(count: capacity)

        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress
            else { return 0 }
            return packed.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_decode_buffer(
                    destinationBase, capacity,
                    sourceBase, packed.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }

        guard written > 0, written < capacity else { return nil }
        output.removeSubrange(written...)
        return output
    }

    func entry(_ id: Int) -> DigimonEntry? { byID[id] }

    /// How many recorded lines digivolve into this form.
    func routesInto(_ id: Int) -> Int { incoming[id] ?? 0 }

    func rarity(of entry: DigimonEntry) -> DigiRarity {
        DigiRarity(routes: routesInto(entry.id))
    }

    func entries(stage: DigiStage) -> [DigimonEntry] { byStage[stage] ?? [] }

    func entries(named name: String) -> [DigimonEntry] {
        all.filter { $0.name.localizedCaseInsensitiveContains(name) }
    }

    var stageCounts: [DigiStage: Int] {
        byStage.mapValues(\.count)
    }
}

/// How hard a form is to arrive at, read off the evolution graph rather than
/// invented.
///
/// The thresholds come from the real distribution across the 1,259 shipped
/// entries: 9% have no recorded route into them at all, a quarter have two or
/// fewer, and the median form has seven. Nothing here is a balance knob — it is
/// a description of the graph, and the exact route count is always shown next to
/// the label so the claim can be checked.
enum DigiRarity: Sendable, Hashable {
    case unreachable
    case rare
    case uncommon
    case common

    init(routes: Int) {
        switch routes {
        case 0: self = .unreachable
        case 1...2: self = .rare
        case 3...6: self = .uncommon
        default: self = .common
        }
    }

    var label: String {
        switch self {
        case .unreachable: "Off the graph"
        case .rare: "Rare"
        case .uncommon: "Uncommon"
        case .common: "Common"
        }
    }

    /// The scale the grid draws. Three, because there are three tiers that the
    /// route count actually separates — a fourth star would have to be invented.
    static let starScale = 3

    /// Filled stars out of `starScale`, or `nil` for a form nothing routes into.
    ///
    /// "Off the graph" is deliberately not the top of the scale. It is a
    /// different statement: not "harder to reach than rare" but "not reachable
    /// by any recorded line at all", which is how a fallback branch or a Jogress
    /// can hand you one without it being an achievement. Giving it four stars
    /// would be claiming something the graph does not say, so it gets its own
    /// mark instead.
    var stars: Int? {
        switch self {
        case .common: 1
        case .uncommon: 2
        case .rare: 3
        case .unreachable: nil
        }
    }

    /// Said plainly, because "Off the graph" on its own sounds like a bug.
    func detail(routes: Int) -> String {
        switch self {
        case .unreachable:
            "No recorded line digivolves into it — you meet it through a fallback branch or a Jogress"
        case .rare, .uncommon, .common:
            "\(routes) recorded line\(routes == 1 ? "" : "s") digivolve\(routes == 1 ? "s" : "") into it"
        }
    }
}
