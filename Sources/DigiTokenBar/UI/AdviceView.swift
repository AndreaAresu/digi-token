import AppKit

/// One piece of coaching: what to change, the number that says so, and why.
///
/// The evidence line sits directly under the title rather than at the end, so a
/// tamer who disagrees with the claim can check it before reading the argument
/// for it.
@MainActor
final class AdviceRow: NSView {
    /// Card insets plus the pane's own margins, so the wrapped text knows how
    /// wide it is allowed to be before Auto Layout has measured anything.
    static let textWidth = Theme.contentWidth - 16

    init(_ advice: Advice) {
        super.init(frame: .zero)

        let title = UI.wraps(
            UI.label(advice.title, size: 11, weight: .semibold), lines: 2, width: Self.textWidth
        )
        let evidence = UI.wraps(
            UI.label(advice.evidence, size: 9, color: Theme.accent, mono: true),
            lines: 3, width: Self.textWidth
        )
        let detail = UI.wraps(
            UI.label(advice.detail, size: 10, color: .secondaryLabelColor), width: Self.textWidth
        )

        let stack = UI.stack(.vertical, spacing: 4, [title, evidence, detail])
        let card = UI.card(stack)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// The coach section of the Usage pane.
///
/// Combined across tools on purpose: the question it answers is how the tamer
/// works, and that does not change when they switch agent halfway through an
/// afternoon.
@MainActor
final class CoachSection: NSView {
    private let rows = UI.stack(.vertical, spacing: 8, [])
    private let summary = UI.label("", size: 10, color: .secondaryLabelColor, mono: true)
    private let verdict = UI.label("", size: 11, weight: .semibold)

    init() {
        super.init(frame: .zero)

        UI.wraps(verdict, lines: 2, width: AdviceRow.textWidth)
        UI.wraps(summary, lines: 2, width: AdviceRow.textWidth)

        let head = UI.stack(.vertical, spacing: 3, [verdict, summary])
        let stack = UI.stack(.vertical, spacing: 8, [
            UI.caption("Coach · all tools"), head, rows,
        ])
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            head.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rows.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ report: CoachReport) {
        rows.arrangedSubviews.forEach {
            rows.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        guard !report.isTooEarly else {
            verdict.stringValue = "Not enough history yet"
            verdict.textColor = .secondaryLabelColor
            summary.stringValue =
                "\(report.sessions) session\(report.sessions == 1 ? "" : "s") so far — "
                + "the coach waits for \(Coach.minSessions) before it claims anything."
            return
        }

        summary.stringValue =
            "\(Int(report.cacheShare * 100))% cache   ·   "
            + "\(String(format: "%.1f", report.amortisation))× reuse   ·   "
            + "median session \(TokenFormatter.short(report.medianSession))"

        if report.advice.isEmpty {
            verdict.stringValue = "Nothing to flag"
            verdict.textColor = Theme.attribute(.data)
            return
        }

        verdict.stringValue = report.advice.count == 1
            ? "One thing worth a look"
            : "\(report.advice.count) things worth a look"
        verdict.textColor = Theme.accent

        for advice in report.advice {
            let row = AdviceRow(advice)
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
    }
}
