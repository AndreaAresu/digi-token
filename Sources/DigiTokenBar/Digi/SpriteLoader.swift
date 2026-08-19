import AppKit
import Foundation

/// Fetches, cleans up and caches Digimon artwork.
///
/// Nothing visual ships in the binary. The first time a form appears we pull its
/// image, strip the white card digi-api paints it on, trim it, and keep the
/// result under Application Support — so every later request is a disk read and
/// the app works offline for anything the tamer has already met.
actor SpriteLoader {
    static let shared = SpriteLoader()

    private var memory: [Int: NSImage] = [:]
    private var inFlight: [Int: Task<NSImage?, Never>] = [:]

    /// Bumped when the processing changes, so cached images from an older
    /// version are regenerated instead of served stale.
    private static let cacheVersion = 2

    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DigiTokenBar/sprites-v\(cacheVersion)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    func image(for entry: DigimonEntry) async -> NSImage? {
        if let cached = memory[entry.id] { return cached }
        if let task = inFlight[entry.id] { return await task.value }

        let task = Task<NSImage?, Never> { [entry] in
            let fileURL = Self.cacheDirectory.appendingPathComponent("\(entry.id).png")
            if let data = try? Data(contentsOf: fileURL), let image = NSImage(data: data) {
                return image
            }

            guard !entry.img.isEmpty, let remote = URL(string: entry.img) else { return nil }
            guard let (data, response) = try? await URLSession.shared.data(from: remote),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let raw = NSImage(data: data)
            else { return nil }

            let cleaned = SpriteProcessor.process(raw)
            if let encoded = Self.png(from: cleaned) {
                try? encoded.write(to: fileURL, options: .atomic)
            }
            return cleaned
        }

        inFlight[entry.id] = task
        let image = await task.value
        inFlight[entry.id] = nil
        if let image { memory[entry.id] = image }
        return image
    }

    private static func png(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Deletes sprite caches written by an older processing version, which would
    /// otherwise sit on disk forever holding images the app will never read again.
    static func removeStaleCaches() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DigiTokenBar", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        let current = "sprites-v\(cacheVersion)"
        for url in entries {
            let name = url.lastPathComponent
            guard name == "sprites" || name.hasPrefix("sprites-v") else { continue }
            guard name != current else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Warms the cache for forms the tamer is about to see.
    func prefetch(_ entries: [DigimonEntry]) async {
        await withTaskGroup(of: Void.self) { group in
            for entry in entries.prefix(12) {
                group.addTask { _ = await self.image(for: entry) }
            }
        }
    }
}

/// Renders a Digimon at a size that stays crisp in the menu bar, where the
/// system hands us an 18-point slot and full-resolution artwork would blur.
enum MenuBarSprite {
    /// `lift` nudges the sprite up by a pixel or two, which is how the idle bob
    /// is drawn without touching the status item's layout.
    static func render(_ image: NSImage, height: CGFloat = 18, lift: CGFloat = 0) -> NSImage {
        let ratio = image.size.width / max(image.size.height, 1)
        let drawHeight = height - abs(lift)
        let width = max(1, (drawHeight * ratio).rounded())
        let canvas = NSSize(width: width, height: height)

        let output = NSImage(size: canvas)
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: lift > 0 ? lift : 0, width: width, height: drawHeight),
            from: .zero, operation: .sourceOver, fraction: 1
        )
        output.unlockFocus()
        // Left as a colour image on purpose: a Digimon rendered as a template
        // mask is an unrecognisable silhouette.
        output.isTemplate = false
        return output
    }
}
