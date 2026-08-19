import AppKit

/// The collection screen: everything the tamer has met, and everything still out
/// there. Unmet forms stay visible as silhouettes — the roster is the point.
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
        ])
    }

    func refresh() {
        let total = DigiDex.shared.all.count
        counterLabel.stringValue = "\(store.seenDigimon.count) / \(total)"
        bar.value = store.completion
        xLabel.stringValue = store.seenXAntibody.isEmpty ? "" : "X ×\(store.seenXAntibody.count)"
        raisedLabel.stringValue = "\(store.collection.count) raised"
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
            var cells: [NSView] = slice.map {
                DexCell(entry: $0, seen: store.seenDigimon.contains($0.id))
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

    @objc private func filterChanged() { rebuildGrid() }
}

/// One Digimon in the grid.
@MainActor
final class DexCell: NSView {
    init(entry: DigimonEntry, seen: Bool) {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6
        if seen {
            layer?.backgroundColor = Theme.attribute(entry.attribute)
                .withAlphaComponent(0.13).cgColor
        }

        // Unmet forms show a generic silhouette rather than their real artwork.
        // It reads better as a collection — an unknown should look unknown — and
        // it keeps the app from pulling a thousand images the tamer never earned.
        let sprite = SpriteView(size: 42)
        if seen {
            sprite.show(entry)
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

        let stack = UI.stack(.vertical, spacing: 2, [sprite, name])
        stack.alignment = .centerX
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
            name.widthAnchor.constraint(equalToConstant: 62),
        ])

        toolTip = "\(entry.name) · \(entry.stageLabel?.dubName ?? entry.stage) · "
            + "\(entry.attribute.rawValue)"
            + (entry.primaryField.map { " · \($0)" } ?? "")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// Scroll views measure from the top when their document view is flipped, which
/// is what makes a grid start at the top rather than the bottom.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
