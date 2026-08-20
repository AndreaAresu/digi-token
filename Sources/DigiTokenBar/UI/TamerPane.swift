import AppKit

/// The Tamer tab: your card, the partners you have graduated, the cards other
/// people gave you, and the fusions between all of them.
///
/// Everything here is copy and paste on purpose. The app has no account, no
/// server and no network beyond fetching artwork, and adding one so two friends
/// can fuse a Digimon would be a poor trade. A card is a short string; the
/// transport is whatever the two of them already use to talk.
@MainActor
final class TamerPane: NSView {
    private let store: PartnerStore

    private let nameField = NSTextField()
    private let cardView = CardView()
    private let copyButton = NSButton()
    private let pasteButton = NSButton()
    private let status = UI.label("", size: 10, color: .secondaryLabelColor)
    private let friendStack = UI.stack(.vertical, spacing: 8, [])
    private let friendsEmpty = UI.label("", size: 10, color: .tertiaryLabelColor)
    private let chargeNote = UI.label("", size: 9, color: .secondaryLabelColor, mono: true)
    private let eggNote = UI.label("", size: 10, color: .secondaryLabelColor)
    private let collectionStack = UI.stack(.vertical, spacing: 6, [])
    private let collectionEmpty = UI.label("", size: 10, color: .tertiaryLabelColor)
    private let fuseButton = NSButton()
    private let fuseHint = UI.label("", size: 9, color: .tertiaryLabelColor)

    /// The partners picked for a local Jogress, oldest pick first.
    ///
    /// Held as an ordered list rather than a set so a third pick can drop the
    /// first one instead of refusing: a two-slot selection that says "no" is a
    /// dead end the tamer has to undo by hand.
    private var selection: [UUID] = []

    init(store: PartnerStore) {
        self.store = store
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        nameField.placeholderString = "Your tamer name"
        nameField.font = .systemFont(ofSize: 12, weight: .semibold)
        nameField.bezelStyle = .roundedBezel
        nameField.target = self
        nameField.action = #selector(nameChanged)
        nameField.translatesAutoresizingMaskIntoConstraints = false

        copyButton.title = "Copy my card"
        pasteButton.title = "Paste a friend's"
        for button in [copyButton, pasteButton] {
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 11, weight: .semibold)
            button.target = self
        }
        copyButton.action = #selector(copyCard)
        pasteButton.action = #selector(pasteCard)

        for label in [status, friendsEmpty, eggNote, chargeNote, collectionEmpty, fuseHint] {
            UI.wraps(label)
        }
        status.isHidden = true

        fuseButton.title = "Jogress the two selected"
        fuseButton.bezelStyle = .rounded
        fuseButton.font = .systemFont(ofSize: 11, weight: .semibold)
        fuseButton.target = self
        fuseButton.action = #selector(fuseSelected)
        fuseButton.translatesAutoresizingMaskIntoConstraints = false

        let buttons = UI.stack(.horizontal, spacing: 8, [copyButton, pasteButton])
        buttons.distribution = .fillEqually

        let mine = UI.stack(.vertical, spacing: 8, [
            UI.caption("Your card"), nameField, cardView, buttons, status, eggNote,
        ])

        // The meter governs every fusion on this tab, local or across tamers,
        // so it sits above both rather than being repeated under each.
        let collected = UI.stack(.vertical, spacing: 8, [
            UI.caption("Your partners"), chargeNote, collectionEmpty,
            collectionStack, fuseHint, fuseButton,
        ])

        let friends = UI.stack(.vertical, spacing: 8, [
            UI.caption("Other tamers"), friendsEmpty, friendStack,
        ])

