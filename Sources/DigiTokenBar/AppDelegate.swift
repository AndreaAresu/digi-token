import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = PartnerStore()
    private lazy var monitor = UsageMonitor()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var controller: PopoverController!
    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.title = " —"
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)

        controller = PopoverController(store: store, monitor: monitor)
        popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self

        monitor.attach(partnerStore: store)
        monitor.onChange = { [weak self] in self?.updateStatusItem() }
        store.onChange = { [weak self] in self?.updateStatusItem() }
        monitor.start()

        updateStatusItem()

        // Opening the popover normally needs a click, which makes the UI awkward
        // to inspect or screenshot. This shows it on launch instead.
        if ProcessInfo.processInfo.environment["DIGITOKENBAR_OPEN"] == "1" {
            Task {
                try? await Task.sleep(for: .seconds(3))
                self.togglePopover()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.save()
    }

    /// Keeps the menu bar showing the partner and today's billable total.
    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        let today = monitor.snapshot.combinedToday.billable
        button.title = today > 0 ? " \(TokenFormatter.short(today))" : ""

        guard let entry = store.partner.entry else {
            button.image = NSImage(
                systemSymbolName: "oval.portrait.fill", accessibilityDescription: "DigiEgg"
            )
            button.toolTip = "DigiTama — \(TokenFormatter.short(store.partner.tokens)) tokens"
            return
        }

        button.toolTip = "\(store.partner.displayName) · \(store.partner.stage.dubName)"
        Task { [weak self] in
            guard let image = await SpriteLoader.shared.image(for: entry) else { return }
            await MainActor.run {
                self?.statusItem.button?.image = MenuBarSprite.render(image)
            }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        controller.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // A transient popover keeps focus behind it otherwise, which makes the
        // search field in the DigiDex tab unusable.
        popover.contentViewController?.view.window?.makeKey()
        Task { await monitor.refresh(); controller.refresh() }
    }
}

/// Entry point. `LSUIElement` in the bundle keeps the app out of the Dock, so
/// the status item is the whole interface.
@main
@MainActor
enum DigiTokenBar {
    static func main() {
        let app = NSApplication.shared
        // `NSApplication.delegate` is a weak reference, and `run()` does not
        // return until the app quits, so this local is what keeps it alive.
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
