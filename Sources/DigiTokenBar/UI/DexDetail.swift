import AppKit

/// The card shown when a tamer taps a Digimon they have met.
///
/// Everything above the fold comes out of the shipped index and costs nothing.
/// The reference-book text underneath is fetched the first time this card is
/// opened for a given form and cached from then on, which is why it fades in a
/// moment after the rest rather than blocking the whole card on a request.
@MainActor
final class DexDetailView: NSView {
    private let sprite = SpriteView(size: 132)
    private let nameLabel = UI.label("", size: 16, weight: .bold, rounded: true)
    private let stageLabel = UI.label("", size: 10, color: .secondaryLabelColor)
    private let rarityLabel = UI.label("", size: 10, weight: .heavy)
    private let rarityDetail = UI.label("", size: 9, color: .tertiaryLabelColor)
    private let traitsLabel = UI.label("", size: 10, color: .secondaryLabelColor)
    private let summaryLabel = UI.label("", size: 10, color: .secondaryLabelColor)
    private let skillsLabel = UI.label("", size: 10, color: .secondaryLabelColor)
    private let routesLabel = UI.label("", size: 9, color: .tertiaryLabelColor)
    private let xBadge = UI.label("", size: 9, weight: .heavy, color: Theme.danger)
    private let xNote = UI.label("", size: 9, color: .tertiaryLabelColor)
    private let stars = RarityStars(size: 11)
    private let scroll = NSScrollView()

    private var shown: Int?
    private var onClose: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // Opaque on purpose: it sits over the grid, and a translucent card would
        // leave a hundred sprites legible through the text.
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let close = NSButton(
            image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!,
            target: self, action: #selector(close)
        )
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = "Back to the DigiDex"

        let cardWidth = Theme.popoverWidth - 32
        for label in [summaryLabel, skillsLabel, traitsLabel, rarityDetail, routesLabel, xNote] {
            UI.wraps(label, width: cardWidth)
        }
        UI.wraps(nameLabel, lines: 2, width: cardWidth)

        let rarityRow = UI.stack(.horizontal, spacing: 6, [stars, rarityLabel, xBadge, UI.spacer()])
        let heading = UI.stack(.vertical, spacing: 2, [
            nameLabel, stageLabel, rarityRow, rarityDetail, xNote,
        ])

        let body = UI.stack(.vertical, spacing: 12, [
            heading,
            section("Traits", traitsLabel),
            section("Reference book", summaryLabel),
            section("Attacks", skillsLabel),
            routesLabel,
        ])

        let content = UI.stack(.vertical, spacing: 10, [sprite, body])
        content.alignment = .centerX
        sprite.setContentHuggingPriority(.required, for: .vertical)

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let clip = FlippedView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: clip.topAnchor),
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            body.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        scroll.documentView = clip

        close.translatesAutoresizingMaskIntoConstraints = false
        addSubview(close)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            close.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.topAnchor.constraint(equalTo: close.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            clip.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func section(_ title: String, _ label: NSTextField) -> NSView {
        let stack = UI.stack(.vertical, spacing: 3, [UI.caption(title), label])
        stack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return stack
    }

    /// `xChance` is the tamer's own odds of an X-Antibody form at the next
    /// digivolution, passed in because the card has no business reading the
    /// care profile itself.
    func show(_ entry: DigimonEntry, xChance: Double, onClose: @escaping () -> Void) {
        self.onClose = onClose
        guard shown != entry.id else { return }
        shown = entry.id

        sprite.show(entry)
        nameLabel.stringValue = entry.name
        nameLabel.textColor = Theme.attribute(entry.attribute)

        let stage = entry.stageLabel
        stageLabel.stringValue = [
            stage.map { "\($0.dubName) · \($0.rawName)" },
            "\(entry.attribute.symbol) \(entry.attribute.rawValue)",
        ].compactMap { $0 }.joined(separator: "   ·   ")

        let routes = DigiDex.shared.routesInto(entry.id)
        let rarity = DigiDex.shared.rarity(of: entry)
        rarityLabel.stringValue = rarity.label.uppercased()
        rarityLabel.textColor = Theme.rarity(rarity)
        rarityDetail.stringValue = rarity.detail(routes: routes)
        stars.show(rarity, routes: routes)
        xBadge.stringValue = entry.x ? "X-ANTIBODY" : ""

        // The X is not a rarity tier, and the stars deliberately do not treat it
        // as one: X forms sit slightly *below* the roster average for routes in.
        // What makes one hard to get is the roll at the digivolution, so that is
        // the number worth printing here.
        xNote.isHidden = !entry.x
        xNote.stringValue = entry.x
            ? "The X is a roll, not a route: about 1 in \(Int((1 / max(xChance, 0.0001)).rounded())) "
                + "at your discipline, or forced with a vial."
            : ""

        var traits: [String] = []
        if !entry.types.isEmpty { traits.append("Type: \(entry.types.joined(separator: ", "))") }
        if !entry.fields.isEmpty { traits.append("Field: \(entry.fields.joined(separator: ", "))") }
        traitsLabel.stringValue = traits.isEmpty ? "Not recorded." : traits.joined(separator: "\n")

        let onward = entry.next.compactMap { DigiDex.shared.entry($0)?.name }
        routesLabel.stringValue = onward.isEmpty
            ? "No recorded digivolution from here."
            : "Digivolves into: \(onward.joined(separator: ", "))"

        // Placeholders while the fetch is in flight, so the card never looks
        // broken and never looks like it is claiming there is nothing to say.
        summaryLabel.stringValue = "Looking it up…"
        summaryLabel.textColor = .tertiaryLabelColor
        skillsLabel.stringValue = "—"

        Task { [weak self, id = entry.id] in
            let detail = await DetailLoader.shared.detail(for: entry)
            await MainActor.run {
                guard let self, self.shown == id else { return }
                self.apply(detail)
            }
        }
    }

    private func apply(_ detail: DigimonDetail?) {
        guard let detail else {
            summaryLabel.stringValue =
                "Could not reach digi-api for this one. It will try again next time."
            summaryLabel.textColor = .tertiaryLabelColor
            skillsLabel.stringValue = "—"
            return
        }

        if let summary = detail.summary, !summary.isEmpty {
            summaryLabel.stringValue = summary
            summaryLabel.textColor = .secondaryLabelColor
        } else {
            summaryLabel.stringValue = "No entry recorded."
            summaryLabel.textColor = .tertiaryLabelColor
        }

        skillsLabel.stringValue = detail.skills.isEmpty
            ? "None recorded."
            : detail.skills.map { skill in
                skill.translation.map { "\(skill.name) — \($0)" } ?? skill.name
            }.joined(separator: "\n")

        if let year = detail.year, !year.isEmpty {
            stageLabel.stringValue += "   ·   \(year)"
        }
    }

    @objc private func close() {
        shown = nil
        onClose?()
    }
}
