import AppKit

/// Drives the popover the way `AppDelegate` does, headlessly.
///
/// `scripts/test.sh` deliberately compiles Core and Digi only, because the UI
/// needs a running `NSApplication`. That left one gap wide enough to ship a
/// crash through: `togglePopover` calls `refresh()` *before* it shows the
/// popover, so on the first click the view has not been loaded yet — and a
/// refresh that touched anything built in `loadView` trapped on nil and took the
/// app down the moment the tamer clicked the menu bar icon.
///
/// The screenshot harness never caught it because it read `controller.view`
/// first, which loads the view and hides exactly the ordering that breaks.
/// So this exercises the real order instead.
@main
enum UISmoke {
    @MainActor
    static func main() async {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "repro-\(UUID()).json")
        let store = PartnerStore(storeURL: url)
        let monitor = UsageMonitor()
        let controller = PopoverController(store: store, monitor: monitor)

        // 1. Exactly what togglePopover does on the first click: refresh before
        //    anything has touched `view`, so loadView has not run.
        controller.refresh()
        print("ok  cold refresh before loadView")

        // 2. The popover is then shown, which loads the view.
        let v = controller.view
        v.frame = NSRect(x: 0, y: 0, width: Theme.popoverWidth, height: Theme.contentHeight + 76)
        v.layoutSubtreeIfNeeded()
        print("ok  view loaded (\(Int(v.frame.height))pt tall)")

        // 3. Second click.
        controller.refresh()
        print("ok  warm refresh")

        // 4. A digivolution lands: the banner has to appear and take its space
        //    without the popover changing size.
        let before = v.frame.height
        if let entry = DigiDex.shared.all.first {
            store.pendingEvent = DigivolutionEvent(
                from: "Koromon", to: entry, stage: .child,
                isXAntibody: false, reason: "test", date: Date()
            )
        }
        controller.refresh()
        v.layoutSubtreeIfNeeded()
        print("ok  refresh with a banner (height \(Int(before)) -> \(Int(v.frame.height)))")

        // 5. Dismissed again.
        store.pendingEvent = nil
        controller.refresh()
        v.layoutSubtreeIfNeeded()
        print("ok  refresh after dismissing (height \(Int(v.frame.height)))")

        // 6. Every tab, since each pane refreshes on every call.
        for tab in 0..<5 {
            func seg(_ x: NSView) -> NSSegmentedControl? {
                if let s = x as? NSSegmentedControl, s.segmentCount == 5 { return s }
                for sub in x.subviews { if let f = seg(sub) { return f } }
                return nil
            }
            if let tabs = seg(v) {
                tabs.selectedSegment = tab
                if let a = tabs.action { _ = tabs.target?.perform(a, with: tabs) }
            }
            controller.refresh()
        }
        print("ok  all five tabs refreshed")
        print("\nUI smoke passed")
        exit(0)
    }
}