        let root = UI.stack(.vertical, spacing: 16, [mine, collected, friends])
        addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            mine.widthAnchor.constraint(equalTo: root.widthAnchor),
            collected.widthAnchor.constraint(equalTo: root.widthAnchor),
            friends.widthAnchor.constraint(equalTo: root.widthAnchor),
            nameField.widthAnchor.constraint(equalTo: mine.widthAnchor),
            cardView.widthAnchor.constraint(equalTo: mine.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: mine.widthAnchor),
            status.widthAnchor.constraint(equalTo: mine.widthAnchor),
            eggNote.widthAnchor.constraint(equalTo: mine.widthAnchor),
            chargeNote.widthAnchor.constraint(equalTo: collected.widthAnchor),
            collectionEmpty.widthAnchor.constraint(equalTo: collected.widthAnchor),
            collectionStack.widthAnchor.constraint(equalTo: collected.widthAnchor),
            fuseHint.widthAnchor.constraint(equalTo: collected.widthAnchor),
            fuseButton.widthAnchor.constraint(equalTo: collected.widthAnchor),
            friendsEmpty.widthAnchor.constraint(equalTo: friends.widthAnchor),
            friendStack.widthAnchor.constraint(equalTo: friends.widthAnchor),
        ])
    }

    func refresh() {
        if nameField.stringValue != Settings.shared.tamerName, nameField.currentEditor() == nil {
            nameField.stringValue = Settings.shared.tamerName
        }

        let card = store.myCard(name: Settings.shared.tamerName)
        cardView.isHidden = card == nil
        copyButton.isEnabled = card != nil
        eggNote.isHidden = card != nil
        if let card {
            cardView.show(card)
        } else {
            eggNote.stringValue =
                "Your DigiTama has not hatched yet. A card describes a partner, so there is "
                + "nothing to hand over until there is one."
        }

        // Shown next to the fusion buttons rather than only in the shop: a
        // tamer picking which partner to spend needs to know the meter is empty
        // before they pick, not after.
        let dna = store.wallet.dna
        chargeNote.stringValue = store.dnaChargeSummary
        chargeNote.textColor = dna.stock > 0 ? Theme.accent : .tertiaryLabelColor

        rebuildCollection()
        rebuildFriends()
    }

    /// The graduated partners, and the fusion between two of them.
    ///
    /// This is the only screen in the app where a retired partner can be looked
    /// at. Before it existed they were a counter on the DigiDex header and a row
    /// of titles inside a modal dropdown — weeks of raising, filed out of sight.
    private func rebuildCollection() {
        collectionStack.arrangedSubviews.forEach {
            collectionStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let partners = store.collection.filter { $0.entry != nil }
        // A partner that left the collection — spent in a fusion — must not stay
        // selected and re-enable the button on the next refresh.
        let held = Set(partners.map(\.id))
        selection.removeAll { !held.contains($0) }

        collectionEmpty.isHidden = !partners.isEmpty
        collectionEmpty.stringValue =
            "Nothing graduated yet. Take a partner to Mega and graduate it — it moves here, "
            + "and two of them can be fused into a form neither line reached alone."

        for partner in partners.sorted(by: { ($0.retiredAt ?? .distantPast) > ($1.retiredAt ?? .distantPast) }) {
            let row = CollectedRow(
                partner: partner,
                order: selection.firstIndex(of: partner.id).map { $0 + 1 }
            ) { [weak self] in
                self?.toggle(partner)
            }
            collectionStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: collectionStack.widthAnchor).isActive = true
        }

        let ready = selection.count == 2
        fuseButton.isHidden = partners.count < 2
        fuseButton.isEnabled = ready && store.wallet.dna.stock > 0
        fuseHint.isHidden = partners.count < 2
        fuseHint.stringValue = hint(selected: selection.count)
    }

    /// Said plainly, because a disabled button with no explanation is the worst
    /// version of every one of these states.
    private func hint(selected: Int) -> String {
        guard store.wallet.dna.stock > 0 else {
            return "A Jogress costs a DNA Charge, and the meter is empty."
        }
        switch selected {
        case 0: return "Pick two. Both are spent, and what they become is not known until it happens."
        case 1: return "Pick one more."
        default: return "Both leave your collection and the fused form takes their place."
        }
    }

    private func toggle(_ partner: Partner) {
        if let index = selection.firstIndex(of: partner.id) {
            selection.remove(at: index)
        } else {
            selection.append(partner.id)
            if selection.count > 2 { selection.removeFirst() }
        }
        rebuildCollection()
    }

    private func rebuildFriends() {
        friendStack.arrangedSubviews.forEach {
            friendStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        friendsEmpty.isHidden = !store.friends.isEmpty
        friendsEmpty.stringValue =
            "Nobody yet. Ask a friend for their card and paste it here — you can then Jogress "
            + "one of your graduated partners with theirs."

        for card in store.friends {
            let row = FriendRow(card: card) { [weak self] action in
                switch action {
                case .jogress: self?.beginJogress(with: card)
                case .forget: self?.store.forgetFriend(card); self?.refresh()
                }
            }
            friendStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: friendStack.widthAnchor).isActive = true
        }
    }

    // MARK: - Actions

    @objc private func nameChanged() {
        Settings.shared.tamerName = nameField.stringValue
        nameField.stringValue = Settings.shared.tamerName
        refresh()
    }

    @objc private func copyCard() {
        guard let card = store.myCard(name: Settings.shared.tamerName) else { return }
        let code = TamerCardCodec.encode(card)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        say(
            "Copied. It is \(code.count) characters and contains only your partner — "
                + "no logs, no project names.",
            tone: Theme.attribute(.data)
        )
    }

    @objc private func pasteCard() {
        let pasted = NSPasteboard.general.string(forType: .string) ?? ""
        switch store.importCard(pasted) {
        case .imported(let name):
            say("Added \(name)'s card.", tone: Theme.attribute(.data))
        case .ownCard:
            say("That is your own card — a Jogress needs two different tamers.")
        case .stillAnEgg:
            say("That card's partner has not hatched yet.")
        case .rejected(let error):
            say(message(for: error), tone: Theme.danger)
        }
        refresh()
    }

    private func message(for error: TamerCardCodec.DecodeError) -> String {
        switch error {
        case .notACard:
            "No card on the clipboard. A card starts with \(TamerCardCodec.prefix)."
        case .damaged:
            "That card is damaged — it was probably truncated on the way here. Ask for it again."
        case .unreadable:
            "That card could not be read."
        case .tooNew(let version):
            "That card was written by a newer version of DigiTokenBar (v\(version))."
        }
    }

    /// Fuses the two selected partners. Both are the tamer's own, so unlike the
    /// cross-tamer path there is no card to pick from — the selection in the
    /// list is the choice, and this only confirms it.
    @objc private func fuseSelected() {
        let partners = store.collection.filter { selection.contains($0.id) }
        guard partners.count == 2 else { return }
        let (first, second) = (partners[0], partners[1])

        let confirm = NSAlert()
        confirm.messageText = "Fuse \(first.displayName) with \(second.displayName)?"
        confirm.informativeText =
            "Both leave your collection and the fused form takes their place. It costs one "
            + "DNA Charge, and what they become is settled by their two seeds — not by asking "
            + "again. This cannot be undone."
        confirm.addButton(withTitle: "Fuse")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        switch store.jogress(first, second) {
        case .fused(let name):
            selection.removeAll()
            let done = NSAlert()
            done.messageText = "Jogress"
            done.informativeText =
                "\(first.displayName) and \(second.displayName) became \(name). "
                + "It is in your collection and recorded in the DigiDex."
            done.runModal()
        case .noCharge:
            say(
                "No DNA Charge — nothing was spent. They come back as you work "
                    + "(\(TokenFormatter.short(store.wallet.dna.tokensToNext)) to the next), "
                    + "or buy one in the shop.",
                tone: Theme.danger
            )
        case .noRoute:
            say("Those two have no fusion between them.", tone: Theme.danger)
        case .samePartner:
            say("A Jogress needs two different partners.", tone: Theme.danger)
        case .notInCollection:
            say("One of those is no longer in your collection.", tone: Theme.danger)
        }
        refresh()
    }

    /// The one place the status line is written.
    ///
    /// It also owns the line's visibility: an empty label still claims its
    /// leading, which held a paragraph of space open between the card and the
    /// collection below it.
    private func say(_ message: String, tone: NSColor = .secondaryLabelColor) {
        status.stringValue = message
        status.textColor = tone
        status.isHidden = message.isEmpty
    }

    /// Fusing spends one of the tamer's own partners, so it asks which one and
    /// then asks again before doing it.
    private func beginJogress(with card: TamerCard) {
        let candidates = store.collection.filter { $0.entry != nil }
        guard !candidates.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No graduated partner to fuse"
            alert.informativeText = """
                Jogress spends one of your retired partners. Raise a partner to Mega, \
                graduate it into your collection, and it becomes available here.

                \(card.tamer)'s partner is not consumed — their card is a photograph, \
                and nothing here reaches their machine.
                """
            alert.runModal()
            return
        }

        let picker = NSAlert()
        picker.messageText = "Jogress with \(card.tamer)"
        picker.informativeText =
            "Choose which of your retired partners fuses with \(card.displayName). "
            + "It is spent in the process."

        let menu = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 25))
        for partner in candidates {
            menu.addItem(withTitle: "\(partner.displayName) · \(partner.stage.dubName)")
        }
        picker.accessoryView = menu
        picker.addButton(withTitle: "Fuse")
        picker.addButton(withTitle: "Cancel")
        guard picker.runModal() == .alertFirstButtonReturn else { return }

        let chosen = candidates[max(0, min(menu.indexOfSelectedItem, candidates.count - 1))]
        let confirm = NSAlert()
        confirm.messageText = "Fuse \(chosen.displayName) with \(card.displayName)?"
        confirm.informativeText =
            "\(chosen.displayName) leaves your collection and the fused form takes its place. "
            + "This cannot be undone."
        confirm.addButton(withTitle: "Fuse")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        switch store.jogress(chosen, with: card) {
        case .fused(let name):
            let done = NSAlert()
            done.messageText = "Jogress"
            done.informativeText =
                "\(chosen.displayName) and \(card.displayName) became \(name). "
                + "It is in your collection and recorded in the DigiDex."
            done.runModal()
        case .notInCollection:
            say("That partner is no longer in your collection.", tone: Theme.danger)
        case .samePartner:
            // Unreachable from here — the picker only offers your own partners
            // and the card is someone else's — but the compiler is right to ask.
            say("A Jogress needs two different partners.", tone: Theme.danger)
        case .noRoute:
            say("Those two have no fusion between them.", tone: Theme.danger)
        case .noCharge:
            // Nothing was consumed: the charge is checked before the partner is
            // removed, so the collection is exactly as it was.
            say(
                "No DNA Charge. \(chosen.displayName) is untouched — charges come back as you "
                    + "work (\(TokenFormatter.short(store.wallet.dna.tokensToNext)) to the next), "
                    + "or buy one in the shop.",
                tone: Theme.danger
            )
        }
        refresh()
    }
}

