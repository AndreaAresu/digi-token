import AppKit

/// The shop. Currency is tokens you already burned working; nothing here costs
/// real money, and nothing here rewrites what already happened.
@MainActor
final class ShopPane: NSView {
    private let store: PartnerStore

    private let balanceLabel = UI.label("", size: 18, weight: .bold, rounded: true, mono: true)
    private let earnedLabel = UI.label("", size: 9, color: .tertiaryLabelColor)
    private let effectsLabel = UI.label("", size: 9, color: .secondaryLabelColor)
    private let itemStack = UI.stack(.vertical, spacing: 8, [])
    private let ruleLabel = UI.label("", size: 9, color: .tertiaryLabelColor)

    init(store: PartnerStore) {
        self.store = store
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let wallet = UI.stack(.horizontal, spacing: 6, [
            balanceLabel, UI.spacer(), earnedLabel,
        ])
        let walletCard = UI.card(UI.stack(.vertical, spacing: 2, [
            UI.caption("Balance"), wallet,
        ]))
        walletCard.translatesAutoresizingMaskIntoConstraints = false

        effectsLabel.maximumNumberOfLines = 4
        effectsLabel.lineBreakMode = .byWordWrapping

        ruleLabel.maximumNumberOfLines = 4
        ruleLabel.lineBreakMode = .byWordWrapping
        ruleLabel.stringValue =
            "Everything here is bought before the outcome is known. Nothing clears a care mistake or skips a stage — your record stays true."

        let root = UI.stack(.vertical, spacing: 10, [
            walletCard, effectsLabel, itemStack, ruleLabel,
        ])
        addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            // Pinned to the bottom so the pane reports its real height; without
            // it the enclosing scroll view finds nothing to scroll and anything
            // past the visible 392 points cannot be reached.
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            walletCard.widthAnchor.constraint(equalTo: root.widthAnchor),
            wallet.widthAnchor.constraint(equalTo: walletCard.widthAnchor, constant: -16),
            effectsLabel.widthAnchor.constraint(equalTo: root.widthAnchor),
            itemStack.widthAnchor.constraint(equalTo: root.widthAnchor),
            ruleLabel.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])
    }

    func refresh() {
        let wallet = store.wallet
        balanceLabel.stringValue = TokenFormatter.short(wallet.balance)
        earnedLabel.stringValue =
            "\(TokenFormatter.short(wallet.earned)) earned · \(TokenFormatter.short(wallet.spent)) spent"

        let effects = store.activeEffects
        effectsLabel.stringValue = effects.isEmpty ? "" : "Active: " + effects.joined(separator: " · ")
        effectsLabel.isHidden = effects.isEmpty

        itemStack.arrangedSubviews.forEach {
            itemStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for item in ShopItem.catalogue {
            let row = ShopRow(item: item, wallet: wallet) { [weak self] field in
                self?.buy(item, field: field)
            }
            itemStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: itemStack.widthAnchor).isActive = true
        }
    }

    private func buy(_ item: ShopItem, field: String?) {
        switch store.purchase(item.id, field: field) {
        case .bought:
            refresh()
        case .tooExpensive:
            report("Not enough tokens", "\(item.name) costs \(TokenFormatter.grouped(item.price)). Keep working.")
        case .notApplicable(let why):
            report("Cannot use that right now", why)
        }
    }

    private func report(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.runModal()
    }
}

/// One purchasable item.
@MainActor
final class ShopRow: NSView {
    private let item: ShopItem
    private let onBuy: (String?) -> Void

    init(item: ShopItem, wallet: Wallet, onBuy: @escaping (String?) -> Void) {
        self.item = item
        self.onBuy = onBuy
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
        icon.contentTintColor = Theme.accent
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true

        var title = item.name
        if item.stockable {
            let held = wallet.stock(of: item.id)
            if held > 0 { title += "  ×\(held)" }
        }
        let name = UI.label(title, size: 11, weight: .semibold)
        let price = UI.label(
            TokenFormatter.short(item.price), size: 10,
            color: wallet.canAfford(item) ? .secondaryLabelColor : .tertiaryLabelColor,
            mono: true
        )
        price.setContentHuggingPriority(.required, for: .horizontal)

        let blurb = UI.label(item.blurb, size: 9, color: .secondaryLabelColor)
        blurb.maximumNumberOfLines = 3
        blurb.lineBreakMode = .byWordWrapping

        let button: NSButton
        if item.needsField {
            // A field has to be chosen at purchase time, so the control is the
            // menu rather than a plain button.
            let popup = NSPopUpButton()
            popup.addItem(withTitle: "Buy…")
            popup.menu?.addItem(.separator())
            for field in DigitalField.all {
                let entry = NSMenuItem(title: field, action: #selector(pickField(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = field
                popup.menu?.addItem(entry)
            }
            popup.isEnabled = wallet.canAfford(item)
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: 10)
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.widthAnchor.constraint(equalToConstant: 74).isActive = true
            button = NSButton()
            button.isHidden = true
            addSubview(popup)
            control = popup
        } else {
            let plain = NSButton(title: "Buy", target: self, action: #selector(buyPlain))
            plain.bezelStyle = .rounded
            plain.controlSize = .small
            plain.font = .systemFont(ofSize: 10, weight: .medium)
            plain.isEnabled = wallet.canAfford(item)
            plain.translatesAutoresizingMaskIntoConstraints = false
            plain.widthAnchor.constraint(equalToConstant: 74).isActive = true
            button = plain
            control = plain
        }

        let header = UI.stack(.horizontal, spacing: 6, [icon, name, UI.spacer(), price])
        let text = UI.stack(.vertical, spacing: 3, [header, blurb])
        let row = UI.stack(.horizontal, spacing: 8, [text, control!])
        row.alignment = .centerY
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            header.widthAnchor.constraint(equalTo: text.widthAnchor),
            blurb.widthAnchor.constraint(equalTo: text.widthAnchor),
        ])
        _ = button
    }

    private var control: NSView?

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func buyPlain() { onBuy(nil) }

    @objc private func pickField(_ sender: NSMenuItem) {
        onBuy(sender.representedObject as? String)
    }
}
