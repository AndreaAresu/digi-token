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

        projectStack = UI.stack(.vertical, spacing: 5, [])
        let projectsSection = UI.stack(.vertical, spacing: 6, [
            UI.caption("Where your tokens went"), projectStack,
        ])
        self.projectsSection = projectsSection

        emptyLabel.maximumNumberOfLines = 3
        emptyLabel.lineBreakMode = .byWordWrapping
        privacyNote.maximumNumberOfLines = 3
        privacyNote.lineBreakMode = .byWordWrapping

        contentStack = UI.stack(.vertical, spacing: 12, [
            picker, row1, row2, blockCard, historyStack, projectsSection,
            emptyLabel, privacyNote,
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
            projectsSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            projectStack.widthAnchor.constraint(equalTo: projectsSection.widthAnchor),
            emptyLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            privacyNote.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])
        self.blockCard = blockCard
        self.historyStack = historyStack
    }

    private var blockCard: NSView!
    private var historyStack: NSView!
    private var projectStack: NSStackView!
    private var projectsSection: NSView!

    /// Long tails are noise in a 340-point popover; everything past this is
    /// folded into one "other" row so the total still adds up.
    private let projectLimit = 6

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

        rebuildProjects(usage)
    }

    private func rebuildProjects(_ usage: ProviderUsage) {
        projectStack.arrangedSubviews.forEach {
            projectStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let projects = usage.projects.filter { $0.counts.billable > 0 }
        projectsSection.isHidden = projects.isEmpty
        guard !projects.isEmpty else { return }

        let peak = projects.first?.counts.billable ?? 1
        let shown = projects.prefix(projectLimit)

        for project in shown {
            let row = ProjectRow(project: project, peak: peak)
            projectStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: projectStack.widthAnchor).isActive = true
        }

        let remainder = projects.dropFirst(projectLimit)
        if !remainder.isEmpty {
            let total = remainder.reduce(0) { $0 + $1.counts.billable }
            let label = UI.label(
                "+\(remainder.count) more · \(TokenFormatter.short(total))",
                size: 9, color: .tertiaryLabelColor
            )
            projectStack.addArrangedSubview(label)
        }
    }

    @objc private func pickProvider() {
        let providers = monitor.snapshot.detected
        guard picker.selectedSegment >= 0, picker.selectedSegment < providers.count else { return }
        selected = providers[picker.selectedSegment].provider
        refresh()
    }
}

/// One project in the breakdown: name, share bar, and total.
@MainActor
final class ProjectRow: NSView {
    init(project: ProjectUsage, peak: Int) {
        super.init(frame: .zero)

        let name = UI.label(project.name, size: 10, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        let total = UI.label(
            TokenFormatter.short(project.counts.billable),
            size: 10, color: .secondaryLabelColor, mono: true
        )
        total.setContentHuggingPriority(.required, for: .horizontal)

        let bar = BarView()
        bar.value = peak > 0 ? Double(project.counts.billable) / Double(peak) : 0
        // Anything worked on today is called out; the rest are the muted history
        // behind it.
        bar.tint = project.today.billable > 0
            ? Theme.accent
            : Theme.accent.withAlphaComponent(0.4)

        let header = UI.stack(.horizontal, spacing: 6, [name, UI.spacer(), total])
        let stack = UI.stack(.vertical, spacing: 2, [header, bar])
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        var tip = "\(project.name) · \(TokenFormatter.grouped(project.counts.billable)) billable tokens"
        if project.today.billable > 0 {
            tip += "\n\(TokenFormatter.short(project.today.billable)) today"
        }
        toolTip = tip
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