/// One graduated partner, and the tap target that selects it for a Jogress.
///
/// Deliberately does not show what a fusion would produce. The outcome is
/// seeded from both partners and settled at the moment it happens; previewing it
/// would turn a choice into a lookup, and make the DNA Charge a fee for
/// information the tamer already had.
@MainActor
final class CollectedRow: NSView {
    private let onTap: () -> Void

    init(partner: Partner, order: Int?, onTap: @escaping () -> Void) {
        self.onTap = onTap
        super.init(frame: .zero)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityChildren([])
        setAccessibilityLabel(
            "\(partner.displayName), \(partner.stage.dubName)"
                + (partner.isXAntibody ? ", X-Antibody" : "")
                + ", raised on \(TokenFormatter.short(partner.tokens)) tokens"
        )
        setAccessibilityValue(order.map { "picked \($0) of 2" } ?? "not picked")
        setAccessibilityHelp("Picks this partner for a Jogress; two are needed")

        wantsLayer = true
        layer?.cornerRadius = 8
        let selected = order != nil
        layer?.backgroundColor = selected
            ? Theme.accent.withAlphaComponent(0.16).cgColor
            : NSColor.labelColor.withAlphaComponent(0.05).cgColor
        layer?.borderWidth = selected ? 1 : 0
        layer?.borderColor = Theme.accent.withAlphaComponent(0.7).cgColor

        let sprite = SpriteView(size: 34)
        sprite.show(partner.entry)

        let name = UI.label(partner.displayName, size: 11, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        // The X rides beside the name rather than recolouring it, the same way
        // it does on the partner screen and in the grid.
        let xBadge = UI.label("X", size: 9, weight: .heavy, color: Theme.danger)
        xBadge.isHidden = !partner.isXAntibody
        let nameRow = UI.stack(.horizontal, spacing: 4, [name, xBadge])

        let stage = UI.label(
            [
                partner.stage.dubName,
                partner.entry.map { "\($0.attribute.symbol) \($0.attribute.rawValue)" },
            ].compactMap { $0 }.joined(separator: " · "),
            size: 9, color: .secondaryLabelColor
        )

        // What it cost to raise, which is the only figure that makes one
        // retired partner different from another at a glance.
        let stats = UI.label(
            "\(TokenFormatter.short(partner.tokens)) · \(partner.lineage.count) forms",
            size: 9, color: .tertiaryLabelColor, mono: true
        )
        stats.setContentHuggingPriority(.required, for: .horizontal)

        // The pick order is shown rather than a plain highlight: with two slots
        // it is the only way to see which one a third tap would replace.
        let badge = UI.label(order.map { "\($0)" } ?? "", size: 10, weight: .heavy, color: Theme.accent)
        badge.isHidden = order == nil

        let text = UI.stack(.vertical, spacing: 1, [nameRow, stage])
        let row = UI.stack(.horizontal, spacing: 8, [sprite, text, UI.spacer(), stats, badge])
        row.alignment = .centerY
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])

