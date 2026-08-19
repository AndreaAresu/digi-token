import AppKit

/// The popover: a tab strip, one of three panes, and a footer.
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
    private lazy var dexPane = DexPane(store: store)
    private lazy var scrollers: [NSScrollView] = []

    private var panes: [NSView] { [partnerPane, usagePane, dexPane] }

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

        tabs.segmentCount = 3
        for (index, title) in ["Partner", "Usage", "DigiDex"].enumerated() {
            tabs.setLabel(title, forSegment: index)
        }
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(switchTab)
        tabs.translatesAutoresizingMaskIntoConstraints = false

        container.translatesAutoresizingMaskIntoConstraints = false

        // Partner and Usage scroll; the DigiDex manages its own scroll view.
        for pane in [partnerPane, usagePane] {
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

        let quit = NSButton(title: "Quit", target: self, action: #selector(quit))
        quit.isBordered = false
        quit.font = .systemFont(ofSize: 11)
        quit.contentTintColor = .secondaryLabelColor

        let footer = UI.stack(.horizontal, spacing: 8, [
            refreshButton, statusLabel, UI.spacer(), quit,
        ])

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        for view in [tabs, container, footer, divider, banner] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }

        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),

            container.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 8),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.heightAnchor.constraint(equalToConstant: Theme.contentHeight),

            divider.topAnchor.constraint(equalTo: container.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            footer.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 7),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -9),

            banner.topAnchor.constraint(equalTo: container.topAnchor),
            banner.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])

        view = root
        showPane(0)
    }

    /// Called whenever the popover opens or the underlying data moves.
    func refresh() {
        partnerPane.refresh()
        usagePane.refresh()
        dexPane.refresh()

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
                self?.banner.isHidden = true
            }
        } else {
            banner.isHidden = true
        }
    }

    private func showPane(_ index: Int) {
        for (position, scroller) in scrollers.enumerated() {
            scroller.isHidden = position != index
        }
        dexPane.isHidden = index != 2
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
