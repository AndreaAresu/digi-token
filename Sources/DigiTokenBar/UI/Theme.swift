import AppKit

/// A Digivice-ish palette: an amber screen glow on a dark shell. It evokes the
/// device without copying any particular model's artwork.
enum Theme {
    static let accent = NSColor(calibratedRed: 0.98, green: 0.66, blue: 0.16, alpha: 1)
    static let screen = NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.16, alpha: 1)
    static let danger = NSColor.systemRed

    static func attribute(_ attribute: DigiAttribute) -> NSColor {
        switch attribute {
        case .vaccine: NSColor(calibratedRed: 0.36, green: 0.72, blue: 0.98, alpha: 1)
        case .data: NSColor(calibratedRed: 0.42, green: 0.80, blue: 0.45, alpha: 1)
        case .virus: NSColor(calibratedRed: 0.82, green: 0.42, blue: 0.85, alpha: 1)
        case .free: NSColor(calibratedRed: 0.66, green: 0.66, blue: 0.72, alpha: 1)
        }
    }

    static let popoverWidth: CGFloat = 340
    static let contentHeight: CGFloat = 392
}

/// Small constructors so the layout code below reads as layout rather than as
/// twenty lines of property assignment per label.
@MainActor
enum UI {
    static func label(
        _ text: String,
        size: CGFloat = 11,
        weight: NSFont.Weight = .regular,
        color: NSColor = .labelColor,
        rounded: Bool = false,
        mono: Bool = false,
        align: NSTextAlignment = .left
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        var font = NSFont.systemFont(ofSize: size, weight: weight)
        if rounded, let descriptor = font.fontDescriptor.withDesign(.rounded) {
            font = NSFont(descriptor: descriptor, size: size) ?? font
        }
        if mono {
            font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        }
        field.font = font
        field.textColor = color
        field.alignment = align
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    /// A small all-caps section heading.
    static func caption(_ text: String) -> NSTextField {
        let field = label(
            text.uppercased(), size: 9, weight: .heavy, color: .tertiaryLabelColor
        )
        field.attributedStringValue = NSAttributedString(
            string: text.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .heavy),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .kern: 1.3,
            ]
        )
        return field
    }

    static func stack(
        _ axis: NSUserInterfaceLayoutOrientation,
        spacing: CGFloat = 6,
        alignment: NSLayoutConstraint.Attribute? = nil,
        _ views: [NSView]
    ) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = axis
        stack.spacing = spacing
        stack.alignment = alignment ?? (axis == .vertical ? .leading : .centerY)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        return view
    }

    /// A rounded panel used for stat tiles and cards.
    static func card(_ content: NSView, radius: CGFloat = 8, fill: NSColor? = nil) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = radius
        box.layer?.backgroundColor = (fill ?? NSColor.labelColor.withAlphaComponent(0.05)).cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            content.topAnchor.constraint(equalTo: box.topAnchor, constant: 7),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -7),
        ])
        return box
    }
}

/// A flat progress bar. `NSProgressIndicator` cannot be tinted reliably across
/// appearances, and the bar is the one element the tamer reads at a glance.
final class BarView: NSView {
    var value: Double = 0 { didSet { needsDisplay = true } }
    var tint: NSColor = Theme.accent { didSet { needsDisplay = true } }
    var track: NSColor = NSColor.labelColor.withAlphaComponent(0.12)

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 6) }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        track.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let clamped = max(0, min(1, value))
        guard clamped > 0 else { return }
        let width = max(bounds.height, bounds.width * clamped)
        tint.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height),
            xRadius: radius, yRadius: radius
        ).fill()
    }
}

/// The sparkline of recent 5-hour windows.
final class HistogramView: NSView {
    var values: [Int] = [] { didSet { needsDisplay = true } }
    var activeIndex: Int?

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 52) }

    override func draw(_ dirtyRect: NSRect) {
        guard !values.isEmpty else { return }
        let peak = CGFloat(max(1, values.max() ?? 1))
        let gap: CGFloat = 3
        let width = (bounds.width - gap * CGFloat(values.count - 1)) / CGFloat(values.count)

        for (index, value) in values.enumerated() {
            let height = max(3, bounds.height * CGFloat(value) / peak)
            let rect = NSRect(
                x: CGFloat(index) * (width + gap), y: 0, width: width, height: height
            )
            let isActive = index == activeIndex
            (isActive ? Theme.accent : Theme.accent.withAlphaComponent(0.45)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }
}

/// Displays a Digimon, loading its artwork the first time it is shown.
final class SpriteView: NSImageView {
    private var currentID: Int?
    private var wantsIdleMotion = false

    /// A slow vertical drift, so the partner reads as alive rather than as a
    /// sticker. Driven by Core Animation on the layer, which costs no timer and
    /// no redraw on the main thread.
    var idleMotion: Bool {
        get { wantsIdleMotion }
        set {
            wantsIdleMotion = newValue
            newValue ? startIdleMotion() : layer?.removeAnimation(forKey: "idle")
        }
    }

    init(size: CGFloat) {
        super.init(frame: .zero)
        imageScaling = .scaleProportionallyUpOrDown
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
        ])
    }

    private func startIdleMotion() {
        guard let layer else { return }
        layer.removeAnimation(forKey: "idle")

        let bob = CABasicAnimation(keyPath: "transform.translation.y")
        bob.fromValue = -2.0
        bob.toValue = 2.0
        bob.duration = 1.6
        bob.autoreverses = true
        bob.repeatCount = .infinity
        bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        // A touch of squash on the way down sells the weight of the thing.
        let squash = CABasicAnimation(keyPath: "transform.scale.y")
        squash.fromValue = 1.0
        squash.toValue = 0.97
        squash.duration = 1.6
        squash.autoreverses = true
        squash.repeatCount = .infinity
        squash.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let group = CAAnimationGroup()
        group.animations = [bob, squash]
        group.duration = 3.2
        group.repeatCount = .infinity
        layer.add(group, forKey: "idle")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Core Animation drops animations when a view leaves the window, which
        // happens every time the popover closes.
        if wantsIdleMotion, window != nil { startIdleMotion() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Placeholder for a Digimon the tamer has not met, drawn without fetching
    /// the real artwork.
    func showUnknown() {
        currentID = nil
        alphaValue = 0.32
        contentFilters = []
        image = NSImage(systemSymbolName: "questionmark.square.dashed", accessibilityDescription: nil)
        contentTintColor = .tertiaryLabelColor
    }

    func show(_ entry: DigimonEntry?) {
        alphaValue = 1
        contentFilters = []

        guard let entry else {
            image = NSImage(
                systemSymbolName: "oval.portrait.fill", accessibilityDescription: "DigiEgg"
            )
            contentTintColor = .tertiaryLabelColor
            currentID = nil
            return
        }
        guard currentID != entry.id else { return }
        currentID = entry.id
        image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil)
        contentTintColor = .quaternaryLabelColor

        Task { [weak self] in
            let loaded = await SpriteLoader.shared.image(for: entry)
            await MainActor.run {
                guard let self, self.currentID == entry.id, let loaded else { return }
                self.contentTintColor = nil
                self.image = loaded
            }
        }
    }

}