        let lineage = partner.lineage.compactMap { DigiDex.shared.entry($0)?.name }
        toolTip = ([
            lineage.isEmpty ? nil : lineage.joined(separator: " → "),
            partner.retiredAt.map { "Graduated \(Self.dateFormatter.string(from: $0))" },
            "\(TokenFormatter.grouped(partner.tokens)) billable tokens raised it",
        ] as [String?]).compactMap { $0 }.joined(separator: "\n")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onTap() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// The tamer's own card, drawn the way it would look if it were a physical one.
@MainActor
final class CardView: NSView {
    private let sprite = SpriteView(size: 56)
    private let tamerLabel = UI.label("", size: 12, weight: .bold, rounded: true)
    private let partnerLabel = UI.label("", size: 11, weight: .semibold)
    private let stageLabel = UI.label("", size: 9, color: .secondaryLabelColor)
    private let statsLabel = UI.label("", size: 9, color: .tertiaryLabelColor, mono: true)
    private let dexBar = BarView()

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityChildren([])
        setAccessibilityLabel("Your tamer card")
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.backgroundColor = Theme.screen.withAlphaComponent(0.35).cgColor

        let text = UI.stack(.vertical, spacing: 2, [
            tamerLabel, partnerLabel, stageLabel, statsLabel, dexBar,
        ])
        let row = UI.stack(.horizontal, spacing: 10, [sprite, text])
        row.alignment = .centerY
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            dexBar.widthAnchor.constraint(equalTo: text.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ card: TamerCard) {
        sprite.show(card.entry)
        tamerLabel.stringValue = card.tamer
        partnerLabel.stringValue = card.isXAntibody
            ? "\(card.displayName) X"
            : card.displayName
        partnerLabel.textColor = Theme.attribute(card.attribute)
        stageLabel.stringValue =
            "\(card.stage.dubName) · \(card.attribute.symbol) \(card.attribute.rawValue)"
        statsLabel.stringValue =
            "\(TokenFormatter.short(card.tokens)) raised   ·   "
            + "\(card.streak)d streak   ·   "
            + "dex \(card.dexSeen)/\(card.dexTotal)"
        dexBar.value = card.completion
        dexBar.tint = Theme.attribute(card.attribute)
        dexBar.setAccessibilityLabel("DigiDex completion")
        layer?.borderColor = Theme.attribute(card.attribute).withAlphaComponent(0.45).cgColor

        setAccessibilityValue(
            "\(card.tamer), \(card.displayName), \(card.stage.dubName), "
                + "\(card.attribute.rawValue). \(TokenFormatter.short(card.tokens)) raised, "
                + "\(card.streak) day streak, dex \(card.dexSeen) of \(card.dexTotal)"
        )
    }
}

/// One other tamer, with the two things you can do about them.
@MainActor
final class FriendRow: NSView {
    enum Action { case jogress, forget }

