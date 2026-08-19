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

    func entries(stage: DigiStage) -> [DigimonEntry] { byStage[stage] ?? [] }

    func entries(named name: String) -> [DigimonEntry] {
        all.filter { $0.name.localizedCaseInsensitiveContains(name) }
    }

    var stageCounts: [DigiStage: Int] {
        byStage.mapValues(\.count)
    }
}
