import Foundation

/// Per-million-token prices used to turn counts into a cost estimate.
///
/// This is a convenience figure, not a bill. Subscription plans do not charge
/// per token at all, so the number answers "what would this have cost on the
/// API" — which is the comparison people actually want.
enum ModelPricing {
    struct Rate: Sendable {
        let input: Double
        let output: Double
        let cacheWrite: Double
        let cacheRead: Double
        /// A cache write held for an hour instead of five minutes. Anthropic
        /// bills it at 2× input against the 1.25× of the short TTL, and Claude
        /// Code uses the long one, so pricing every write as short understated
        /// the biggest line in the estimate.
        let cacheWrite1h: Double

        /// Anthropic's cache multipliers are fixed against the input rate:
        /// 1.25× for a five-minute write, 2× for an hour, 0.1× for a read.
        static func anthropic(input: Double, output: Double) -> Rate {
            Rate(
                input: input, output: output,
                cacheWrite: input * 1.25, cacheRead: input * 0.1,
                cacheWrite1h: input * 2
            )
        }

        /// A provider with no published long-TTL cache tier prices both the
        /// same, which is what OpenAI does.
        static func flat(input: Double, output: Double, cacheWrite: Double, cacheRead: Double) -> Rate {
            Rate(
                input: input, output: output, cacheWrite: cacheWrite,
                cacheRead: cacheRead, cacheWrite1h: cacheWrite
            )
        }
    }

    /// Matched by substring against the model id, **in this order**, so a
    /// specific generation is found before the family rule that would otherwise
    /// swallow it — `claude-opus-5` must not be priced by a bare `claude-opus`
    /// rule written for the generation before it.
    ///
    /// Opus dropped from $15/$75 to $5/$25 with the 4.6 generation. Keeping the
    /// old figure made this app overstate a day's work by roughly three times,
    /// which is worse than showing nothing.
    private static let table: [(pattern: String, rate: Rate)] = [
        ("claude-fable", .anthropic(input: 10, output: 50)),
        ("claude-mythos", .anthropic(input: 10, output: 50)),
        ("claude-opus-5", .anthropic(input: 5, output: 25)),
        ("claude-opus-4-8", .anthropic(input: 5, output: 25)),
        ("claude-opus-4-7", .anthropic(input: 5, output: 25)),
        ("claude-opus-4-6", .anthropic(input: 5, output: 25)),
        // Opus 4.5 and everything before it, which really did cost this much.
        ("claude-opus", .anthropic(input: 15, output: 75)),
        ("claude-sonnet", .anthropic(input: 3, output: 15)),
        ("claude-haiku", .anthropic(input: 1, output: 5)),
        ("gpt-5", .flat(input: 1.25, output: 10, cacheWrite: 1.25, cacheRead: 0.125)),
        ("codex", .flat(input: 1.25, output: 10, cacheWrite: 1.25, cacheRead: 0.125)),
        ("o3", .flat(input: 2, output: 8, cacheWrite: 2, cacheRead: 0.50)),
    ]

    /// What an unrecognised model is priced at, so a cost estimate is never
    /// simply absent. It is a guess, and everything that reads it has to be able
    /// to find out that it is one — see `isKnown`.
    private static let fallback = Rate.anthropic(input: 3, output: 15)

    private static func match(_ model: String) -> Rate? {
        let lowered = model.lowercased()
        for entry in table where lowered.contains(entry.pattern) {
            return entry.rate
        }
        return nil
    }

    static func rate(for model: String) -> Rate {
        match(model) ?? fallback
    }

    /// Whether the table recognises this model at all.
    ///
    /// The fallback used to be invisible: a model id nobody had added yet was
    /// priced like a Sonnet and nothing said so. That is fine for a rough total
    /// and not fine for the coach, which claims *which* model is carrying the
    /// bill — a guessed rate on enough tokens can change the answer. Anything
    /// making a claim about cost asks this first.
    static func isKnown(_ model: String) -> Bool {
        match(model) != nil
    }

    static func cost(model: String, counts: TokenCounts) -> Double {
        let r = rate(for: model)
        return (Double(counts.input) * r.input
            + Double(counts.output) * r.output
            + Double(counts.cacheCreation5m) * r.cacheWrite
            + Double(counts.cacheCreation1h) * r.cacheWrite1h
            + Double(counts.cacheRead) * r.cacheRead) / 1_000_000
    }
}

enum TokenFormatter {
    /// Compact form for the menu bar, where horizontal space is the constraint.
    static func short(_ value: Int) -> String {
        switch value {
        case ..<1_000: "\(value)"
        case ..<1_000_000: String(format: "%.1fK", Double(value) / 1_000)
        case ..<1_000_000_000: String(format: "%.1fM", Double(value) / 1_000_000)
        default: String(format: "%.2fB", Double(value) / 1_000_000_000)
        }
    }

    static func grouped(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func cost(_ value: Double) -> String {
        value >= 100 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}
