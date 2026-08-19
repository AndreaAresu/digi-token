import AppKit

/// The numbers behind the partner: totals, the live 5-hour window, and recent
/// history per tool.
@MainActor
final class UsagePane: NSView {
    private let monitor: UsageMonitor

    private let picker = NSSegmentedControl()
    private var tiles: [StatTile] = []
    private let blockHeader = UI.label("", size: 9, weight: .medium, mono: true)
    private let blockBar = BarView()
    private let blockStats = UI.label("", size: 10, color: .secondaryLabelColor, mono: true)
    private let histogram = HistogramView()
    private let emptyLabel = UI.label("", size: 11, color: .secondaryLabelColor, align: .center)
    private let privacyNote = UI.label(
        "DigiTokenBar reads Claude Code and Codex logs already on this Mac. Nothing leaves the machine.",
        size: 9, color: .tertiaryLabelColor, align: .center
    )
    private var contentStack: NSStackView!
    private var selected: ProviderID?

    init(monitor: UsageMonitor) {
        self.monitor = monitor
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        picker.segmentStyle = .automatic
        picker.target = self
        picker.action = #selector(pickProvider)
        picker.translatesAutoresizingMaskIntoConstraints = false

        tiles = [
            StatTile(label: "Today"), StatTile(label: "This week"),
            StatTile(label: "This month"), StatTile(label: "All time"),
        ]
        let row1 = UI.stack(.horizontal, spacing: 8, [tiles[0], tiles[1]])
        let row2 = UI.stack(.horizontal, spacing: 8, [tiles[2], tiles[3]])
        row1.distribution = .fillEqually
        row2.distribution = .fillEqually

        let blockInner = UI.stack(.vertical, spacing: 5, [blockHeader, blockBar, blockStats])
        let blockCard = UI.card(blockInner)
        blockCard.translatesAutoresizingMaskIntoConstraints = false

        let historyStack = UI.stack(.vertical, spacing: 5, [
            UI.caption("Recent 5-hour windows"), histogram,
        ])

        emptyLabel.maximumNumberOfLines = 3
        emptyLabel.lineBreakMode = .byWordWrapping
        privacyNote.maximumNumberOfLines = 3
        privacyNote.lineBreakMode = .byWordWrapping

        contentStack = UI.stack(.vertical, spacing: 12, [
            picker, row1, row2, blockCard, historyStack, emptyLabel, privacyNote,
        ])
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            picker.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            row1.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            row2.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            blockCard.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            historyStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            blockBar.widthAnchor.constraint(equalTo: blockInner.widthAnchor),
            histogram.widthAnchor.constraint(equalTo: historyStack.widthAnchor),
            emptyLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            privacyNote.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])
        self.blockCard = blockCard
        self.historyStack = historyStack
    }

    private var blockCard: NSView!
    private var historyStack: NSView!

    func refresh() {
        let providers = monitor.snapshot.detected
        let hasData = !providers.isEmpty

        picker.isHidden = providers.count < 2
        blockCard.isHidden = !hasData
        historyStack.isHidden = !hasData
        emptyLabel.isHidden = hasData
        tiles.forEach { $0.isHidden = !hasData }

        guard hasData else {
            emptyLabel.stringValue = monitor.lastError ?? "Looking for local logs…"
            return
        }

        if picker.segmentCount != providers.count {
            picker.segmentCount = providers.count
            for (index, usage) in providers.enumerated() {
                picker.setLabel(usage.provider.displayName, forSegment: index)
            }
            picker.selectedSegment = 0
        }

        let usage = providers.first { $0.provider == selected } ?? providers[0]

        tiles[0].set(
            value: TokenFormatter.short(usage.today.billable),
            hint: TokenFormatter.cost(usage.todayCost)
        )
        tiles[1].set(value: TokenFormatter.short(usage.week.billable), hint: "billable")
        tiles[2].set(
            value: TokenFormatter.short(usage.month.billable),
            hint: TokenFormatter.cost(usage.monthCost)
        )
        tiles[3].set(
            value: TokenFormatter.short(usage.allTime.billable),
            hint: "\(usage.sessionCount) sessions"
        )

        if let block = usage.currentBlock {
            blockCard.isHidden = false
            blockHeader.stringValue =
                "CURRENT WINDOW · \(TokenFormatter.duration(block.remaining)) left"
            blockHeader.textColor = Theme.accent
            blockBar.value = block.elapsed / UsageAggregator.blockDuration
            blockStats.stringValue =
                "\(TokenFormatter.short(block.counts.billable)) used   ·   "
                + "\(TokenFormatter.short(Int(block.burnRate)))/h   ·   "
                + "~\(TokenFormatter.short(block.projectedTotal)) projected"
        } else {
            blockCard.isHidden = true
        }

        let recent = usage.recentBlocks.suffix(14)
        histogram.values = recent.map(\.counts.billable)
        histogram.activeIndex = recent.last?.isActive == true ? recent.count - 1 : nil
    }

    @objc private func pickProvider() {
        let providers = monitor.snapshot.detected
        guard picker.selectedSegment >= 0, picker.selectedSegment < providers.count else { return }
        selected = providers[picker.selectedSegment].provider
        refresh()
    }
}
