import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = PartnerStore()
    private lazy var monitor = UsageMonitor()
    private let settings = Settings.shared

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var controller: PopoverController!
    private var pet: FloatingPetPanel?

    /// The partner's artwork at menu-bar scale, kept so the idle bob can redraw
    /// it at a new offset without going back through the loader.
    private var menuBarArtwork: NSImage?
    private var bobTimer: Timer?
    private var bobPhase = 0

    /// Watches for a click outside the popover while it is open.
    ///
    /// `.transient` is supposed to do this on its own, and mostly does — but the
    /// popover is made key below so the DigiDex search field can be typed in,
    /// and a key popover belonging to an accessory app stops seeing some of the
    /// clicks that should dismiss it: clicking straight into another app's
    /// window, or into a window of an app that was already frontmost, would
    /// leave it hanging there. Watching for the click ourselves makes the
    /// behaviour the same every time.
    private var dismissMonitors: [Any] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)

        controller = PopoverController(store: store, monitor: monitor)
        popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self

        monitor.attach(partnerStore: store)
        monitor.onChange = { [weak self] in
            guard let self else { return }
            self.updateStatusItem()
            // A scan that lands while the panel is open should be visible in it.
            // Without this the popover shows whatever was true when it opened
            // until the tamer closes and reopens it.
            if self.popover.isShown { self.controller.refresh() }
        }
        store.onChange = { [weak self] in
            self?.updateStatusItem()
            self?.pet?.refresh()
        }
        store.onDigivolution = { event in
            event.stage == .babyI && event.reason == "hatched"
                ? Notifier.hatched(event.to)
                : Notifier.digivolved(event)
        }
        settings.onChange = { [weak self] in self?.applySettings() }

        SpriteLoader.removeStaleCaches()
        Notifier.requestAuthorizationIfNeeded()
        monitor.refreshInterval = TimeInterval(settings.refreshMinutes * 60)
        monitor.start()

        applySettings()
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

    // MARK: - Settings

    private func applySettings() {
        monitor.refreshInterval = TimeInterval(settings.refreshMinutes * 60)
        updateFloatingPet()
        updateBobTimer()
        updateStatusItem()
    }

    private func updateFloatingPet() {
        if settings.floatingPetEnabled {
            if pet == nil { pet = FloatingPetPanel(store: store) }
            pet?.applySize(settings.petSize)
            pet?.refresh()
            pet?.orderFront(nil)
        } else {
            pet?.orderOut(nil)
            pet = nil
        }
    }

    // MARK: - Menu bar

    private func updateBobTimer() {
        bobTimer?.invalidate()
        bobTimer = nil
        bobPhase = 0
        guard settings.animateSprite else {
            redrawStatusImage()
            return
        }
        // Four frames a second is enough to read as motion and costs nothing;
        // the status item is 18 points tall and the offsets are whole pixels.
        bobTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.bobPhase = (self.bobPhase + 1) % Self.bobOffsets.count
                self.redrawStatusImage()
            }
        }
    }

    private static let bobOffsets: [CGFloat] = [0, 1, 2, 1, 0, 0, 1, 0]

    private func redrawStatusImage() {
        guard let button = statusItem.button else { return }
        guard let artwork = menuBarArtwork else { return }
        let lift = settings.animateSprite ? Self.bobOffsets[bobPhase] : 0
        button.image = MenuBarSprite.render(artwork, lift: lift)
    }

    /// Keeps the menu bar showing the partner and today's billable total.
    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        let today = monitor.snapshot.combinedToday.billable
        button.title = settings.showTokensInMenuBar && today > 0
            ? " \(TokenFormatter.short(today))"
            : ""

        // The status item is a sprite and, at most, a token count. Without a
        // label VoiceOver announces an unnamed button in the menu bar.
        button.setAccessibilityLabel(
            "DigiTokenBar — \(store.partner.displayName), "
                + "\(TokenFormatter.short(today)) billable tokens today"
        )

        guard let entry = store.partner.entry else {
            menuBarArtwork = nil
            button.image = NSImage(
                systemSymbolName: "oval.portrait.fill", accessibilityDescription: "DigiEgg"
            )
            button.toolTip = "DigiTama — \(TokenFormatter.short(store.partner.tokens)) tokens"
            button.setAccessibilityLabel(
                "DigiTokenBar — DigiTama, \(TokenFormatter.short(store.partner.tokens)) tokens to hatch"
            )
            return
        }

        button.toolTip = "\(store.partner.displayName) · \(store.partner.stage.dubName)"
        Task { [weak self] in
            guard let image = await SpriteLoader.shared.image(for: entry) else { return }
            await MainActor.run {
                guard let self else { return }
                self.menuBarArtwork = image
                self.redrawStatusImage()
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
        startDismissWatch()
        Task { await monitor.refresh(); controller.refresh() }
    }

    // MARK: - Dismissal

    /// Closes the popover on the first click that lands anywhere else.
    ///
    /// Two monitors, because one event stream does not cover both cases: the
    /// global one sees clicks in other applications, which never reach us, and
    /// the local one sees clicks inside our own windows — the floating pet, or
    /// the status item itself. The local monitor returns the event untouched so
    /// whatever was clicked still receives it.
    private func startDismissWatch() {
        stopDismissWatch()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            Task { @MainActor in self?.closePopoverFromOutsideClick() }
        })
        if let global { dismissMonitors.append(global) }

        let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let self else { return event }
            // A click inside the popover is not an outside click, and the status
            // item has its own toggle — closing here as well would reopen it.
            let inPopover = event.window === self.popover.contentViewController?.view.window
            let inStatusItem = event.window === self.statusItem.button?.window
            if !inPopover, !inStatusItem {
                self.closePopoverFromOutsideClick()
            }
            return event
        })
        if let local { dismissMonitors.append(local) }
    }

    private func closePopoverFromOutsideClick() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    private func stopDismissWatch() {
        dismissMonitors.forEach(NSEvent.removeMonitor)
        dismissMonitors.removeAll()
    }

    /// Called by AppKit whichever way the popover closed — our own watch, the
    /// transient behaviour, or the status item being clicked again — so the
    /// monitors never outlive the window they were installed for.
    func popoverDidClose(_ notification: Notification) {
        stopDismissWatch()
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
