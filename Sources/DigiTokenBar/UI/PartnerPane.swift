import AppKit

/// The main screen: who your partner is, how close the next rung is, and what
/// your working habits are doing to it.
@MainActor
final class PartnerPane: NSView {
    private let store: PartnerStore

    private let sprite = SpriteView(size: 104)
    private let nameLabel = UI.label("", size: 16, weight: .bold, rounded: true)
    private let xBadge = UI.label("X", size: 10, weight: .black, color: .white)
    private let stageLabel = UI.label("", size: 10, weight: .medium, color: .secondaryLabelColor)
    private let fieldLabel = UI.label("", size: 8, weight: .semibold, color: .tertiaryLabelColor)
    private let progressCaption = UI.label("", size: 10, weight: .semibold)
    private let progressValue = UI.label("", size: 10, color: .secondaryLabelColor, mono: true)
    private let bar = BarView()
    private let alignmentNote = UI.label("", size: 9, color: .tertiaryLabelColor)
    private let lineageStack = UI.stack(.horizontal, spacing: 4, [])
    private let graduateButton: NSButton
    private var careTiles: [StatTile] = []

    init(store: PartnerStore) {
        self.store = store
        graduateButton = NSButton(title: "Graduate & start a new egg", target: nil, action: nil)
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        graduateButton.target = self
        graduateButton.action = #selector(graduate)
        graduateButton.bezelStyle = .rounded
        graduateButton.controlSize = .regular
        graduateButton.font = .systemFont(ofSize: 11, weight: .semibold)
        graduateButton.isHidden = true

        xBadge.wantsLayer = true
        xBadge.layer?.backgroundColor = Theme.danger.withAlphaComponent(0.9).cgColor
        xBadge.layer?.cornerRadius = 4
        xBadge.isHidden = true

        // Screen
        let nameRow = UI.stack(.horizontal, spacing: 5, [nameLabel, xBadge])
        let screenStack = UI.stack(.vertical, spacing: 5, [sprite, nameRow, stageLabel, fieldLabel])
        screenStack.alignment = .centerX

        let screen = NSView()
        screen.wantsLayer = true
        screen.layer?.cornerRadius = 12
        screen.layer?.backgroundColor = Theme.screen.cgColor
        screen.layer?.borderWidth = 1
        screen.layer?.borderColor = Theme.accent.withAlphaComponent(0.35).cgColor
        screen.addSubview(screenStack)
        NSLayoutConstraint.activate([
            screenStack.topAnchor.constraint(equalTo: screen.topAnchor, constant: 12),
            screenStack.bottomAnchor.constraint(equalTo: screen.bottomAnchor, constant: -12),
            screenStack.centerXAnchor.constraint(equalTo: screen.centerXAnchor),
            screenStack.leadingAnchor.constraint(greaterThanOrEqualTo: screen.leadingAnchor, constant: 8),
        ])
        // The screen's labels sit on a dark panel in both appearances, so they
        // are tinted explicitly rather than following the system label colour.
        nameLabel.textColor = .white
        stageLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        fieldLabel.textColor = Theme.accent.withAlphaComponent(0.8)

        // Growth
        let progressRow = UI.stack(.horizontal, spacing: 6, [progressCaption, UI.spacer(), progressValue])
        let growth = UI.stack(.vertical, spacing: 4, [progressRow, bar])

        // Care
        careTiles = [
            StatTile(label: "Weight"), StatTile(label: "Discipline"),
            StatTile(label: "Streak"), StatTile(label: "Care mistakes"),
        ]
        let careRow1 = UI.stack(.horizontal, spacing: 8, [careTiles[0], careTiles[1]])
        let careRow2 = UI.stack(.horizontal, spacing: 8, [careTiles[2], careTiles[3]])
        careRow1.distribution = .fillEqually
        careRow2.distribution = .fillEqually
        UI.wraps(alignmentNote, lines: 3)
        let care = UI.stack(.vertical, spacing: 6, [
            UI.caption("Care"), careRow1, careRow2, alignmentNote,
        ])

        let lineageScroll = NSScrollView()
        lineageScroll.hasHorizontalScroller = false
        lineageScroll.drawsBackground = false
        lineageScroll.documentView = lineageStack
        lineageScroll.translatesAutoresizingMaskIntoConstraints = false
        lineageScroll.heightAnchor.constraint(equalToConstant: 52).isActive = true
        let lineage = UI.stack(.vertical, spacing: 5, [UI.caption("Lineage"), lineageScroll])

        let root = UI.stack(.vertical, spacing: 13, [screen, growth, care, lineage, graduateButton])
        root.setHuggingPriority(.defaultHigh, for: .vertical)
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            // Pinned to the bottom so the pane reports its real height; without
            // it the enclosing scroll view finds nothing to scroll and anything
            // past the visible 392 points cannot be reached.
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            screen.widthAnchor.constraint(equalTo: root.widthAnchor),
            growth.widthAnchor.constraint(equalTo: root.widthAnchor),
            care.widthAnchor.constraint(equalTo: root.widthAnchor),
            lineage.widthAnchor.constraint(equalTo: root.widthAnchor),
            lineageScroll.widthAnchor.constraint(equalTo: root.widthAnchor),
            graduateButton.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])
    }

    func refresh() {
        let partner = store.partner
        let profile = store.profile

        sprite.show(partner.entry)
        sprite.idleMotion = Settings.shared.animateSprite && !partner.isEgg
        nameLabel.stringValue = partner.displayName
        xBadge.isHidden = !partner.isXAntibody

        if let entry = partner.entry {
            stageLabel.stringValue =
                "\(partner.stage.dubName) · \(entry.attribute.symbol) \(entry.attribute.rawValue)"
            fieldLabel.stringValue = (entry.primaryField ?? "").uppercased()
        } else {
            stageLabel.stringValue = "DigiTama — not yet hatched"
            fieldLabel.stringValue = ""
        }

        let pace = Settings.shared.growthPace
        if partner.isEgg {
            progressCaption.stringValue = "Hatching"
            bar.value = min(1, Double(partner.tokens) / Double(GrowthCurve.eggHatch))
            let left = max(0, GrowthCurve.eggHatch - partner.tokens)
            progressValue.stringValue = "\(TokenFormatter.short(left)) to hatch"
        } else {
            progressCaption.stringValue = "Next digivolution"
            bar.value = GrowthCurve.progress(tokens: partner.tokens, stage: partner.stage, pace: pace)
            if let remaining = GrowthCurve.tokensToNext(tokens: partner.tokens, stage: partner.stage, pace: pace) {
                progressValue.stringValue =
                    "\(TokenFormatter.short(remaining)) to \(partner.stage.next?.dubName ?? "")"
            } else {
                progressValue.stringValue = "Max stage reached"
            }
        }

        careTiles[0].set(value: "\(profile.weight)", hint: weightHint(profile))
        careTiles[1].set(value: "\(profile.discipline)", hint: "consistency")
        // A frozen day is always declared. Softening the consequence is fine;
        // letting the number quietly overstate the work is not.
        careTiles[2].set(
            value: "\(profile.streak)d",
            hint: profile.frozenDays > 0 ? "\(profile.frozenDays) frozen" : "active days"
        )
        careTiles[3].set(
            value: "\(profile.careMistakes)",
            hint: profile.careMistakes > 4 ? "drifting Virus" : "on track",
            warning: profile.careMistakes > 4
        )

        alignmentNote.stringValue =
            "Alignment: \(profile.attribute.symbol) \(profile.attribute.rawValue) — this is what steers which branch your partner takes at the next digivolution."

        rebuildLineage(partner)
        graduateButton.isHidden = !store.canGraduate
    }

    private func weightHint(_ profile: CareProfile) -> String {
        if profile.isLean { return "cache-efficient" }
        if profile.isHeavy { return "context-heavy" }
        return "balanced"
    }

    private func rebuildLineage(_ partner: Partner) {
        lineageStack.arrangedSubviews.forEach {
            lineageStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard !partner.lineage.isEmpty else {
            lineageStack.addArrangedSubview(
                UI.label("Your DigiTama has not hatched yet.", size: 10, color: .secondaryLabelColor)
            )
            return
        }
        for (index, id) in partner.lineage.enumerated() {
            if index > 0 {
                let arrow = NSImageView()
                arrow.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
                arrow.contentTintColor = .tertiaryLabelColor
                lineageStack.addArrangedSubview(arrow)
            }
            let entry = DigiDex.shared.entry(id)
            let thumb = SpriteView(size: 32)
            thumb.show(entry)
            let caption = UI.label(entry?.name ?? "?", size: 7, color: .secondaryLabelColor, align: .center)
            caption.widthAnchor.constraint(equalToConstant: 46).isActive = true
            let cell = UI.stack(.vertical, spacing: 1, [thumb, caption])
            cell.alignment = .centerX
            lineageStack.addArrangedSubview(cell)
        }
    }

    @objc private func graduate() {
        store.graduate()
        refresh()
    }
}

/// One labelled number in the care / usage grids.
final class StatTile: NSView {
    private let titleLabel: NSTextField
    private let valueLabel = UI.label("—", size: 15, weight: .bold, rounded: true, mono: true)
    private let hintLabel = UI.label("", size: 8, color: .tertiaryLabelColor)

    init(label: String) {
        titleLabel = UI.label(label, size: 9, color: .secondaryLabelColor)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor

        let stack = UI.stack(.vertical, spacing: 1, [titleLabel, valueLabel, hintLabel])
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(value: String, hint: String, warning: Bool = false) {
        valueLabel.stringValue = value
        valueLabel.textColor = warning ? .systemOrange : .labelColor
        hintLabel.stringValue = hint
    }
}
