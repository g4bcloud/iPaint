import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - Tools

enum Tool: Equatable {
    case select
    case freeSelect
    case pencil
    case fill
    case text
    case eraser
    case picker      // color eyedropper
    case magnifier
    case brush(BrushKind)
    case shape(ShapeKind)
}

enum BrushKind: String, CaseIterable, Identifiable {
    case brush = "Brush"
    case calligraphyPen = "Calligraphy pen"
    case calligraphyBrush = "Calligraphy brush"
    case airbrush = "Airbrush"
    case oilBrush = "Oil brush"
    case crayon = "Crayon"
    case marker = "Marker"
    case naturalPencil = "Natural pencil"
    case watercolor = "Watercolour brush"
    var id: String { rawValue }

    /// Shown under the brush name in its hover card.
    var detail: String {
        switch self {
        case .brush: return "A plain round brush."
        case .calligraphyPen: return "A narrow angled nib, thin on one stroke and wide on the other."
        case .calligraphyBrush: return "A broad angled nib for lettering."
        case .airbrush: return "Sprays colour. Hold the button still to build it up."
        case .oilBrush: return "A thick, heavy stroke."
        case .crayon: return "A grainy, waxy line."
        case .marker: return "A translucent stroke that darkens where it overlaps."
        case .naturalPencil: return "A soft, lightly textured pencil line."
        case .watercolor: return "A thin wash that builds up as you paint over it."
        }
    }

    var symbol: String {
        switch self {
        case .brush: return "paintbrush.pointed.fill"
        case .calligraphyPen: return "pencil.tip"
        case .calligraphyBrush: return "paintbrush.fill"
        case .airbrush: return "humidity.fill"
        case .oilBrush: return "paintbrush"
        case .crayon: return "pencil.and.outline"
        case .marker: return "highlighter"
        case .naturalPencil: return "pencil"
        case .watercolor: return "drop.fill"
        }
    }
}

enum ShapeKind: String, CaseIterable, Identifiable {
    case line = "Line"
    case curve = "Curve"
    case oval = "Oval"
    case rectangle = "Rectangle"
    case roundedRectangle = "Rounded rectangle"
    case polygon = "Polygon"
    case triangle = "Triangle"
    case rightTriangle = "Right-angled triangle"
    case diamond = "Diamond"
    case pentagon = "Pentagon"
    case hexagon = "Hexagon"
    case arrowRight = "Right arrow"
    case arrowLeft = "Left arrow"
    case arrowUp = "Up arrow"
    case arrowDown = "Down arrow"
    case star4 = "Four-point star"
    case star5 = "Five-point star"
    case star6 = "Six-point star"
    case calloutRounded = "Rounded rectangular callout"
    case calloutOval = "Oval callout"
    case calloutCloud = "Cloud callout"
    case heart = "Heart"
    case lightning = "Lightning"
    var id: String { rawValue }

    /// Extra hint shown in the hover card for shapes that need one.
    var detail: String {
        switch self {
        case .line: return "Drag to draw a straight line. Hold Shift to snap to 45°."
        case .curve: return "Drag the line, then click twice to bend it."
        case .polygon: return "Click each corner, then double-click to close the shape."
        case .rectangle: return "Drag to draw. Hold Shift for a perfect square."
        case .oval: return "Drag to draw. Hold Shift for a perfect circle."
        case .roundedRectangle: return "Drag to draw. Hold Shift for a square."
        default: return "Drag to draw. Hold Shift to keep it even."
        }
    }
}

enum FillStyle: String, CaseIterable, Identifiable {
    case none = "No fill"
    case solid = "Solid colour"
    var id: String { rawValue }
}

enum OutlineStyle: String, CaseIterable, Identifiable {
    case solid = "Solid colour"
    case none = "No outline"
    var id: String { rawValue }
}

// MARK: - Engine

