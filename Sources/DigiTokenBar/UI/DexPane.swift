import AppKit

/// The collection screen: everything the tamer has met, and everything still out
/// there.
///
/// Three states, deliberately. Met forms show their artwork and open a card;
/// forms one digivolution away show a flattened silhouette; the rest stay a
/// dashed mark whose image is never fetched. Names are always visible, so search
/// still works on the whole roster.
@MainActor
final class DexPane: NSView {
    private let store: PartnerStore

    private let counterLabel = UI.label("", size: 13, weight: .bold, rounded: true, mono: true)
    private let xLabel = UI.label("", size: 10, weight: .bold, color: Theme.danger)
    private let raisedLabel = UI.label("", size: 10, color: .secondaryLabelColor)
    private let bar = BarView()
    private let searchField = NSSearchField()
    private let stageMenu = NSPopUpButton()
    private let grid = UI.stack(.vertical, spacing: 8, [])
    private let scroll = NSScrollView()
    private let detail = DexDetailView()

    /// Forms one step from something the tamer has met.
    ///
    /// These are the only unmet Digimon whose artwork is fetched. Silhouetting
    /// the whole roster would mean pulling 1,259 images from digi-api the first
    /// time this tab is opened, which is both rude to a free API and the
    /// opposite of the discovery the grid is for. A form you could reach next is
    /// a tease; the other thousand are a spoiler.
    private var reachable: Set<Int> = []

    /// Building 1200 sprite views at once would stall the popover; the tamer
    /// narrows with search instead of scrolling the whole roster.
    private let displayLimit = 160

    init(store: PartnerStore) {
        self.store = store
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        searchField.placeholderString = "Search"
        searchField.font = .systemFont(ofSize: 11)
        searchField.target = self
        searchField.action = #selector(filterChanged)
        searchField.sendsSearchStringImmediately = false

        stageMenu.addItem(withTitle: "All stages")
        for stage in DigiStage.allCases {
            stageMenu.addItem(withTitle: "\(stage.dubName) (\(stage.rawName))")
        }
        stageMenu.target = self
        stageMenu.action = #selector(filterChanged)
        stageMenu.font = .systemFont(ofSize: 11)

        bar.setAccessibilityLabel("DigiDex completion")
        let header = UI.stack(.horizontal, spacing: 6, [
            counterLabel, UI.label("met", size: 10, color: .secondaryLabelColor),
            UI.spacer(), xLabel, raisedLabel,
        ])
        let controls = UI.stack(.horizontal, spacing: 6, [searchField, stageMenu])
        controls.distribution = .fill
        stageMenu.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let clip = FlippedView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: clip.topAnchor),
            grid.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
        ])
        scroll.documentView = clip

        let root = UI.stack(.vertical, spacing: 8, [header, bar, controls, scroll])
        addSubview(root)

        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.isHidden = true
        addSubview(detail)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            header.widthAnchor.constraint(equalTo: root.widthAnchor),
            bar.widthAnchor.constraint(equalTo: root.widthAnchor),
            controls.widthAnchor.constraint(equalTo: root.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor),
            clip.widthAnchor.constraint(equalTo: scroll.widthAnchor),

            detail.topAnchor.constraint(equalTo: topAnchor),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor),
            detail.leadingAnchor.constraint(equalTo: leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    func refresh() {
        let total = DigiDex.shared.all.count
        counterLabel.stringValue = "\(store.seenDigimon.count) / \(total)"
        bar.value = store.completion
        // The percentage rounds to zero for the first few hundred forms, which
        // is exactly when the count matters most.
        bar.setAccessibilityValue("\(store.seenDigimon.count) of \(total) met")
        xLabel.stringValue = store.seenXAntibody.isEmpty ? "" : "X ×\(store.seenXAntibody.count)"
        raisedLabel.stringValue = "\(store.collection.count) raised"

        let seen = store.seenDigimon
        reachable = Set(
            seen.compactMap { DigiDex.shared.entry($0)?.next }.joined()
        ).subtracting(seen)

        rebuildGrid()
    }

    private var filtered: [DigimonEntry] {
        var entries = DigiDex.shared.all.filter { !$0.side }

        let index = stageMenu.indexOfSelectedItem
        if index > 0, let stage = DigiStage(rawValue: index - 1) {
            entries = entries.filter { $0.stageLabel == stage }
        }

        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            entries = entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }

        // Met forms first so the collection reads as progress, not as a catalogue.
        return entries.sorted { lhs, rhs in
            let l = store.seenDigimon.contains(lhs.id)
            let r = store.seenDigimon.contains(rhs.id)
            if l != r { return l }
            return lhs.id < rhs.id
        }
    }

    private func rebuildGrid() {
        grid.arrangedSubviews.forEach {
            grid.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let entries = filtered
        let shown = Array(entries.prefix(displayLimit))
        let columns = 4

        for start in stride(from: 0, to: shown.count, by: columns) {
            let slice = shown[start..<min(start + columns, shown.count)]
            var cells: [NSView] = slice.map { entry in
                DexCell(
                    entry: entry,
                    seen: store.seenDigimon.contains(entry.id),
                    reachable: reachable.contains(entry.id)
                ) { [weak self] tapped in
                    self?.present(tapped)
                }
            }
            // Pad the last row so its cells keep the same width as every other.
            while cells.count < columns { cells.append(NSView()) }
            let row = UI.stack(.horizontal, spacing: 6, cells)
            row.distribution = .fillEqually
            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }

        if entries.count > shown.count {
            grid.addArrangedSubview(
                UI.label(
                    "+\(entries.count - shown.count) more — narrow the search to see them.",
                    size: 9, color: .tertiaryLabelColor
                )
            )
        }
        if shown.isEmpty {
            grid.addArrangedSubview(
                UI.label("Nothing matches.", size: 10, color: .secondaryLabelColor)
            )
        }
    }

    /// Only met forms open a card. A silhouette that unfolded into a full
    /// reference entry would hand over exactly what it is meant to withhold.
    private func present(_ entry: DigimonEntry) {
        guard store.seenDigimon.contains(entry.id) else { return }
        detail.show(
            entry,
            xChance: CareEngine.xAntibodyChance(profile: store.profile, hasCharm: false)
        ) { [weak self] in
            self?.detail.isHidden = true
        }
        detail.isHidden = false
    }

    @objc private func filterChanged() { rebuildGrid() }
}

