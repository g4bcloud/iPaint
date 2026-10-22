import AppKit

/// One drawing layer: its own bitmap, plus how it is composited.
///
/// The bottom layer is opaque white and acts as the paper; every layer above it
/// starts fully transparent so whatever is underneath shows through.
final class Layer: Identifiable {
    let id = UUID()
    var name: String
    var visible: Bool = true
    var opacity: CGFloat = 1
    private(set) var context: CGContext

    init?(name: String, size: CGSize, fillWhite: Bool) {
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        if fillWhite {
            ctx.setFillColor(CGColor.white)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        self.context = ctx
        self.name = name
    }

    var image: CGImage? { context.makeImage() }

    var size: CGSize { CGSize(width: context.width, height: context.height) }

    /// Roughly how much memory one snapshot of this layer costs.
    var byteCost: Int { context.bytesPerRow * context.height }

    func copyingSettings(from other: Layer) {
        visible = other.visible
        opacity = other.opacity
    }

    /// A scaled-down preview for the layers list.
    func thumbnail(fitting box: CGSize) -> CGImage? {
        guard let src = image else { return nil }
        let scale = min(box.width / CGFloat(src.width), box.height / CGFloat(src.height))
        let w = max(1, Int((CGFloat(src.width) * scale).rounded()))
        let h = max(1, Int((CGFloat(src.height) * scale).rounded()))
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

/// A restorable copy of the whole layer stack, used by undo for structural edits.
struct DocumentState {
    struct Entry {
        let image: CGImage?
        let name: String
        let visible: Bool
        let opacity: CGFloat
    }
    let entries: [Entry]
    let activeIndex: Int
    let size: CGSize

    var byteCost: Int {
        entries.reduce(0) { $0 + ($1.image.map { $0.bytesPerRow * $0.height } ?? 0) }
    }
}
