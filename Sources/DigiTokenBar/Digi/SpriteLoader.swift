import AppKit
import Foundation

/// Fetches and caches Digimon artwork.
///
/// Nothing visual ships in the binary. The first time a form appears we pull its
/// image, keep it under Application Support, and serve every later request from
/// disk — so the app works offline for anything the tamer has already met.
actor SpriteLoader {
    static let shared = SpriteLoader()

    private var memory: [Int: NSImage] = [:]
    private var inFlight: [Int: Task<NSImage?, Never>] = [:]

    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DigiTokenBar/sprites", isDirectory: true)
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
                  let image = NSImage(data: data)
            else { return nil }
            try? data.write(to: fileURL, options: .atomic)
            return image
        }

        inFlight[entry.id] = task
        let image = await task.value
        inFlight[entry.id] = nil
        if let image { memory[entry.id] = image }
        return image
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
    static func render(_ image: NSImage, height: CGFloat = 18) -> NSImage {
        let ratio = image.size.width / max(image.size.height, 1)
        let size = NSSize(width: (height * ratio).rounded(), height: height)
        let output = NSImage(size: size)
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero, operation: .sourceOver, fraction: 1
        )
        output.unlockFocus()
        // Left as a colour image on purpose: a Digimon rendered as a template
        // mask is an unrecognisable silhouette.
        output.isTemplate = false
        return output
    }
}