/// One Digimon in the grid.
@MainActor
final class DexCell: NSView {
    private let entry: DigimonEntry
    private let seen: Bool
    private let onTap: (DigimonEntry) -> Void

    init(
        entry: DigimonEntry,
        seen: Bool,
        reachable: Bool,
        onTap: @escaping (DigimonEntry) -> Void
    ) {
        self.entry = entry
        self.seen = seen
        self.onTap = onTap
        super.init(frame: .zero)

        // The cell is one item, not a picture next to a caption next to three
        // stars. Its children are folded in so VoiceOver reads it once.
        setAccessibilityElement(true)
        setAccessibilityRole(seen ? .button : .staticText)
        setAccessibilityChildren([])

        wantsLayer = true
        layer?.cornerRadius = 6
        if seen {
            layer?.backgroundColor = Theme.attribute(entry.attribute)
                .withAlphaComponent(0.13).cgColor
        }

        // Three states, not two: met forms show their artwork, forms one step
        // away show a flattened silhouette, and everything else stays a mark
        // whose image is never fetched at all.
        let sprite = SpriteView(size: 42)
        if seen {
            sprite.show(entry)
        } else if reachable {
            sprite.showSilhouette(entry)
        } else {
            sprite.showUnknown()
        }

        let name = UI.label(
            entry.name, size: 7,
            color: seen ? .labelColor : .tertiaryLabelColor,
            align: .center
        )
        name.maximumNumberOfLines = 2
        name.lineBreakMode = .byTruncatingTail
        name.cell?.wraps = true

        // Rarity is shown for met forms only. It is public information about
        // the graph rather than about the tamer, but printing it under a
        // silhouette would say which of the unmet ones are worth chasing —
        // which is the one thing the three states exist to withhold.
        var badges: [NSView] = []
        if seen {
            let stars = RarityStars(size: 7)
            stars.show(DigiDex.shared.rarity(of: entry), routes: DigiDex.shared.routesInto(entry.id))
            badges.append(stars)
            if entry.x {
                badges.append(UI.label("X", size: 7, weight: .heavy, color: Theme.danger))
            }
        }
        let badgeRow = UI.stack(.horizontal, spacing: 3, badges)
        badgeRow.alignment = .centerY

        let stack = UI.stack(.vertical, spacing: 2, [sprite, name, badgeRow])
        stack.alignment = .centerX
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
            name.widthAnchor.constraint(equalToConstant: 62),
        ])

        if seen {
            let rarity = DigiDex.shared.rarity(of: entry)
            toolTip = "\(entry.name) · \(entry.stageLabel?.dubName ?? entry.stage) · "
                + "\(entry.attribute.rawValue)"
                + (entry.primaryField.map { " · \($0)" } ?? "")
                + "\nClick for the full entry"
            setAccessibilityLabel(
                "\(entry.name), met. \(entry.stageLabel?.dubName ?? entry.stage), "
                    + "\(entry.attribute.rawValue), \(rarity.label)"
                    + (entry.x ? ", X-Antibody" : "")
            )
            setAccessibilityHelp("Opens the full entry")
        } else if reachable {
            toolTip = "\(entry.name) — one digivolution away from a form you have met"
            setAccessibilityLabel(
                "\(entry.name), not met — one digivolution away from a form you have"
            )
        } else {
            toolTip = "Not met yet"
            setAccessibilityLabel("\(entry.name), not met yet")
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        guard seen else { return }
        onTap(entry)
    }

    /// A pointing cursor is the only affordance a 62-point cell has room for.
    override func resetCursorRects() {
        guard seen else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// Scroll views measure from the top when their document view is flipped, which
/// is what makes a grid start at the top rather than the bottom.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
