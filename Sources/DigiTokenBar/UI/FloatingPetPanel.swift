import AppKit

/// A desktop pet: the partner, floating over everything, draggable anywhere.
///
/// It is a borderless transparent panel rather than a window so it has no chrome
/// and never takes focus — clicking it must not pull the tamer out of whatever
/// they were typing in.
@MainActor
final class FloatingPetPanel: NSPanel {
    private let sprite: SpriteView
    private var dragOffset: NSPoint?
    private weak var store: PartnerStore?

    init(store: PartnerStore) {
        self.store = store
        let size = Settings.shared.petSize
        sprite = SpriteView(size: size)

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isMovableByWindowBackground = false
        // Follows the tamer across Spaces and stays put in Mission Control.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false

        let host = PetHostView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        host.panel = self
        host.addSubview(sprite)
        sprite.idleMotion = Settings.shared.animateSprite
        NSLayoutConstraint.activate([
            sprite.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            sprite.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        contentView = host

        restorePosition()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func refresh() {
        guard let partner = store?.partner else { return }
        sprite.show(partner.entry)
        sprite.idleMotion = Settings.shared.animateSprite
        sprite.toolTip = "\(partner.displayName) · \(partner.stage.dubName)"
        // After `show`, which sets the plain species name.
        sprite.setAccessibilityLabel("\(partner.displayName), \(partner.stage.dubName)")
    }

    /// Rebuilds at a new size. Simpler and less error-prone than mutating the
    /// sprite's constraints in place.
    func applySize(_ size: Double) {
        let origin = frame.origin
        setContentSize(NSSize(width: size, height: size))
        setFrameOrigin(origin)
        sprite.removeConstraints(sprite.constraints)
        NSLayoutConstraint.activate([
            sprite.widthAnchor.constraint(equalToConstant: size),
            sprite.heightAnchor.constraint(equalToConstant: size),
        ])
    }

    private func restorePosition() {
        guard let screen = NSScreen.main else { return }
        if let saved = Settings.shared.petOrigin, isOnAnyScreen(saved) {
            setFrameOrigin(saved)
            return
        }
        // Default to the lower-right, clear of the menu bar and most dock setups.
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(
            x: visible.maxX - frame.width - 40,
            y: visible.minY + 60
        ))
    }

    /// Guards against a saved position on a monitor that is no longer attached,
    /// which would otherwise leave the pet permanently off-screen.
    private func isOnAnyScreen(_ origin: CGPoint) -> Bool {
        let probe = NSRect(x: origin.x, y: origin.y, width: frame.width, height: frame.height)
        return NSScreen.screens.contains { $0.visibleFrame.intersects(probe) }
    }

    // MARK: - Dragging

    fileprivate func beginDrag(at point: NSPoint) {
        dragOffset = point
    }

    fileprivate func continueDrag(to screenPoint: NSPoint) {
        guard let dragOffset else { return }
        setFrameOrigin(NSPoint(
            x: screenPoint.x - dragOffset.x,
            y: screenPoint.y - dragOffset.y
        ))
    }

    fileprivate func endDrag() {
        dragOffset = nil
        Settings.shared.petOrigin = frame.origin
    }

    fileprivate func showContextMenu(for event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        for size in [64.0, 96.0, 128.0, 192.0] {
            let item = NSMenuItem(
                title: "\(Int(size)) px", action: #selector(pickSize(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = size
            item.state = abs(Settings.shared.petSize - size) < 1 ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let hide = NSMenuItem(title: "Hide pet", action: #selector(hidePet), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func pickSize(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? Double else { return }
        Settings.shared.petSize = size
        applySize(Settings.shared.petSize)
    }

    @objc private func hidePet() {
        Settings.shared.floatingPetEnabled = false
    }
}

/// The panel's content view. It exists to catch mouse events, since a borderless
/// non-activating panel does not get them for free.
private final class PetHostView: NSView {
    weak var panel: FloatingPetPanel?

    override func mouseDown(with event: NSEvent) {
        // Where inside the pet the grab happened, so the artwork does not snap
        // to the cursor on the first movement.
        panel?.beginDrag(at: event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        panel?.continueDrag(to: window.convertPoint(toScreen: event.locationInWindow))
    }

    override func mouseUp(with event: NSEvent) {
        panel?.endDrag()
    }

    override func rightMouseDown(with event: NSEvent) {
        panel?.showContextMenu(for: event, in: self)
    }

    /// Only the artwork should be draggable; clicks on the transparent corners
    /// belong to whatever is behind the pet.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        let radius = min(bounds.width, bounds.height) / 2
        let centre = NSPoint(x: bounds.midX, y: bounds.midY)
        let distance = hypot(local.x - centre.x, local.y - centre.y)
        return distance <= radius ? super.hitTest(point) : nil
    }
}