/// Holds the canvas bitmap, tool state, undo stacks and file I/O.
final class PaintEngine: ObservableObject {
    @Published var tool: Tool = .pencil
    @Published var lastBrush: BrushKind = .brush
    @Published var lastShape: ShapeKind = .rectangle
    @Published var color1: NSColor = .black          // primary (left button)
    @Published var color2: NSColor = .white          // secondary (right button)
    @Published var activeColorSlot: Int = 1          // 1 or 2, which swatch "Edit colours" targets
    @Published var strokeSize: CGFloat = 3
    @Published var shapeFill: FillStyle = .none
    @Published var shapeOutline: OutlineStyle = .solid
    @Published var zoom: CGFloat = 1.0
    @Published var showGrid: Bool = false
    @Published var fontName: String = "Helvetica"
    @Published var fontSize: CGFloat = 24
    @Published var fontBold: Bool = false
    @Published var fontItalic: Bool = false
    @Published var fontUnderline: Bool = false
    @Published var textOpaqueBackground: Bool = false
    @Published var showRulers: Bool = false
    @Published var transparentSelection: Bool = false

    @Published var canvasSize: CGSize = CGSize(width: 1152, height: 648)
    @Published var cursorPos: CGPoint? = nil
    @Published var selectionInfo: CGSize? = nil
    @Published var documentURL: URL? = nil
    @Published var isDirty: Bool = false

    /// Incremented whenever the bitmap content changes so views repaint.
    @Published var revision: Int = 0


    // Custom colours added via the colour editor (right end of the palette).
    @Published var customColors: [NSColor] = []

    /// The zoom levels the +/- controls and the magnifier step through.
    static let zoomSteps: [CGFloat] = [0.125, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 6, 8]

    init() {
        resetLayers(size: canvasSize)
    }

    // MARK: Layers

    @Published private(set) var layers: [Layer] = []
    /// Not clamped on write — assigning inside `didSet` re-enters it and
    /// recurses until the stack blows. Every reader clamps instead.
    @Published var activeLayerIndex: Int = 0
    @Published var showLayersPanel: Bool = false

    private var compositeCache: CGImage?

    private func clampedLayerIndex(_ i: Int) -> Int {
        layers.isEmpty ? 0 : min(max(0, i), layers.count - 1)
    }

    var activeLayer: Layer { layers[clampedLayerIndex(activeLayerIndex)] }

    /// The bottom layer is the paper, so a hole punched in it is filled with
    /// Colour 2. A hole in any layer above it has to be left transparent, or it
    /// would mask whatever is underneath.
    var isActiveLayerBackground: Bool { clampedLayerIndex(activeLayerIndex) == 0 }

    /// Drawing tools all target the active layer, so every tool keeps working
    /// against `context` exactly as it did before layers existed.
    var context: CGContext! { activeLayer.context }

    /// What the user sees: every visible layer composited bottom to top. Cached,
    /// because the canvas asks for it on each redraw.
    var image: CGImage? {
        if let compositeCache { return compositeCache }
        compositeCache = renderComposite()
        return compositeCache
    }

    /// Pixels of the active layer alone.
    var activeLayerImage: CGImage? { activeLayer.image }

