import AppKit
import CoreGraphics

/// Turns digi-api reference artwork into something that sits well on a dark
/// panel and in the menu bar.
///
/// Almost every image on digi-api is a painting on a solid white card. Dropped
/// straight into the app that reads as a white rectangle floating in a dark UI,
/// which is what made the first build look wrong. This strips the card and trims
/// the margin, once per Digimon, and the result is cached to disk.
enum SpriteProcessor {
    /// How close to white a pixel must be to count as background.
    private static let whiteCutoff: UInt8 = 233
    /// Maximum spread between channels for a pixel to count as neutral. Keeps a
    /// pale yellow body from being eaten along with the card behind it.
    private static let neutralTolerance: Int = 22

    /// Removes the background card and crops to the artwork.
    ///
    /// Only white *connected to the border* is removed, by flood fill. A plain
    /// "make every light pixel transparent" pass would punch holes through eyes,
    /// teeth and highlights — Zurumon alone would lose most of its face.
    static func process(_ image: NSImage) -> NSImage {
        guard let source = cgImage(from: image) else { return image }
        guard let rgba = pixels(of: source) else { return image }

        let width = source.width
        let height = source.height
        guard width > 1, height > 1 else { return image }

        var buffer = rgba
        // An image that already ships with real transparency needs no card
        // removed; it only wants trimming.
        if !hasMeaningfulAlpha(buffer, width: width, height: height) {
            floodFillBackground(&buffer, width: width, height: height)
        }

        guard let bounds = opaqueBounds(buffer, width: width, height: height) else { return image }
        guard let stripped = makeImage(buffer, width: width, height: height) else { return image }
        guard let cropped = stripped.cropping(to: bounds) else { return image }

        return NSImage(cgImage: cropped, size: pointSize(of: bounds, pixels: source, points: image))
    }

    /// The crop is measured in pixels, but an `NSImage`'s `size` is in points.
    ///
    /// The two are only the same when the source happens to be 1x. Anything that
    /// carries a backing scale — an image drawn with `lockFocus` on a Retina
    /// display, or a download whose DPI metadata says otherwise — has twice the
    /// pixels per point, and handing those pixel counts to `NSImage(cgImage:size:)`
    /// declares the sprite twice as large as it is. Everything downstream sizes
    /// itself off `size`, so the sprite would be laid out at double scale and
    /// drawn soft, and `SpriteLoader.flatten` would build its silhouette canvas
    /// on the same inflated number.
    private static func pointSize(of bounds: CGRect, pixels: CGImage, points: NSImage) -> NSSize {
        let scaleX = points.size.width > 0 ? CGFloat(pixels.width) / points.size.width : 1
        let scaleY = points.size.height > 0 ? CGFloat(pixels.height) / points.size.height : 1
        guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else {
            return NSSize(width: bounds.width, height: bounds.height)
        }
        return NSSize(width: bounds.width / scaleX, height: bounds.height / scaleY)
    }

    // MARK: - Pixel plumbing

    private static func cgImage(from image: NSImage) -> CGImage? {
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Premultiplied-last RGBA bytes, which is the layout the fill below assumes.
    private static func pixels(of image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width * height < 16_000_000 else { return nil }

        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &buffer,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private static func makeImage(_ buffer: [UInt8], width: Int, height: Int) -> CGImage? {
        var mutable = buffer
        guard let context = CGContext(
            data: &mutable,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        return context.makeImage()
    }

    /// Whether the image already carries transparency worth respecting.
    private static func hasMeaningfulAlpha(_ buffer: [UInt8], width: Int, height: Int) -> Bool {
        var transparent = 0
        // Sampling the border is enough: a cut-out is transparent at its edges,
        // a card is not.
        for x in stride(from: 0, to: width, by: max(1, width / 64)) {
            for y in [0, height - 1] {
                if buffer[(y * width + x) * 4 + 3] < 16 { transparent += 1 }
            }
        }
        for y in stride(from: 0, to: height, by: max(1, height / 64)) {
            for x in [0, width - 1] {
                if buffer[(y * width + x) * 4 + 3] < 16 { transparent += 1 }
            }
        }
        return transparent > 8
    }

    private static func isBackground(_ buffer: [UInt8], at index: Int) -> Bool {
        let alpha = buffer[index + 3]
        if alpha < 16 { return true }
        let r = Int(buffer[index])
        let g = Int(buffer[index + 1])
        let b = Int(buffer[index + 2])
        let brightest = max(r, max(g, b))
        let darkest = min(r, min(g, b))
        return brightest >= Int(whiteCutoff) && (brightest - darkest) <= neutralTolerance
    }

    /// Clears background-coloured pixels reachable from the border.
    private static func floodFillBackground(_ buffer: inout [UInt8], width: Int, height: Int) {
        var visited = [Bool](repeating: false, count: width * height)
        var stack: [Int] = []
        stack.reserveCapacity(width * 2)

        func seed(_ x: Int, _ y: Int) {
            let pixel = y * width + x
            guard !visited[pixel] else { return }
            guard isBackground(buffer, at: pixel * 4) else { return }
            visited[pixel] = true
            stack.append(pixel)
        }

        for x in 0..<width {
            seed(x, 0)
            seed(x, height - 1)
        }
        for y in 0..<height {
            seed(0, y)
            seed(width - 1, y)
        }

        while let pixel = stack.popLast() {
            let index = pixel * 4
            buffer[index] = 0
            buffer[index + 1] = 0
            buffer[index + 2] = 0
            buffer[index + 3] = 0

            let x = pixel % width
            let y = pixel / width
            if x > 0 { seed(x - 1, y) }
            if x < width - 1 { seed(x + 1, y) }
            if y > 0 { seed(x, y - 1) }
            if y < height - 1 { seed(x, y + 1) }
        }
    }

    /// Bounding box of everything still visible, with a small margin so the
    /// artwork does not sit flush against the frame.
    private static func opaqueBounds(_ buffer: [UInt8], width: Int, height: Int) -> CGRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1

        for y in 0..<height {
            let row = y * width
            for x in 0..<width where buffer[(row + x) * 4 + 3] > 24 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        let pad = 2
        minX = max(0, minX - pad)
        minY = max(0, minY - pad)
        maxX = min(width - 1, maxX + pad)
        maxY = min(height - 1, maxY + pad)

        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
