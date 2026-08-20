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
    }

    /// Matched by substring against the model id, longest pattern first, so
    /// `claude-haiku-4-5` does not get swallowed by a broader `claude` rule.
    private static let table: [(pattern: String, rate: Rate)] = [
        ("claude-fable", Rate(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.50)),
        ("claude-mythos", Rate(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.50)),
        ("claude-opus", Rate(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.50)),
        ("claude-sonnet", Rate(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.30)),
        ("claude-haiku", Rate(input: 1, output: 5, cacheWrite: 1.25, cacheRead: 0.10)),
        ("gpt-5", Rate(input: 1.25, output: 10, cacheWrite: 1.25, cacheRead: 0.125)),
        ("codex", Rate(input: 1.25, output: 10, cacheWrite: 1.25, cacheRead: 0.125)),
        ("o3", Rate(input: 2, output: 8, cacheWrite: 2, cacheRead: 0.50)),
    ]

    /// What an unrecognised model is priced at, so a cost estimate is never
    /// simply absent. It is a guess, and everything that reads it has to be able
    /// to find out that it is one — see `isKnown`.
    private static let fallback = Rate(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.30)

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
            + Double(counts.cacheCreation) * r.cacheWrite
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
