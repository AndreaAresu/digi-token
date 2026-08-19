import AppKit

/// The popover: a tab strip, one of five panes, and a footer.
@MainActor
final class PopoverController: NSViewController {
    private let store: PartnerStore
    private let monitor: UsageMonitor

    private let tabs = NSSegmentedControl()
    private let container = NSView()
    private let refreshButton = NSButton()
    private let statusLabel = UI.label("", size: 10, color: .tertiaryLabelColor)
    private let banner = DigivolutionBanner()

    private lazy var partnerPane = PartnerPane(store: store)
    private lazy var usagePane = UsagePane(monitor: monitor)
    private lazy var shopPane = ShopPane(store: store)
    private lazy var dexPane = DexPane(store: store)
    private lazy var tamerPane = TamerPane(store: store)
    private lazy var scrollers: [NSScrollView] = []

    /// Index of the DigiDex tab, which is the one pane that scrolls itself.
    private static let dexTab = 3

    /// The banner announces a digivolution above the panes rather than on top of
    /// them. It used to be an overlay pinned to the container's top edge, which
    /// meant it covered whatever was underneath — the partner's head on the
    /// Partner tab, the artwork on a DigiDex card. These two constraints let it
    /// take its space from the content area instead, so the popover keeps its
    /// size and nothing is ever hidden behind it.
    private var bannerHeight: NSLayoutConstraint!
    private var containerTop: NSLayoutConstraint!

    init(store: PartnerStore, monitor: UsageMonitor) {
        self.store = store
        self.monitor = monitor
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(
            x: 0, y: 0, width: Theme.popoverWidth, height: Theme.contentHeight + 76
        ))

        tabs.segmentCount = 5
        for (index, title) in ["Partner", "Usage", "Shop", "DigiDex", "Tamer"].enumerated() {
            tabs.setLabel(title, forSegment: index)
        }
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(switchTab)
        tabs.translatesAutoresizingMaskIntoConstraints = false

        container.translatesAutoresizingMaskIntoConstraints = false