    private func renderComposite() -> CGImage? {
        let w = max(1, Int(canvasSize.width)), h = max(1, Int(canvasSize.height))
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        for layer in layers where layer.visible && layer.opacity > 0 {
            guard let img = layer.image else { continue }
            ctx.saveGState()
            ctx.setAlpha(layer.opacity)
            ctx.draw(img, in: full)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    private func resetLayers(size: CGSize) {
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        canvasSize = CGSize(width: w, height: h)
        if let base = Layer(name: "Background", size: canvasSize, fillWhite: true) {
            layers = [base]
        }
        activeLayerIndex = 0
        compositeCache = nil
    }

    /// Replaces the stack and selects a layer, in one change.
    func setLayers(_ newLayers: [Layer], active: Int) {
        guard !newLayers.isEmpty else { return }
        layers = newLayers
        activeLayerIndex = min(max(0, active), newLayers.count - 1)
        bumpRevision()
    }

    func captureDocumentState() -> DocumentState {
        DocumentState(
            entries: layers.map {
                DocumentState.Entry(image: $0.image, name: $0.name,
                                    visible: $0.visible, opacity: $0.opacity)
            },
            activeIndex: activeLayerIndex,
            size: canvasSize)
    }

    func restore(_ state: DocumentState) {
        canvasSize = state.size
        layers = state.entries.compactMap { entry in
            guard let layer = Layer(name: entry.name, size: state.size, fillWhite: false) else {
                return nil
            }
            layer.visible = entry.visible
            layer.opacity = entry.opacity
            if let img = entry.image {
                layer.context.draw(img, in: CGRect(origin: .zero, size: state.size))
            }
            return layer
        }
        if layers.isEmpty, let base = Layer(name: "Background", size: state.size, fillWhite: true) {
            layers = [base]
        }
        activeLayerIndex = state.activeIndex
        bumpRevision()
    }

    /// Rebuilds every layer at `newSize`, so they stay aligned with each other.
    /// Only the bottom layer gets fresh white; the rest stay transparent.
    private func mapLayers(to newSize: CGSize,
                           draw: (_ dest: CGContext, _ src: CGImage, _ index: Int) -> Void) {
        var rebuilt: [Layer] = []
        for (i, old) in layers.enumerated() {
            guard let fresh = Layer(name: old.name, size: newSize, fillWhite: i == 0) else { continue }
            fresh.copyingSettings(from: old)
            if let src = old.image { draw(fresh.context, src, i) }
            rebuilt.append(fresh)
        }
        guard !rebuilt.isEmpty else { return }
        layers = rebuilt
        canvasSize = CGSize(width: max(1, Int(newSize.width)), height: max(1, Int(newSize.height)))
    }

    func zoomIn() {
        zoom = Self.zoomSteps.first(where: { $0 > zoom }) ?? Self.zoomSteps.last!
    }

    func zoomOut() {
        zoom = Self.zoomSteps.last(where: { $0 < zoom }) ?? Self.zoomSteps.first!
    }

    var documentName: String {
        documentURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    /// Flip helper: canvas coordinates are top-left origin; CGContext is bottom-left.
    func toCG(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: canvasSize.height - p.y) }

    func bumpRevision() {
        compositeCache = nil
        revision &+= 1
        isDirty = true
    }

    // MARK: Undo / redo

    /// Most edits touch one layer's pixels, so those snapshot just that layer.
    /// Anything that changes the stack or the canvas size snapshots the lot.
    private enum UndoStep {
        case layerPixels(index: Int, image: CGImage)
        case document(DocumentState)

        var byteCost: Int {
            switch self {
            case .layerPixels(_, let image): return image.bytesPerRow * image.height
            case .document(let state): return state.byteCost
            }
        }
    }

    private var undoSteps: [UndoStep] = []
    private var redoSteps: [UndoStep] = []

    /// Undo is bounded by memory rather than step count: a 4K canvas with
    /// several layers would otherwise run to gigabytes.
    static let undoByteBudget = 512 * 1024 * 1024
    static let undoStepLimit = 60

    /// Snapshot the active layer's pixels. Call before any edit that paints.
    func snapshotForUndo() {
        guard let img = activeLayer.image else { return }
        push(.layerPixels(index: clampedLayerIndex(activeLayerIndex), image: img))
    }

    /// Snapshot the whole stack. Call before adding, removing, reordering,
    /// merging or resizing, where one layer's pixels are not the whole change.
    func snapshotDocumentForUndo() {
        push(.document(captureDocumentState()))
    }

    private func push(_ step: UndoStep) {
        undoSteps.append(step)
        redoSteps.removeAll()
        trimUndo()
    }

    private func trimUndo() {
        while undoSteps.count > Self.undoStepLimit { undoSteps.removeFirst() }
        var total = undoSteps.reduce(0) { $0 + $1.byteCost }
        while total > Self.undoByteBudget, undoSteps.count > 1 {
            total -= undoSteps.removeFirst().byteCost
        }
    }

    var canUndo: Bool { !undoSteps.isEmpty }
    var canRedo: Bool { !redoSteps.isEmpty }

    func undo() {
        guard let step = undoSteps.popLast() else { return }
        if let mirror = currentState(matching: step) { redoSteps.append(mirror) }
        apply(step)
    }

    func redo() {
        guard let step = redoSteps.popLast() else { return }
        if let mirror = currentState(matching: step) { undoSteps.append(mirror) }
        apply(step)
    }

    /// The state the opposite stack needs, shaped like the step being applied.
    private func currentState(matching step: UndoStep) -> UndoStep? {
        switch step {
        case .layerPixels(let index, _):
            let i = clampedLayerIndex(index)
            guard i < layers.count, let img = layers[i].image else { return nil }
            return .layerPixels(index: i, image: img)
        case .document:
            return .document(captureDocumentState())
        }
    }

    private func apply(_ step: UndoStep) {
        switch step {
        case .layerPixels(let index, let img):
            let i = clampedLayerIndex(index)
            guard i < layers.count else { return }
            let layer = layers[i]
            // A pixel-only step can never change the canvas size, so if the
            // sizes disagree the stack has drifted; fall back to redrawing.
            layer.context.clear(CGRect(origin: .zero, size: layer.size))
            layer.context.draw(img, in: CGRect(origin: .zero, size: layer.size))
            bumpRevision()
        case .document(let state):
            restore(state)
        }
    }

    // MARK: Image operations

    func newDocument() {
        clearHistory()
        resetLayers(size: CGSize(width: 1152, height: 648))
        documentURL = nil
        bumpRevision()
        isDirty = false
    }

    private func clearHistory() {
        undoSteps.removeAll(); redoSteps.removeAll()
    }

    func load(url: URL) -> Bool {
        guard let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        clearHistory()
        resetLayers(size: CGSize(width: cg.width, height: cg.height))
        context.draw(cg, in: CGRect(origin: .zero, size: canvasSize))
        documentURL = url
        bumpRevision()
        isDirty = false
        return true
    }

    /// Saving writes the flattened picture: none of the formats iPaint reads or
    /// writes can carry layers.
    @discardableResult
    func save(to url: URL) -> Bool {
        guard let img = image else { return false }
        let rep = NSBitmapImageRep(cgImage: img)
        let ext = url.pathExtension.lowercased()
        let type: NSBitmapImageRep.FileType
        switch ext {
        case "jpg", "jpeg": type = .jpeg
        case "bmp": type = .bmp
        case "gif": type = .gif
        case "tif", "tiff": type = .tiff
        default: type = .png
        }
        var props: [NSBitmapImageRep.PropertyKey: Any] = [:]
        if type == .jpeg { props[.compressionFactor] = 0.92 }
        guard let data = rep.representation(using: type, properties: props) else { return false }
        do {
            try data.write(to: url)
            documentURL = url
            isDirty = false
            return true
        } catch { return false }
    }

    // Geometry operations run over every layer. Transforming only the active one
    // would leave the stack misaligned, which there is no way to undo by hand.

    func resizeCanvas(to size: CGSize, stretch: Bool) {
        snapshotDocumentForUndo()
        let old = canvasSize
        mapLayers(to: size) { dest, src, _ in
            if stretch {
                dest.interpolationQuality = .high
                dest.draw(src, in: CGRect(origin: .zero, size: size))
                dest.interpolationQuality = .none
            } else {
                // keep content anchored to top-left
                dest.draw(src, in: CGRect(x: 0, y: size.height - old.height,
                                          width: old.width, height: old.height))
            }
        }
        bumpRevision()
    }

    func skew(horizontalDeg h: CGFloat, verticalDeg v: CGFloat) {
        snapshotDocumentForUndo()
        let w = canvasSize.width, ht = canvasSize.height
        let tanH = tan(h * .pi / 180), tanV = tan(v * .pi / 180)
        let newSize = CGSize(width: w + abs(tanH) * ht, height: ht + abs(tanV) * w)
        mapLayers(to: newSize) { dest, src, _ in
            dest.saveGState()
            var t = CGAffineTransform.identity
            t = t.translatedBy(x: tanH < 0 ? abs(tanH) * ht : 0,
                               y: tanV > 0 ? 0 : abs(tanV) * w)
            // CG y-axis points up; invert the vertical shear so a positive angle
            // slants downward as it does in Paint.
            t.c = -tanH
            t.b = -tanV
            dest.concatenate(t)
            dest.draw(src, in: CGRect(x: 0, y: 0, width: w, height: ht))
            dest.restoreGState()
        }
        bumpRevision()
    }

    func rotate90(clockwise: Bool) {
        snapshotDocumentForUndo()
        let old = canvasSize
        let newSize = CGSize(width: old.height, height: old.width)
        mapLayers(to: newSize) { dest, src, _ in
            dest.saveGState()
            dest.translateBy(x: newSize.width / 2, y: newSize.height / 2)
            dest.rotate(by: (clockwise ? -1 : 1) * .pi / 2)
            dest.draw(src, in: CGRect(x: -old.width / 2, y: -old.height / 2,
                                      width: old.width, height: old.height))
            dest.restoreGState()
        }
        bumpRevision()
    }

    func rotate180() {
        snapshotDocumentForUndo()
        let size = canvasSize
        mapLayers(to: size) { dest, src, _ in
            dest.saveGState()
            dest.translateBy(x: size.width / 2, y: size.height / 2)
            dest.rotate(by: .pi)
            dest.draw(src, in: CGRect(x: -size.width / 2, y: -size.height / 2,
                                      width: size.width, height: size.height))
            dest.restoreGState()
        }
        bumpRevision()
    }

    func flip(horizontal: Bool) {
        snapshotDocumentForUndo()
        let size = canvasSize
        mapLayers(to: size) { dest, src, _ in
            dest.saveGState()
            if horizontal {
                dest.translateBy(x: size.width, y: 0)
                dest.scaleBy(x: -1, y: 1)
            } else {
                dest.translateBy(x: 0, y: size.height)
                dest.scaleBy(x: 1, y: -1)
            }
            dest.draw(src, in: CGRect(origin: .zero, size: size))
            dest.restoreGState()
        }
        bumpRevision()
    }

    func crop(to rect: CGRect) {
        let size = canvasSize
        snapshotDocumentForUndo()
        mapLayers(to: rect.size) { dest, src, _ in
            // Shift the whole layer so the crop rect's top-left lands at the
            // origin. Cropping the CGImage directly would need its own y
            // convention; moving the draw keeps one convention in play.
            dest.draw(src, in: CGRect(x: -rect.minX,
                                      y: -(size.height - rect.maxY),
                                      width: size.width, height: size.height))
        }
        bumpRevision()
    }

    /// Clears the active layer. The bottom layer goes back to white paper;
    /// layers above it go back to transparent.
    func clearAll() {
        snapshotForUndo()
        let isBottom = clampedLayerIndex(activeLayerIndex) == 0
        let full = CGRect(origin: .zero, size: canvasSize)
        context.clear(full)
        if isBottom {
            context.setFillColor(CGColor.white)
            context.fill(full)
        }
        bumpRevision()
    }

    /// Inverts the active layer, the way a layer-based editor does.
    func invertColors() {
        guard let img = activeLayer.image else { return }
        snapshotForUndo()
        let ci = CIImage(cgImage: img).applyingFilter("CIColorInvert")
        if let out = CIContext().createCGImage(ci, from: ci.extent) {
            context.clear(CGRect(origin: .zero, size: canvasSize))
            context.draw(out, in: CGRect(origin: .zero, size: canvasSize))
        }
        bumpRevision()
    }

    // MARK: Flood fill (scanline)

    /// Pixels within this distance of the clicked colour are filled solidly.
    /// Deliberately tight, so a fill cannot escape through a thin outline.
    static let fillHardTolerance = 30
    /// Pixels out to here are blended rather than filled, by how much of them
    /// belongs to the region. Shapes are drawn anti-aliased, so without this the
    /// fill halts on the first blended pixel and leaves a pale fringe tracing
    /// every outline. Pixels beyond this are essentially the outline itself.
    static let fillSoftTolerance = 240

    func floodFill(at point: CGPoint, color: NSColor) {
        let w = Int(canvasSize.width), h = Int(canvasSize.height)
        // Bitmap row 0 is the top scanline, matching canvas (top-left origin) y directly.
        let x0 = Int(point.x), y0 = Int(point.y)
        guard x0 >= 0, x0 < w, y0 >= 0, y0 < h else { return }

        // The region is worked out from the composite, so clicking inside a shape
        // that lives on a lower layer fills the area you can actually see. The
        // paint itself lands on the active layer.
        let sampleRow = w * 4
        let sample = UnsafeMutablePointer<UInt8>.allocate(capacity: sampleRow * h)
        sample.initialize(repeating: 0, count: sampleRow * h)
        defer { sample.deallocate() }
        guard let sampleCtx = CGContext(
            data: sample, width: w, height: h, bitsPerComponent: 8, bytesPerRow: sampleRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        if let composite = image {
            sampleCtx.draw(composite, in: CGRect(x: 0, y: 0, width: w, height: h))
        }

        guard let data = context.data else { return }
        snapshotForUndo()

        let bpr = context.bytesPerRow
        let buf = data.bindMemory(to: UInt8.self, capacity: bpr * h)

        func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            let o = y * sampleRow + x * 4
            return (sample[o], sample[o+1], sample[o+2], sample[o+3])
        }
        let target = pixel(x0, y0)
        let c = color.usingColorSpace(.deviceRGB) ?? color
        let nr = UInt8(round(c.redComponent * 255)), ng = UInt8(round(c.greenComponent * 255)),
            nb = UInt8(round(c.blueComponent * 255))
        let newPx: (UInt8, UInt8, UInt8, UInt8) = (nr, ng, nb, 255)
        if target == newPx { return }

        /// How far a pixel is from the colour that was clicked.
        func distance(_ x: Int, _ y: Int) -> Int {
            let p = pixel(x, y)
            return max(abs(Int(p.0) - Int(target.0)),
                       max(abs(Int(p.1) - Int(target.1)),
                           max(abs(Int(p.2) - Int(target.2)),
                               abs(Int(p.3) - Int(target.3)))))
        }
        func matches(_ x: Int, _ y: Int) -> Bool {
            distance(x, y) <= Self.fillHardTolerance
        }
        func set(_ x: Int, _ y: Int) {
            let o = y * bpr + x * 4
            buf[o] = newPx.0; buf[o+1] = newPx.1; buf[o+2] = newPx.2; buf[o+3] = newPx.3
        }

        var filled = [Bool](repeating: false, count: w * h)
        var stack: [(Int, Int)] = [(x0, y0)]
        while let (sx, sy) = stack.popLast() {
            guard matches(sx, sy), !filled[sy * w + sx] else { continue }
            var l = sx, r = sx
            while l > 0 && matches(l - 1, sy) { l -= 1 }
            while r < w - 1 && matches(r + 1, sy) { r += 1 }
            for x in l...r {
                set(x, sy)
                filled[sy * w + x] = true
            }
            for ny in [sy - 1, sy + 1] where ny >= 0 && ny < h {
                var x = l
                while x <= r {
                    if matches(x, ny) && !filled[ny * w + x] {
                        stack.append((x, ny))
                        while x <= r && matches(x, ny) { x += 1 }
                    } else { x += 1 }
                }
            }
        }

        featherEdges(of: filled, buf: buf, bpr: bpr, w: w, h: h,
                     distance: distance, fill: newPx)
        bumpRevision()
    }

    /// Blends the fill colour into the anti-aliased pixels that ring the filled
    /// area, by how much of each pixel belonged to the region. Only pixels
    /// touching the fill are considered and they never themselves spread, so a
    /// fill still cannot bleed more than one pixel past an outline.
    private func featherEdges(of filled: [Bool], buf: UnsafeMutablePointer<UInt8>,
                              bpr: Int, w: Int, h: Int,
                              distance: (Int, Int) -> Int,
                              fill: (UInt8, UInt8, UInt8, UInt8)) {
        let hard = Self.fillHardTolerance, soft = Self.fillSoftTolerance
        guard soft > hard else { return }
        var edits: [(Int, Int, CGFloat)] = []

        for y in 0..<h {
            for x in 0..<w where !filled[y * w + x] {
                let touchesFill =
                    (x > 0 && filled[y * w + x - 1]) ||
                    (x < w - 1 && filled[y * w + x + 1]) ||
                    (y > 0 && filled[(y - 1) * w + x]) ||
                    (y < h - 1 && filled[(y + 1) * w + x])
                guard touchesFill else { continue }
                let d = distance(x, y)
                guard d > hard, d <= soft else { continue }

                // Only blend pixels that sit on a gradient — an anti-aliased edge
                // always has a darker neighbour on the far side. A solid block of
                // another colour does not, and must not pick up a tinted border.
                var onEdge = false
                let neighbours: [(Int, Int)] = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                for (nx, ny) in neighbours {
                    guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                    guard !filled[ny * w + nx] else { continue }
                    if distance(nx, ny) > d + 25 {
                        onEdge = true
                        break
                    }
                }
                guard onEdge else { continue }

                // A pixel this far from the region's colour is that fraction
                // covered by the outline, so give it the remaining fraction of
                // fill. This is ordinary coverage compositing, and it is what
                // makes the fill appear to meet the line exactly.
                edits.append((x, y, max(0, 1 - CGFloat(d) / 255)))
            }
        }

        // Premultiplied source-over with the fill at `weight` alpha. Compositing
        // rather than overwriting is what lets this work on a transparent layer:
        // the partial pixel lets whatever is underneath show through it.
        for (x, y, weight) in edits {
            let o = y * bpr + x * 4
            func over(_ dst: UInt8, _ src: UInt8) -> UInt8 {
                let v = CGFloat(src) * weight + CGFloat(dst) * (1 - weight)
                return UInt8(max(0, min(255, v.rounded())))
            }
            buf[o] = over(buf[o], fill.0)
            buf[o + 1] = over(buf[o + 1], fill.1)
            buf[o + 2] = over(buf[o + 2], fill.2)
            buf[o + 3] = over(buf[o + 3], 255)
        }
    }

    // MARK: Pick colour

    /// Samples the composite, so the eyedropper returns the colour on screen
    /// rather than whatever happens to be on the active layer.
    func pickColor(at point: CGPoint) -> NSColor? {
        let w = Int(canvasSize.width), h = Int(canvasSize.height)
        let x = Int(point.x), y = Int(point.y)
        guard x >= 0, x < w, y >= 0, y < h, let composite = image else { return nil }

        var px: [UInt8] = [0, 0, 0, 0]
        let ok = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // Place the wanted pixel at the context's origin. Canvas y counts from
            // the top, CG y from the bottom, hence the flip on the vertical offset.
            ctx.draw(composite, in: CGRect(x: CGFloat(-x), y: CGFloat(-(h - 1 - y)),
                                           width: CGFloat(w), height: CGFloat(h)))
            return true
        }
        guard ok else { return nil }
        let a = CGFloat(px[3]) / 255
        guard a > 0 else { return .white }   // transparent reads as the paper
        // stored premultiplied, so divide the alpha back out
        return NSColor(deviceRed: min(1, CGFloat(px[0]) / 255 / a),
                       green: min(1, CGFloat(px[1]) / 255 / a),
                       blue: min(1, CGFloat(px[2]) / 255 / a), alpha: 1)
    }
}
