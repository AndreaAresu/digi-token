import AppKit

/// What is left before a limit, in the only two forms this app can honestly
/// offer them.
///
/// The first is a **reading**: Codex writes its own rate-limit state onto every
/// turn — how much of each window is used, and when it rolls over — so that is
/// shown as the gauge it is. Claude Code writes nothing of the sort until a
/// limit actually stops a turn, and then only the type of window and its reset
/// time; there is no allowance in those logs to be a percentage of.
///
/// The second is a **comparison**: this window against the busiest window on
/// record, this week against the busiest week. That is not a quota and is never
/// labelled as one. It is the honest answer to "how much room is left" from an
/// app that can see what you spent and cannot see what you are allowed.
@MainActor
final class LimitsSection: NSView {
    private let rows = UI.stack(.vertical, spacing: 8, [])
    private let note = UI.label("", size: 9, color: .tertiaryLabelColor)

    init() {
        super.init(frame: .zero)

        UI.wraps(note, lines: 3)
        let stack = UI.stack(.vertical, spacing: 7, [
            UI.caption("Limits & pace"), rows, note,
        ])
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            rows.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ usage: ProviderUsage) {
        rows.arrangedSubviews.forEach {
            rows.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let live = usage.limits.filter { $0.isCurrent() }
        let expired = usage.limits.filter { !$0.isCurrent() }
        for window in live { add(gauge: window) }

        // The pace rows are always shown. They are the part that exists for
        // every tool, because they are measured from usage rather than read out
        // of a tool's own bookkeeping.
        // Only while a window is actually open. "0 of 234K busiest" under a
        // closed window is a bar that measures nothing.
        if usage.peakBlock > 0, let block = usage.currentBlock {
            let used = block.counts.billable
            add(
                label: "This 5-hour window",
                value: "\(TokenFormatter.short(used)) of \(TokenFormatter.short(usage.peakBlock)) busiest",
                fraction: Double(used) / Double(usage.peakBlock),
                tint: Theme.accent
            )
        }
        if usage.peakWeek > 0 {
            add(
                label: "This week",
                value: "\(TokenFormatter.short(usage.week.billable)) of "
                    + "\(TokenFormatter.short(usage.peakWeek)) busiest",
                fraction: Double(usage.week.billable) / Double(usage.peakWeek),
                tint: Theme.accent
            )
        }

        note.stringValue = Self.note(live: live, expired: expired, tool: usage.provider.displayName)
    }

    /// An expired reading is not shown as a gauge — a five-hour window from a
    /// fortnight ago describes nothing — but it is worth saying that one exists
    /// and how to refresh it. A section that simply goes quiet looks broken.
    private static func note(live: [RateWindow], expired: [RateWindow], tool: String) -> String {
        if !live.isEmpty {
            return "The gauge is what the tool itself last wrote down. The bars below it compare "
                + "against your own record, which is not a limit."
        }
        if let last = expired.compactMap(\.observedAt).max() {
            return "\(tool) last wrote down its usage \(relative.localizedString(for: last, relativeTo: Date()))"
                + ", and those windows have since reset. Ask it for its usage to refresh the figure. "
                + "The bars above are your own record, not a limit."
        }
        return "\(tool) has not written down an allowance yet, so there is no quota to show. "
            + "The bars above compare against your own busiest window and week — a high-water "
            + "mark, not a limit."
    }

    private func add(gauge window: RateWindow) {
        let resets = window.resetsAt.map { Self.relative.localizedString(for: $0, relativeTo: Date()) }

        if let fraction = window.usedFraction {
            var value = "\(Int((fraction * 100).rounded()))% used"
            if let resets { value += " · resets \(resets)" }
            add(
                label: window.label.capitalizedFirst,
                value: value,
                fraction: fraction,
                // The bar earns the warning colour from the tool's own figure,
                // not from a threshold this app invented.
                tint: fraction >= 0.9 ? Theme.danger : Theme.accent,
                footnote: Self.staleness(of: window)
            )
            return
        }

        // No gauge, only a refusal the tool recorded. A full bar is the truth
        // here: the allowance is gone until it resets.
        add(
            label: window.label.capitalizedFirst,
            value: resets.map { "reached · clears \($0)" } ?? "reached",
            fraction: 1,
            tint: Theme.danger,
            footnote: Self.staleness(of: window)
        )
    }

    private func add(
        label: String, value: String, fraction: Double, tint: NSColor, footnote: String? = nil
    ) {
        let title = UI.label(label, size: 10, weight: .medium)
        let figure = UI.label(value, size: 9, color: .secondaryLabelColor, mono: true)
        figure.setContentHuggingPriority(.required, for: .horizontal)

        let bar = BarView()
        bar.value = max(0, min(1, fraction))
        bar.tint = tint
        bar.setAccessibilityLabel(label)
        bar.setAccessibilityValue(value)

        var views: [NSView] = [
            UI.stack(.horizontal, spacing: 6, [title, UI.spacer(), figure]), bar,
        ]
        if let footnote {
            views.append(UI.label(footnote, size: 8, color: .tertiaryLabelColor))
        }

        let row = UI.stack(.vertical, spacing: 3, views)
        rows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        views.forEach { $0.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true }
    }

    /// A gauge is only as current as the moment the tool wrote it. Saying when
    /// that was is the difference between a reading and a claim — a percentage
    /// from three weeks ago describes three weeks ago.
    private static func staleness(of window: RateWindow) -> String? {
        guard let observed = window.observedAt else { return nil }
        guard Date().timeIntervalSince(observed) > 2 * 3600 else { return nil }
        return "as the tool last wrote it, \(relative.localizedString(for: observed, relativeTo: Date()))"
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

extension String {
    /// Upper-cases the first character only, leaving "5-hour limit" alone rather
    /// than shouting it the way `capitalized` would.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