    private let onAction: (Action) -> Void

    init(card: TamerCard, onAction: @escaping (Action) -> Void) {
        self.onAction = onAction
        super.init(frame: .zero)

        let sprite = SpriteView(size: 34)
        sprite.show(card.entry)

        let tamer = UI.label(card.tamer, size: 11, weight: .semibold)
        let partner = UI.label(
            "\(card.displayName) · \(card.stage.dubName)",
            size: 9, color: .secondaryLabelColor
        )
        partner.lineBreakMode = .byTruncatingTail

        let fuse = NSButton(title: "Jogress", target: self, action: #selector(jogress))
        fuse.bezelStyle = .rounded
        fuse.font = .systemFont(ofSize: 10, weight: .semibold)
        fuse.setContentHuggingPriority(.required, for: .horizontal)
        // With three friends listed there are three buttons all reading
        // "Jogress"; the name is what tells them apart.
        fuse.setAccessibilityLabel("Jogress with \(card.tamer)")

        let forget = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove")!,
            target: self, action: #selector(forget)
        )
        forget.isBordered = false
        forget.contentTintColor = .tertiaryLabelColor
        forget.toolTip = "Remove \(card.tamer)'s card"
        forget.setAccessibilityLabel("Remove \(card.tamer)'s card")

        let text = UI.stack(.vertical, spacing: 1, [tamer, partner])
        let row = UI.stack(.horizontal, spacing: 8, [sprite, text, UI.spacer(), fuse, forget])
        let card2 = UI.card(row)
        card2.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card2)

        NSLayoutConstraint.activate([
            card2.leadingAnchor.constraint(equalTo: leadingAnchor),
            card2.trailingAnchor.constraint(equalTo: trailingAnchor),
            card2.topAnchor.constraint(equalTo: topAnchor),
            card2.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        toolTip = """
            \(card.tamer) · \(card.displayName)
            \(card.stage.dubName) · \(card.attribute.rawValue)
            \(TokenFormatter.grouped(card.tokens)) tokens raised, \(card.streak)-day streak
            DigiDex \(card.dexSeen)/\(card.dexTotal)
            """
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func jogress() { onAction(.jogress) }
    @objc private func forget() { onAction(.forget) }
}
