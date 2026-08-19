import Foundation

/// The reference-book text for one Digimon.
///
/// Deliberately *not* in `digidex.bin`. The descriptions alone are 442 KB of
/// prose — they were 49% of the index before it was slimmed, and adding them
/// back would cost 165 KB compressed on an app that is 692 KB in total. Since
/// artwork is already fetched on demand and cached per user, the text rides
/// along the same path: you pay for the forms you actually look at, and nothing
/// is downloaded for a Digimon whose card you never open.
struct DigimonDetail: Codable, Sendable, Hashable {
    var id: Int
    var summary: String?
    var skills: [Skill]
    /// The year the form first appeared, where digi-api records one.
    var year: String?

    struct Skill: Codable, Sendable, Hashable {
        var name: String
        /// digi-api gives romanised Japanese names with an English gloss
        /// alongside; both are worth showing, and neither is always present.
        var translation: String?
    }

    init(id: Int, summary: String? = nil, skills: [Skill] = [], year: String? = nil) {
        self.id = id
        self.summary = summary
        self.skills = skills
        self.year = year
    }

    /// Lenient, like every other persisted type here: this is written to disk
    /// and re-read by later builds, and a cache that stops decoding is a cache
    /// that silently re-downloads everything.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        skills = try c.decodeIfPresent([Skill].self, forKey: .skills) ?? []
        year = try c.decodeIfPresent(String.self, forKey: .year)
    }

    var isEmpty: Bool { (summary ?? "").isEmpty && skills.isEmpty }
}

/// Fetches and caches the reference text, one Digimon at a time.
actor DetailLoader {
    static let shared = DetailLoader()

    private var memory: [Int: DigimonDetail] = [:]
    private var inFlight: [Int: Task<DigimonDetail?, Never>] = [:]

    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DigiTokenBar/details", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Only ever called for a form the tamer has opened, so the request count
    /// tracks curiosity rather than roster size.
    func detail(for entry: DigimonEntry) async -> DigimonDetail? {
        if let cached = memory[entry.id] { return cached }
        if let task = inFlight[entry.id] { return await task.value }

        let task = Task<DigimonDetail?, Never> { [id = entry.id] in
            let fileURL = Self.cacheDirectory.appendingPathComponent("\(id).json")
            if let data = try? Data(contentsOf: fileURL),
               let cached = try? JSONDecoder().decode(DigimonDetail.self, from: data) {
                return cached
            }

            guard let url = URL(string: "https://digi-api.com/api/v1/digimon/\(id)"),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let parsed = Self.parse(data, id: id)
            else { return nil }

            if let encoded = try? JSONEncoder().encode(parsed) {
                try? encoded.write(to: fileURL, options: .atomic)
            }
            return parsed
        }

        inFlight[entry.id] = task
        let detail = await task.value
        inFlight[entry.id] = nil
        if let detail { memory[entry.id] = detail }
        return detail
    }

    /// Pulls the few fields worth showing out of the API payload.
    ///
    /// Hand-rolled rather than modelled as a Codable mirror of the whole
    /// response: the app wants four values out of a document with a dozen
    /// nested arrays, and a full model would break the moment digi-api adds a
    /// field.
    static func parse(_ data: Data, id: Int) -> DigimonDetail? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var detail = DigimonDetail(id: id)

        // The reference book is published in Japanese and English; take the
        // English one, and accept any English variant rather than pinning the
        // exact "en_us" tag the API happens to use today.
        if let descriptions = root["descriptions"] as? [[String: Any]] {
            let english = descriptions.first {
                ($0["language"] as? String)?.lowercased().hasPrefix("en") == true
            }
            let text = english?["description"] as? String
            detail.summary = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let skills = root["skills"] as? [[String: Any]] {
            detail.skills = skills.compactMap { raw in
                guard let name = raw["skill"] as? String, !name.isEmpty else { return nil }
                let gloss = (raw["translation"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return DigimonDetail.Skill(
                    name: name,
                    translation: (gloss?.isEmpty == false && gloss != name) ? gloss : nil
                )
            }
        }

        // Recorded as a number in some entries and a string in others.
        if let year = root["releaseDate"] as? String, !year.isEmpty {
            detail.year = year
        } else if let year = root["releaseDate"] as? Int {
            detail.year = String(year)
        }

        return detail.isEmpty && detail.year == nil ? nil : detail
    }
}
