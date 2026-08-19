import AppKit

/// The Tamer tab: your card, the cards other people gave you, and the fusion
/// between them.
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

        for label in [status, friendsEmpty, eggNote, chargeNote] { UI.wraps(label) }

        let buttons = UI.stack(.horizontal, spacing: 8, [copyButton, pasteButton])
        buttons.distribution = .fillEqually

        let mine = UI.stack(.vertical, spacing: 8, [
            UI.caption("Your card"), nameField, cardView, buttons, status, eggNote,
        ])

        let friends = UI.stack(.vertical, spacing: 8, [
            UI.caption("Other tamers"), chargeNote, friendsEmpty, friendStack,
        ])

        let root = UI.stack(.vertical, spacing: 16, [mine, friends])
        addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            mine.widthAnchor.constraint(equalTo: root.widthAnchor),
            friends.widthAnchor.constraint(equalTo: root.widthAnchor),
            nameField.widthAnchor.constraint(equalTo: mine.widthAnchor),
            cardView.widthAnchor.constraint(equalTo: mine.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: mine.widthAnchor),
            status.widthAnchor.constraint(equalTo: mine.widthAnchor),
            eggNote.widthAnchor.constraint(equalTo: mine.widthAnchor),
            chargeNote.widthAnchor.constraint(equalTo: friends.widthAnchor),
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

        rebuildFriends()
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
        status.stringValue =
            "Copied. It is \(code.count) characters and contains only your partner — "
            + "no logs, no project names."
        status.textColor = Theme.attribute(.data)
    }

    @objc private func pasteCard() {
        let pasted = NSPasteboard.general.string(forType: .string) ?? ""
        switch store.importCard(pasted) {
        case .imported(let name):
            status.stringValue = "Added \(name)'s card."
            status.textColor = Theme.attribute(.data)
        case .ownCard:
            status.stringValue = "That is your own card — a Jogress needs two different tamers."
            status.textColor = .secondaryLabelColor
        case .stillAnEgg:
            status.stringValue = "That card's partner has not hatched yet."
            status.textColor = .secondaryLabelColor
        case .rejected(let error):
            status.stringValue = message(for: error)
            status.textColor = Theme.danger
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
            status.stringValue = "That partner is no longer in your collection."
            status.textColor = Theme.danger
        case .noRoute:
            status.stringValue = "Those two have no fusion between them."
            status.textColor = Theme.danger
        case .noCharge:
            // Nothing was consumed: the charge is checked before the partner is
            // removed, so the collection is exactly as it was.
            status.stringValue =
                "No DNA Charge. \(chosen.displayName) is untouched — charges come back as you "
                + "work (\(TokenFormatter.short(store.wallet.dna.tokensToNext)) to the next), "
                + "or buy one in the shop."
            status.textColor = Theme.danger
        }
        refresh()
    }
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
        layer?.borderColor = Theme.attribute(card.attribute).withAlphaComponent(0.45).cgColor
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

        let forget = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove")!,
            target: self, action: #selector(forget)
        )
        forget.isBordered = false
        forget.contentTintColor = .tertiaryLabelColor
        forget.toolTip = "Remove \(card.tamer)'s card"

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
