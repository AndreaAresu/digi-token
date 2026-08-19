import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Fetches, cleans up and caches Digimon artwork.
///
/// Nothing visual ships in the binary. The first time a form appears we pull its
/// image, strip the white card digi-api paints it on, trim it, and keep the
/// result under Application Support — so every later request is a disk read and
/// the app works offline for anything the tamer has already met.
actor SpriteLoader {
    static let shared = SpriteLoader()

    private var memory: [Int: NSImage] = [:]
    private var silhouettes: [Int: NSImage] = [:]
    private var inFlight: [Int: Task<NSImage?, Never>] = [:]

    /// Bumped when the processing changes, so cached images from an older
    /// version are regenerated instead of served stale. v3 moved the cache from
    /// PNG to HEIC.
    private static let cacheVersion = 3

    /// Measured across 86 real sprites, HEIC at this quality averages 28 KB
    /// against 79 KB for the equivalent PNG — a full roster projects to 34 MB
    /// rather than 94 MB. Individual sprites do better than that (81 KB to 17 KB
    /// on a busy one), so do not quote the best case as the average.
    ///
    /// Alpha survives exactly, which is the part that matters: these images are
    /// cut-outs, and a format that flattened them would put the white card back.
    private static let heicQuality = 0.75

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
            let fileURL = Self.cacheDirectory.appendingPathComponent("\(entry.id).heic")
            if let data = try? Data(contentsOf: fileURL), let image = NSImage(data: data) {
                return image
            }

            guard !entry.img.isEmpty, let remote = URL(string: entry.img) else { return nil }
            guard let (data, response) = try? await URLSession.shared.data(from: remote),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let raw = NSImage(data: data)
            else { return nil }

            let cleaned = SpriteProcessor.process(raw)
            // PNG is the fallback rather than the format: if HEIC encoding is
            // ever unavailable, a bigger cache beats no cache.
            if let encoded = Self.heic(from: cleaned) ?? Self.png(from: cleaned) {
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

    private static func heic(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage
        else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.heic.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, cg,
            [kCGImageDestinationLossyCompressionQuality: heicQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
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

    /// The grey a silhouette is painted in.
    ///
    /// Fixed rather than taken from the system palette, and opaque rather than
    /// tinted. `labelColor` is white in the dark appearance, so a translucent
    /// wash of it lightened the artwork instead of hiding it — and whatever the
    /// colour, anything short of full opacity leaves the original showing
    /// through. This grey reads on both the dark cell and a light one.
    static let silhouetteInk = NSColor(calibratedWhite: 0.46, alpha: 1)

    /// The same artwork, reduced to its shape.
    ///
    /// Used for forms the tamer has not met but could reach next. It is drawn
    /// from the real sprite because a silhouette has to have the right shape to
    /// be worth showing — that is the whole tease — but it gives away nothing
    /// else: not the colours, not the markings, not which of two similar forms
    /// it is.
    func silhouette(for entry: DigimonEntry) async -> NSImage? {
        if let cached = silhouettes[entry.id] { return cached }
        guard let image = await self.image(for: entry) else { return nil }
        let flat = Self.flatten(image)
        silhouettes[entry.id] = flat
        return flat
    }

    static func flatten(_ image: NSImage, color: NSColor = silhouetteInk) -> NSImage {
        let output = NSImage(size: image.size)
        output.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: image.size),
            from: .zero, operation: .sourceOver, fraction: 1
        )
        color.set()
        // sourceAtop keeps the alpha and replaces only the colour, so the shape
        // survives — including its soft edges — and nothing of the artwork does.
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        output.unlockFocus()
        return output
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