        // Everything but the DigiDex lives in a scroller; the order here is the
        // tab order, with the DigiDex slotted in at `dexTab` afterwards.
        for pane in [partnerPane, usagePane, shopPane, tamerPane] as [NSView] {
            let scroller = NSScrollView()
            scroller.hasVerticalScroller = true
            scroller.drawsBackground = false
            scroller.translatesAutoresizingMaskIntoConstraints = false
            let flipped = FlippedView()
            flipped.translatesAutoresizingMaskIntoConstraints = false
            pane.translatesAutoresizingMaskIntoConstraints = false
            flipped.addSubview(pane)
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: flipped.topAnchor),
                pane.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
                pane.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
                pane.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
            ])
            scroller.documentView = flipped
            container.addSubview(scroller)
            NSLayoutConstraint.activate([
                scroller.topAnchor.constraint(equalTo: container.topAnchor),
                scroller.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                scroller.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                scroller.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                flipped.widthAnchor.constraint(equalTo: scroller.widthAnchor),
            ])
            scrollers.append(scroller)
        }

        dexPane.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(dexPane)
        NSLayoutConstraint.activate([
            dexPane.topAnchor.constraint(equalTo: container.topAnchor),
            dexPane.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            dexPane.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            dexPane.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        refreshButton.image = NSImage(
            systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh"
        )
        refreshButton.isBordered = false
        refreshButton.target = self
        refreshButton.action = #selector(refreshNow)
        refreshButton.toolTip = "Refresh now"

        let gear = NSButton()
        gear.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        gear.isBordered = false
        gear.target = self
        gear.action = #selector(showSettings(_:))
        gear.toolTip = "Settings"

        let quit = NSButton(title: "Quit", target: self, action: #selector(quit))
        quit.isBordered = false
        quit.font = .systemFont(ofSize: 11)
        quit.contentTintColor = .secondaryLabelColor

        let footer = UI.stack(.horizontal, spacing: 8, [
            refreshButton, statusLabel, UI.spacer(), gear, quit,
        ])

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        for view in [tabs, container, footer, divider, banner] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }

        // Zero while there is nothing to announce, so the layout below is
        // identical to having no banner at all.
        bannerHeight = banner.heightAnchor.constraint(equalToConstant: 0)
        bannerHeight.isActive = true
        containerTop = container.topAnchor.constraint(equalTo: banner.bottomAnchor)

        NSLayoutConstraint.activate([
            root.heightAnchor.constraint(equalToConstant: Theme.contentHeight + 76),

            tabs.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),

            banner.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 8),
            banner.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            containerTop,
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            divider.topAnchor.constraint(equalTo: container.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            footer.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 7),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -9),
        ])

        view = root
        showPane(0)
    }

    /// Called whenever the popover opens or the underlying data moves.
    func refresh() {
        // `togglePopover` refreshes before it shows, so on the very first click
        // this runs before AppKit has called `loadView` and the constraints set
        // up there do not exist yet. Loading on demand keeps one code path
        // instead of leaving the banner state to be fixed up later.
        loadViewIfNeeded()

        partnerPane.refresh()
        usagePane.refresh()
        shopPane.refresh()
        dexPane.refresh()
        tamerPane.refresh()

        if let last = monitor.lastRefresh {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            statusLabel.stringValue = "updated \(formatter.localizedString(for: last, relativeTo: Date()))"
        } else {
            statusLabel.stringValue = monitor.isRefreshing ? "scanning…" : ""
        }

        if let event = store.pendingEvent {
            banner.present(event) { [weak self] in
                self?.store.pendingEvent = nil
                self?.setBannerVisible(false)
            }
            setBannerVisible(true)
        } else {
            setBannerVisible(false)
        }
    }

    /// Shows or hides the banner by giving it space rather than by floating it
    /// over the panes. The popover's overall height never changes; the content
    /// area gives up the room instead.
    private func setBannerVisible(_ visible: Bool) {
        banner.isHidden = !visible
        // Defensive: these are built in `loadView`, and a caller that arrives
        // before it should get a no-op rather than a crash.
        guard isViewLoaded, bannerHeight != nil, containerTop != nil else { return }
        bannerHeight.isActive = !visible
        containerTop.constant = visible ? 8 : 0
        view.layoutSubtreeIfNeeded()
    }

    private func showPane(_ index: Int) {
        // The scrollers hold every pane except the DigiDex, so tabs past it map
        // one lower into that array.
        let scrollerIndex = index > Self.dexTab ? index - 1 : index
        for (position, scroller) in scrollers.enumerated() {
            scroller.isHidden = index == Self.dexTab || position != scrollerIndex
        }
        dexPane.isHidden = index != Self.dexTab
    }

    @objc private func switchTab() {
        showPane(tabs.selectedSegment)
    }

    @objc private func refreshNow() {
        Task { await monitor.refresh(); refresh() }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Settings menu

    @objc private func showSettings(_ sender: NSButton) {
        let settings = Settings.shared
        let menu = NSMenu()

        menu.addItem(toggle("Show token count in menu bar", #selector(toggleTokens), settings.showTokensInMenuBar))
        menu.addItem(toggle("Animate the partner", #selector(toggleAnimation), settings.animateSprite))
        menu.addItem(toggle("Floating desktop pet", #selector(togglePet), settings.floatingPetEnabled))
        menu.addItem(toggle("Notify on digivolution", #selector(toggleNotifications), settings.notificationsEnabled))
        menu.addItem(.separator())
        menu.addItem(toggle("Launch at login", #selector(toggleLogin), settings.launchesAtLogin))

        menu.addItem(.separator())
        let paceHeader = NSMenuItem(title: "Growth pace", action: nil, keyEquivalent: "")
        paceHeader.isEnabled = false
        menu.addItem(paceHeader)
        for pace in GrowthPace.allCases {
            let item = NSMenuItem(
                title: "  \(pace.label)", action: #selector(pickPace(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = pace.rawValue
            item.state = settings.growthPace == pace ? .on : .off
            item.toolTip = "Mega at \(TokenFormatter.short(GrowthCurve.requirement(for: .ultimate, pace: pace))) billable tokens"
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh every", action: nil, keyEquivalent: "")
        refresh.isEnabled = false
        menu.addItem(refresh)
        for minutes in [1, 2, 5, 15] {
            let item = NSMenuItem(
                title: "\(minutes) min", action: #selector(pickRefresh(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = minutes
            item.state = settings.refreshMinutes == minutes ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let about = NSMenuItem(
            title: "About & credits", action: #selector(showAbout), keyEquivalent: ""
        )
        about.target = self
        menu.addItem(about)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    /// CC BY-SA requires attribution to travel with the work, so it has to be
    /// reachable from inside the app and not only from the repository README.
    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "DigiTokenBar"
        alert.informativeText = """
            An unofficial, non-commercial fan project. Not affiliated with, \
            sponsored by, or endorsed by Bandai, Bandai Namco, or Toei Animation. \
            Digimon and Digital Monsters are trademarks of Bandai.

            Digimon data from digi-api.com, drawing on Wikimon, used under \
            CC BY-SA 3.0 and modified for this app. Artwork is fetched at runtime \
            and cached on your machine; none is redistributed with the app.

            Application code is MIT licensed.
            """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open digi-api.com")
        if alert.runModal() == .alertSecondButtonReturn,
           let url = URL(string: "https://digi-api.com") {
            NSWorkspace.shared.open(url)
        }
    }

    private func toggle(_ title: String, _ action: Selector, _ on: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    @objc private func toggleTokens() {
        Settings.shared.showTokensInMenuBar.toggle()
    }

    @objc private func toggleAnimation() {
        Settings.shared.animateSprite.toggle()
        refresh()
    }

    @objc private func togglePet() {
        Settings.shared.floatingPetEnabled.toggle()
    }

    @objc private func toggleNotifications() {
        Settings.shared.notificationsEnabled.toggle()
        Notifier.requestAuthorizationIfNeeded()
    }

    @objc private func toggleLogin() {
        let settings = Settings.shared
        if let error = settings.setLaunchAtLogin(!settings.launchesAtLogin) {
            // Registration fails for a build that is not in /Applications, which
            // is worth saying rather than silently doing nothing.
            let alert = NSAlert()
            alert.messageText = "Could not change the login item"
            alert.informativeText =
                "\(error.localizedDescription)\n\nThis usually means the app is running from somewhere other than /Applications."
            alert.runModal()
        }
    }

    @objc private func pickRefresh(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        Settings.shared.refreshMinutes = minutes
    }

    @objc private func pickPace(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let pace = GrowthPace(rawValue: raw)
        else { return }
        Settings.shared.growthPace = pace
        // Thresholds just moved under the current partner, so it may have earned
        // rungs it had not a moment ago.
        store.reevaluate()
        refresh()
    }
}

/// Announces a digivolution the first time the tamer opens the popover after it
/// happened, then gets out of the way.
@MainActor
final class DigivolutionBanner: NSView {
    private let title = UI.label("", size: 10, weight: .heavy, align: .center)
    private let body = UI.label("", size: 13, weight: .bold, rounded: true, align: .center)
    private let detail = UI.label("", size: 10, color: .secondaryLabelColor, align: .center)
    private var dismiss: (() -> Void)?

    init() {
        super.init(frame: .zero)
        isHidden = true
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Theme.accent.withAlphaComponent(0.5).cgColor
        layer?.cornerRadius = 10

        let close = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Dismiss")!,
            target: self, action: #selector(close)
        )
        close.isBordered = false
        close.contentTintColor = .tertiaryLabelColor

        let stack = UI.stack(.vertical, spacing: 4, [title, body, detail])
        stack.alignment = .centerX
        addSubview(stack)
        close.translatesAutoresizingMaskIntoConstraints = false
        addSubview(close)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 28),
            close.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present(_ event: DigivolutionEvent, dismiss: @escaping () -> Void) {
        self.dismiss = dismiss
        title.stringValue = event.isXAntibody ? "X-ANTIBODY DIGIVOLUTION" : "DIGIVOLUTION"
        title.textColor = event.isXAntibody ? Theme.danger : Theme.accent
        body.stringValue = "\(event.from)  →  \(event.to.name)"
        detail.stringValue = "\(event.stage.dubName) · \(event.reason)"
        isHidden = false
    }

    @objc private func close() { dismiss?() }
}
