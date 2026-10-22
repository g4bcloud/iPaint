import AppKit
import SwiftUI
import Combine

// MARK: - AppKit canvas

final class CanvasNSView: NSView, NSTextViewDelegate {
    let engine: PaintEngine
    private var cancellables: Set<AnyCancellable> = []

    // stroke-in-progress layer (composited over the bitmap, merged on mouse up)
    private var strokeLayer: CGContext?
    private var strokeAlpha: CGFloat = 1
    private var lastPoint: CGPoint?
    private var strokeActive = false
    private var usingColor2 = false

    // shape-in-progress
    private var shapeStart: CGPoint?
    private var shapeEnd: CGPoint?
    // curve tool: 0 = dragging base line, 1 = setting control1, 2 = setting control2
    private var curvePhase = 0
    private var curveControls: [CGPoint] = []
    // polygon tool
    private var polyPoints: [CGPoint] = []

    // selection
    private(set) var selectionRect: CGRect?         // committed selection (no floating image yet)
    private var selectionPath: CGPath?              // free-form lasso
    private var floatImage: CGImage?                // floating (lifted) pixels
    private var floatRect: CGRect = .zero
    private var draggingSelection = false
    private var dragOffset: CGPoint = .zero
    private var rubberBand: CGRect?
    private var lassoPoints: [CGPoint] = []
    private var antsPhase: CGFloat = 0
    private var antsTimer: Timer?

    // airbrush
    private var sprayTimer: Timer?
    private var sprayPoint: CGPoint = .zero

    // text tool
    private var textBox: TextBoxView?
    /// The box's position and size in canvas coordinates; the view frame is
    /// derived from this so the box survives zooming.
    private var textBoxRect: CGRect = .zero
    /// Set once the box has been resized by hand, which stops auto-growth.
    private var textBoxHeightIsManual = false

    private var trackingArea: NSTrackingArea?

    init(engine: PaintEngine) {
        self.engine = engine
        super.init(frame: .zero)
        wantsLayer = true
        engine.$revision.sink { [weak self] _ in self?.needsDisplay = true }.store(in: &cancellables)
        engine.$zoom.sink { [weak self] newZoom in
            self?.resizeToFit(zoom: newZoom)
            // the box lives in canvas space, so re-derive its frame and font scale
            DispatchQueue.main.async {
                guard let self, self.textBox != nil else { return }
                self.layoutTextBox()
                self.applyTextStyle()
            }
        }.store(in: &cancellables)
        engine.$canvasSize.sink { [weak self] newSize in
            self?.clearSelection(commit: false)
            self?.resizeToFit(size: newSize)
        }.store(in: &cancellables)
        engine.$showGrid.sink { [weak self] _ in self?.needsDisplay = true }.store(in: &cancellables)
        // @Published emits in willSet, so engine.tool still holds the previous
        // value here — act on the incoming tool, never on the property.
        engine.$tool.sink { [weak self] newTool in self?.toolChanged(to: newTool) }
            .store(in: &cancellables)
        // Font and colour changes must show up in the text being typed. These
        // fire in willSet, so the refresh is deferred a turn to read settled values.
        let styleChanges: [AnyPublisher<Void, Never>] = [
            engine.$fontName.map { _ in () }.eraseToAnyPublisher(),
            engine.$fontSize.map { _ in () }.eraseToAnyPublisher(),
            engine.$fontBold.map { _ in () }.eraseToAnyPublisher(),
            engine.$fontItalic.map { _ in () }.eraseToAnyPublisher(),
            engine.$fontUnderline.map { _ in () }.eraseToAnyPublisher(),
            engine.$textOpaqueBackground.map { _ in () }.eraseToAnyPublisher(),
            engine.$color1.map { _ in () }.eraseToAnyPublisher(),
            engine.$color2.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(styleChanges)
            .sink { [weak self] _ in
                guard let self, self.textBox != nil else { return }
                DispatchQueue.main.async { self.applyTextStyle() }
            }
            .store(in: &cancellables)

        resizeToFit()
        startAnts()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var zoom: CGFloat { engine.zoom }

    /// `@Published` emits in willSet, so a sink cannot read the new value off the
    /// engine yet — callers pass it in explicitly or the frame lags one change behind.
    func resizeToFit(size: CGSize? = nil, zoom z: CGFloat? = nil) {
        let s = size ?? engine.canvasSize
        let k = z ?? engine.zoom
        setFrameSize(NSSize(width: s.width * k, height: s.height * k))
        needsDisplay = true
    }

    // MARK: Pinch to zoom

    /// Trackpad pinch. Unlike the +/- buttons this is continuous rather than
    /// stepped, so it can land on any zoom between 12.5% and 800%.
    override func magnify(with event: NSEvent) {
        applyPinch(magnification: event.magnification,
                   at: convert(event.locationInWindow, from: nil))
    }

    /// Two-finger double tap: jump to 100%, or back to fitting the window.
    override func smartMagnify(with event: NSEvent) {
        if abs(engine.zoom - 1) > 0.01 {
            setZoomAnchored(1, at: convert(event.locationInWindow, from: nil))
        } else {
            setZoomAnchored(zoomToFit(), at: convert(event.locationInWindow, from: nil))
        }
    }

    /// Command-scroll also zooms, which is the habit most Windows users bring
    /// with them. Plain scrolling is left alone so it still pans the picture.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        let ticks = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 50
                                                    : event.scrollingDeltaY / 3
        applyPinch(magnification: ticks, at: convert(event.locationInWindow, from: nil))
    }

    /// `magnification` is a per-event delta (roughly 0.01–0.1 per frame).
    func applyPinch(magnification: CGFloat, at viewPoint: CGPoint) {
        setZoomAnchored(engine.zoom * (1 + magnification), at: viewPoint)
    }

    /// Zoom so that the canvas point under `viewPoint` stays under it afterwards.
    func setZoomAnchored(_ requested: CGFloat, at viewPoint: CGPoint) {
        let lo = PaintEngine.zoomSteps.first!, hi = PaintEngine.zoomSteps.last!
        let old = engine.zoom
        let new = min(hi, max(lo, requested))
        guard abs(new - old) > 0.0001 else { return }

        // The canvas pixel under the fingers, which must not move.
        let canvasPt = CGPoint(x: viewPoint.x / old, y: viewPoint.y / old)
        engine.zoom = new
        resizeToFit(zoom: new)

        // That pixel moves from canvasPt*old to canvasPt*new within the view, so
        // shifting the visible origin by the difference cancels the movement out.
        guard let clip = superview as? NSClipView else { return }
        let delta = new - old
        var origin = clip.bounds.origin
        origin.x += canvasPt.x * delta
        origin.y += canvasPt.y * delta
        origin.x = min(max(0, origin.x), max(0, frame.width - clip.bounds.width))
        origin.y = min(max(0, origin.y), max(0, frame.height - clip.bounds.height))
        clip.scroll(to: origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    /// Largest zoom at which the whole picture fits the visible area.
    func zoomToFit() -> CGFloat {
        guard let clip = superview as? NSClipView,
              clip.bounds.width > 0, clip.bounds.height > 0 else { return 1 }
        let k = min(clip.bounds.width / engine.canvasSize.width,
                    clip.bounds.height / engine.canvasSize.height)
        let lo = PaintEngine.zoomSteps.first!, hi = PaintEngine.zoomSteps.last!
        return min(hi, max(lo, k))
    }

    private func startAnts() {
        antsTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.selectionRect != nil || self.rubberBand != nil || self.floatImage != nil {
                self.antsPhase += 2
                self.needsDisplay = true
            }
        }
    }

    deinit {
        antsTimer?.invalidate()
        sprayTimer?.invalidate()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .cursorUpdate],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    // MARK: Coordinate helpers

    private func canvasPoint(_ event: NSEvent) -> CGPoint {
        let v = convert(event.locationInWindow, from: nil)
        return CGPoint(x: v.x / zoom, y: v.y / zoom)
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), engine.canvasSize.width - 1),
                y: min(max(p.y, 0), engine.canvasSize.height - 1))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let W = engine.canvasSize.width * zoom
        let H = engine.canvasSize.height * zoom

        // Chequerboard first, so anywhere the layers are transparent reads as
        // transparent rather than as the window behind it.
        let canvasRect = CGRect(x: 0, y: 0, width: W, height: H)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(canvasRect)
        let sq: CGFloat = 8
        ctx.setFillColor(NSColor(calibratedWhite: 0.86, alpha: 1).cgColor)
        var row = 0
        var y: CGFloat = 0
        while y < H {
            var col = 0
            var x: CGFloat = 0
            while x < W {
                if (row + col).isMultiple(of: 2) {
                    ctx.fill(CGRect(x: x, y: y, width: min(sq, W - x), height: min(sq, H - y)))
                }
                x += sq; col += 1
            }
            y += sq; row += 1
        }

        // bitmap (unflip locally for CGImage drawing)
        if let img = engine.image {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: H)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = zoom >= 1 ? .none : .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
            ctx.restoreGState()
        }

        // in-progress stroke layer
        if strokeActive, let layer = strokeLayer, let simg = layer.makeImage() {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: H)
            ctx.scaleBy(x: 1, y: -1)
            ctx.setAlpha(strokeAlpha)
            ctx.draw(simg, in: CGRect(x: 0, y: 0, width: W, height: H))
            ctx.restoreGState()
        }

        // floating selection image
        if let fi = floatImage {
            let r = CGRect(x: floatRect.minX * zoom, y: floatRect.minY * zoom,
                           width: floatRect.width * zoom, height: floatRect.height * zoom)
            ctx.saveGState()
            ctx.translateBy(x: r.minX, y: r.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(fi, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
            ctx.restoreGState()
            drawAnts(ctx, rect: r)
        } else if let sel = selectionRect {
            drawAnts(ctx, rect: CGRect(x: sel.minX * zoom, y: sel.minY * zoom,
                                       width: sel.width * zoom, height: sel.height * zoom))
        }

        // rubber band / lasso in progress
        if let rb = rubberBand {
            drawAnts(ctx, rect: CGRect(x: rb.minX * zoom, y: rb.minY * zoom,
                                       width: rb.width * zoom, height: rb.height * zoom))
        }
        if lassoPoints.count > 1 {
            ctx.saveGState()
            ctx.scaleBy(x: zoom, y: zoom)
            ctx.move(to: lassoPoints[0])
            for p in lassoPoints.dropFirst() { ctx.addLine(to: p) }
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1 / zoom)
            ctx.setLineDash(phase: antsPhase, lengths: [4 / zoom, 3 / zoom])
            ctx.strokePath()
            ctx.restoreGState()
        }

        // shape preview
        if let path = currentShapePreviewPath() {
            ctx.saveGState()
            ctx.scaleBy(x: zoom, y: zoom)
            applyShapeStyle(to: ctx, path: path, preview: true)
            ctx.restoreGState()
        }

        // gridlines
        if engine.showGrid && zoom >= 0.5 {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.gray.withAlphaComponent(0.35).cgColor)
            ctx.setLineWidth(1)
            let step: CGFloat = (zoom >= 4 ? 1 : (zoom >= 2 ? 8 : 16)) * zoom
            var x: CGFloat = 0
            while x <= W { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: H)); x += step }
            var y: CGFloat = 0
            while y <= H { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: W, y: y)); y += step }
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    private func drawAnts(_ ctx: CGContext, rect: CGRect) {
        ctx.saveGState()
        ctx.setLineWidth(1)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.stroke(rect)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineDash(phase: antsPhase, lengths: [4, 4])
        ctx.stroke(rect)
        ctx.restoreGState()
    }

    // MARK: Stroke layer

    private func beginStrokeLayer(alpha: CGFloat) {
        let w = Int(engine.canvasSize.width), h = Int(engine.canvasSize.height)
        strokeLayer = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        strokeAlpha = alpha
        strokeActive = true
    }

    private func commitStrokeLayer() {
        guard strokeActive, let layer = strokeLayer, let img = layer.makeImage() else { strokeActive = false; return }
        engine.snapshotForUndo()
        engine.context.saveGState()
        engine.context.setAlpha(strokeAlpha)
        engine.context.draw(img, in: CGRect(origin: .zero, size: engine.canvasSize))
        engine.context.restoreGState()
        strokeActive = false
        strokeLayer = nil
        engine.bumpRevision()
    }

    private var strokeColor: NSColor { usingColor2 ? engine.color2 : engine.color1 }

    // MARK: Brush stamping (into stroke layer, canvas coords)

    private func stamp(from a: CGPoint, to b: CGPoint) {
        guard let layer = strokeLayer else { return }
        let H = engine.canvasSize.height
        func cg(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: H - p.y) }
        let color = strokeColor.usingColorSpace(.deviceRGB) ?? strokeColor
        let size = engine.strokeSize

        switch engine.tool {
        case .pencil:
            layer.setStrokeColor(color.cgColor)
            layer.setLineWidth(max(1, size))
            layer.setLineCap(.round); layer.setLineJoin(.round)
            layer.move(to: cg(a)); layer.addLine(to: cg(b)); layer.strokePath()

        case .eraser:
            let c = (engine.color2.usingColorSpace(.deviceRGB) ?? .white).cgColor
            let s = max(4, size * 3)
            stampAlong(a, b, spacing: s / 3) { p in
                layer.setFillColor(c)
                layer.fill(CGRect(x: cg(p).x - s / 2, y: cg(p).y - s / 2, width: s, height: s))
            }

        case .brush(let kind):
            switch kind {
            case .brush, .watercolor, .marker:
                layer.setStrokeColor(color.cgColor)
                layer.setLineWidth(max(2, size * (kind == .marker ? 2.2 : 1.6)))
                layer.setLineCap(kind == .marker ? .butt : .round)
                layer.setLineJoin(.round)
                layer.move(to: cg(a)); layer.addLine(to: cg(b)); layer.strokePath()

            case .calligraphyPen, .calligraphyBrush:
                let nib = kind == .calligraphyPen ? max(3, size * 1.4) : max(5, size * 2.2)
                stampAlong(a, b, spacing: 1) { p in
                    layer.saveGState()
                    layer.translateBy(x: cg(p).x, y: cg(p).y)
                    layer.rotate(by: .pi / 4)
                    layer.setFillColor(color.cgColor)
                    layer.fill(CGRect(x: -nib / 2, y: -1, width: nib, height: 2))
                    layer.restoreGState()
                }

            case .oilBrush:
                let s = max(6, size * 2.6)
                stampAlong(a, b, spacing: 2) { p in
                    layer.setFillColor(color.withAlphaComponent(0.9).cgColor)
                    layer.fillEllipse(in: CGRect(x: cg(p).x - s / 2, y: cg(p).y - s / 2, width: s, height: s))
                }

            case .crayon, .naturalPencil:
                let radius = kind == .crayon ? max(4, size * 1.8) : max(2, size)
                let dots = kind == .crayon ? 14 : 6
                stampAlong(a, b, spacing: 2) { p in
                    for _ in 0..<dots {
                        let dx = CGFloat.random(in: -radius...radius)
                        let dy = CGFloat.random(in: -radius...radius)
                        guard dx * dx + dy * dy <= radius * radius else { continue }
                        layer.setFillColor(color.withAlphaComponent(.random(in: 0.3...0.9)).cgColor)
                        let d: CGFloat = kind == .crayon ? 1.6 : 1.0
                        layer.fillEllipse(in: CGRect(x: cg(p).x + dx, y: cg(p).y + dy, width: d, height: d))
                    }
                }

            case .airbrush:
                break   // handled by timer
            }
        default:
            break
        }
    }

    private func stampAlong(_ a: CGPoint, _ b: CGPoint, spacing: CGFloat, _ fn: (CGPoint) -> Void) {
        let d = hypot(b.x - a.x, b.y - a.y)
        let steps = max(1, Int(d / max(0.5, spacing)))
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            fn(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
    }

    private func sprayOnce() {
        guard let layer = strokeLayer else { return }
        let H = engine.canvasSize.height
        let color = strokeColor.usingColorSpace(.deviceRGB) ?? strokeColor
        let radius = max(8, engine.strokeSize * 4)
        layer.setFillColor(color.cgColor)
        for _ in 0..<18 {
            let angle = CGFloat.random(in: 0..<(2 * .pi))
            let r = radius * sqrt(CGFloat.random(in: 0...1))
            let x = sprayPoint.x + r * cos(angle)
            let y = H - (sprayPoint.y + r * sin(angle))
            layer.fillEllipse(in: CGRect(x: x, y: y, width: 1.4, height: 1.4))
        }
        needsDisplay = true
    }

    // MARK: Shape drawing

    private func currentShapePreviewPath() -> CGPath? {
        guard case .shape(let kind) = engine.tool else { return nil }
        if kind == .polygon {
            guard polyPoints.count > 1 else { return nil }
            let p = CGMutablePath()
            p.move(to: polyPoints[0])
            for pt in polyPoints.dropFirst() { p.addLine(to: pt) }
            if let e = shapeEnd { p.addLine(to: e) }
            return p
        }
        guard let s = shapeStart, let e = shapeEnd else { return nil }
        let rect = CGRect(x: min(s.x, e.x), y: min(s.y, e.y), width: abs(e.x - s.x), height: abs(e.y - s.y))
        return ShapePath.path(for: kind, in: rect, start: s, end: e, curveControls: curveControls)
    }

    private func applyShapeStyle(to ctx: CGContext, path: CGPath, preview: Bool) {
        // Outline takes colour 1, fill takes colour 2 — swapped when drawn with the right button.
        let c1 = (usingColor2 ? engine.color2 : engine.color1)
        let c2 = (usingColor2 ? engine.color1 : engine.color2)
        if engine.shapeFill != .none {
            ctx.addPath(path)
            ctx.setFillColor(c2.cgColor)
            ctx.fillPath()
        }
        if engine.shapeOutline != .none {
            ctx.addPath(path)
            ctx.setStrokeColor(c1.cgColor)
            ctx.setLineWidth(max(1, engine.strokeSize) / (preview ? 1 : 1))
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.strokePath()
        }
    }

    private func commitShape(_ path: CGPath) {
        engine.snapshotForUndo()
        let ctx = engine.context!
        let H = engine.canvasSize.height
        ctx.saveGState()
        ctx.translateBy(x: 0, y: H)
        ctx.scaleBy(x: 1, y: -1)
        applyShapeStyle(to: ctx, path: path, preview: false)
        ctx.restoreGState()
        engine.bumpRevision()
    }

    // MARK: Mouse events

    override func mouseDown(with event: NSEvent) {
        usingColor2 = false
        handleDown(event)
    }
    override func rightMouseDown(with event: NSEvent) {
        usingColor2 = true
        handleDown(event)
    }
    override func mouseDragged(with event: NSEvent) { handleDrag(event) }
    override func rightMouseDragged(with event: NSEvent) { handleDrag(event) }
    override func mouseUp(with event: NSEvent) { handleUp(event) }
    override func rightMouseUp(with event: NSEvent) { handleUp(event) }

    private func handleDown(_ event: NSEvent) {
        window?.makeFirstResponder(self)
        commitTextIfAny()
        let p = clamp(canvasPoint(event))
        lastPoint = p

        switch engine.tool {
        case .pencil, .eraser:
            beginStrokeLayer(alpha: 1)
            stamp(from: p, to: p)
            needsDisplay = true

        case .brush(let kind):
            let alpha: CGFloat
            switch kind {
            case .marker: alpha = 0.45
            case .watercolor: alpha = 0.4
            default: alpha = 1
            }
            beginStrokeLayer(alpha: alpha)
            if kind == .airbrush {
                sprayPoint = p
                sprayTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
                    self?.sprayOnce()
                }
                sprayOnce()
            } else {
                stamp(from: p, to: p)
            }
            needsDisplay = true

        case .fill:
            engine.floodFill(at: p, color: usingColor2 ? engine.color2 : engine.color1)

        case .picker:
            if let c = engine.pickColor(at: p) {
                if usingColor2 { engine.color2 = c } else { engine.color1 = c }
            }
            engine.tool = .pencil

        case .magnifier:
            if usingColor2 || event.modifierFlags.contains(.option) {
                engine.zoomOut()
            } else {
                engine.zoomIn()
            }

        case .text:
            beginTextEditing(at: p)

        case .select:
            if floatImage != nil && floatRect.contains(p) {
                draggingSelection = true
                dragOffset = CGPoint(x: p.x - floatRect.minX, y: p.y - floatRect.minY)
            } else if let sel = selectionRect, sel.contains(p) {
                liftSelection()
                draggingSelection = true
                dragOffset = CGPoint(x: p.x - floatRect.minX, y: p.y - floatRect.minY)
            } else {
                clearSelection(commit: true)
                rubberBandAnchor = p
                rubberBand = CGRect(origin: p, size: .zero)
            }
            needsDisplay = true

        case .freeSelect:
            if floatImage != nil && floatRect.contains(p) {
                draggingSelection = true
                dragOffset = CGPoint(x: p.x - floatRect.minX, y: p.y - floatRect.minY)
            } else {
                clearSelection(commit: true)
                lassoPoints = [p]
            }
            needsDisplay = true

        case .shape(let kind):
            switch kind {
            case .curve:
                if curvePhase == 0 {
                    shapeStart = p; shapeEnd = p; curveControls = []
                } else if curvePhase == 1 {
                    curveControls = [p]
                } else if curvePhase == 2 {
                    if curveControls.count == 1 { curveControls.append(p) }
                    else { curveControls[1] = p }
                }
            case .polygon:
                if polyPoints.isEmpty {
                    polyPoints = [p]
                    shapeEnd = p
                } else if event.clickCount >= 2 {
                    finishPolygon()
                } else {
                    polyPoints.append(p)
                    shapeEnd = p
                }
            default:
                shapeStart = p; shapeEnd = p
            }
            needsDisplay = true
        }
        updateStatus(p)
    }

    private func handleDrag(_ event: NSEvent) {
        let p = clamp(canvasPoint(event))
        defer { lastPoint = p; updateStatus(p); needsDisplay = true }

        switch engine.tool {
        case .pencil, .eraser:
            if let lp = lastPoint { stamp(from: lp, to: p) }

        case .brush(let kind):
            if kind == .airbrush { sprayPoint = p }
            else if let lp = lastPoint { stamp(from: lp, to: p) }

        case .select:
            if draggingSelection {
                floatRect.origin = CGPoint(x: p.x - dragOffset.x, y: p.y - dragOffset.y)
            } else if rubberBand != nil, let anchor = rubberBandAnchor {
                let rb = CGRect(x: min(anchor.x, p.x), y: min(anchor.y, p.y),
                                width: abs(p.x - anchor.x), height: abs(p.y - anchor.y))
                rubberBand = rb
                engine.selectionInfo = rb.size
            }

        case .freeSelect:
            if draggingSelection {
                floatRect.origin = CGPoint(x: p.x - dragOffset.x, y: p.y - dragOffset.y)
            } else {
                lassoPoints.append(p)
            }

        case .shape(let kind):
            switch kind {
            case .curve:
                if curvePhase == 0 {
                    shapeEnd = constrained(p, from: shapeStart, event: event, line: true)
                } else if curvePhase == 1 {
                    curveControls = [p]
                } else if curvePhase == 2, !curveControls.isEmpty {
                    if curveControls.count == 1 { curveControls.append(p) } else { curveControls[1] = p }
                }
            case .polygon:
                shapeEnd = p
            default:
                shapeEnd = constrained(p, from: shapeStart, event: event, line: kind == .line)
            }
        default:
            break
        }
    }

    private var rubberBandAnchor: CGPoint?

    private func handleUp(_ event: NSEvent) {
        let p = clamp(canvasPoint(event))

        switch engine.tool {
        case .pencil, .eraser:
            commitStrokeLayer()

        case .brush(let kind):
            if kind == .airbrush { sprayTimer?.invalidate(); sprayTimer = nil }
            commitStrokeLayer()

        case .select:
            if draggingSelection {
                draggingSelection = false
            } else if let rb = rubberBand, rb.width >= 2, rb.height >= 2 {
                selectionRect = rb.intersection(CGRect(origin: .zero, size: engine.canvasSize))
                engine.selectionInfo = selectionRect?.size
            } else {
                engine.selectionInfo = nil
            }
            rubberBand = nil

        case .freeSelect:
            if draggingSelection {
                draggingSelection = false
            } else if lassoPoints.count > 2 {
                liftLasso()
            }
            lassoPoints = []

        case .shape(let kind):
            switch kind {
            case .curve:
                if curvePhase == 0, let s = shapeStart, let e = shapeEnd, hypot(e.x - s.x, e.y - s.y) > 2 {
                    curvePhase = 1
                } else if curvePhase == 1 {
                    curvePhase = 2
                } else if curvePhase == 2 {
                    if let path = currentShapePreviewPath() { commitShape(path) }
                    resetShapeState()
                }
            case .polygon:
                break   // commits on double-click in handleDown
            default:
                if let path = currentShapePreviewPath(), let s = shapeStart, let e = shapeEnd,
                   kind == .line || kind == .curve || (abs(e.x - s.x) > 1 && abs(e.y - s.y) > 1) ||
                   hypot(e.x - s.x, e.y - s.y) > 2 {
                    commitShape(path)
                }
                resetShapeState()
            }
        default:
            break
        }
        lastPoint = nil
        _ = p
        needsDisplay = true
    }

    private func finishPolygon() {
        guard polyPoints.count > 2 else { resetShapeState(); return }
        let path = CGMutablePath()
        path.move(to: polyPoints[0])
        for pt in polyPoints.dropFirst() { path.addLine(to: pt) }
        path.closeSubpath()
        commitShape(path)
        resetShapeState()
    }

    private func resetShapeState() {
        shapeStart = nil; shapeEnd = nil
        curvePhase = 0; curveControls = []
        polyPoints = []
        needsDisplay = true
    }

    private func constrained(_ p: CGPoint, from start: CGPoint?, event: NSEvent, line: Bool) -> CGPoint {
        guard event.modifierFlags.contains(.shift), let s = start else { return p }
        if line {
            let dx = p.x - s.x, dy = p.y - s.y
            let angle = atan2(dy, dx)
            let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
            let d = hypot(dx, dy)
            return CGPoint(x: s.x + d * cos(snapped), y: s.y + d * sin(snapped))
        }
        let w = p.x - s.x, h = p.y - s.y
        let m = max(abs(w), abs(h))
        return CGPoint(x: s.x + (w < 0 ? -m : m), y: s.y + (h < 0 ? -m : m))
    }

    override func mouseMoved(with event: NSEvent) {
        updateStatus(canvasPoint(event))
    }

    override func mouseExited(with event: NSEvent) {
        engine.cursorPos = nil
    }

    private func updateStatus(_ p: CGPoint) {
        let s = engine.canvasSize
        if p.x >= 0, p.y >= 0, p.x < s.width, p.y < s.height {
            engine.cursorPos = CGPoint(x: floor(p.x), y: floor(p.y))
        } else {
            engine.cursorPos = nil
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        switch engine.tool {
        case .text: NSCursor.iBeam.set()
        case .select, .freeSelect, .picker, .magnifier: NSCursor.crosshair.set()
        default: NSCursor.crosshair.set()
        }
    }

    private func toolChanged(to newTool: Tool) {
        commitTextIfAny()
        // Any half-finished curve or polygon belongs to the tool being left behind,
        // so drop it whenever the shape itself changes.
        if case .shape(let newKind) = newTool, case .shape(let oldKind) = engine.tool,
           newKind == oldKind {
            // same shape re-selected: keep the in-progress gesture
        } else {
            resetShapeState()
        }
        switch newTool {
        case .select, .freeSelect: break
        default: clearSelection(commit: true)
        }
        needsDisplay = true
    }

    // MARK: Selection ops

    /// Empties a region of the active layer. On the background that means
    /// painting Colour 2; on a layer above it means clearing to transparent, so
    /// the layers underneath still show through the hole.
    private func punchHole(cgRect: CGRect) {
        let ctx = engine.context!
        ctx.clear(cgRect)
        guard engine.isActiveLayerBackground else { return }
        ctx.setFillColor((engine.color2.usingColorSpace(.deviceRGB) ?? .white).cgColor)
        ctx.fill(cgRect)
    }

    /// Moving a selection takes it off the layer being worked on, not off the
    /// flattened picture — otherwise dragging it would smear a copy of the
    /// layers below onto the active one.
    private func liftSelection() {
        guard let sel = selectionRect, let img = engine.activeLayerImage else { return }
        let H = engine.canvasSize.height
        let cgRect = CGRect(x: sel.minX, y: H - sel.maxY, width: sel.width, height: sel.height)
        guard let cut = img.cropping(to: cgRect) else { return }
        floatImage = transparentSelectionApplied(cut)
        floatRect = sel
        engine.snapshotForUndo()
        punchHole(cgRect: cgRect)
        engine.bumpRevision()
        selectionRect = nil
    }

    private func liftLasso() {
        let path = CGMutablePath()
        path.move(to: lassoPoints[0])
        for p in lassoPoints.dropFirst() { path.addLine(to: p) }
        path.closeSubpath()
        let box = path.boundingBox.intersection(CGRect(origin: .zero, size: engine.canvasSize)).standardized
        guard box.width >= 2, box.height >= 2, let img = engine.activeLayerImage else { return }
        let H = engine.canvasSize.height
        let cgRect = CGRect(x: box.minX, y: H - box.maxY, width: box.width, height: box.height)
        guard let cut = img.cropping(to: cgRect) else { return }

        // mask the cut to the lasso path
        let w = Int(box.width), h = Int(box.height)
        guard let mctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        mctx.saveGState()
        // path is in canvas (top-left) coords; transform into local bottom-up coords
        mctx.translateBy(x: -box.minX, y: box.maxY)
        mctx.scaleBy(x: 1, y: -1)
        mctx.addPath(path)
        mctx.clip()
        mctx.translateBy(x: box.minX, y: box.minY)
        mctx.draw(cut, in: CGRect(x: 0, y: 0, width: box.width, height: box.height))
        mctx.restoreGState()
        guard let masked = mctx.makeImage() else { return }

        floatImage = transparentSelectionApplied(masked)
        floatRect = box
        engine.snapshotForUndo()
        let ctx = engine.context!
        ctx.saveGState()
        ctx.translateBy(x: 0, y: H)
        ctx.scaleBy(x: 1, y: -1)
        ctx.addPath(path)
        if engine.isActiveLayerBackground {
            ctx.setFillColor((engine.color2.usingColorSpace(.deviceRGB) ?? .white).cgColor)
            ctx.fillPath()
        } else {
            // no "clear this path" call exists, so clip to it and clear the box
            ctx.clip()
            ctx.clear(CGRect(origin: .zero, size: engine.canvasSize))
        }
        ctx.restoreGState()
        engine.bumpRevision()
        engine.selectionInfo = box.size
    }

    /// If "Transparent selection" is on, pixels matching colour 2 become transparent.
    private func transparentSelectionApplied(_ img: CGImage) -> CGImage {
        guard engine.transparentSelection else { return img }
        let key = engine.color2.usingColorSpace(.deviceRGB) ?? .white
        let kr = UInt8(round(key.redComponent * 255)), kg = UInt8(round(key.greenComponent * 255)),
            kb = UInt8(round(key.blueComponent * 255))
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return img }
        let buf = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
        for y in 0..<h {
            for x in 0..<w {
                let o = y * ctx.bytesPerRow + x * 4
                func close(_ a: UInt8, _ b: UInt8) -> Bool { abs(Int(a) - Int(b)) <= 10 }
                if close(buf[o], kr) && close(buf[o+1], kg) && close(buf[o+2], kb) {
                    buf[o] = 0; buf[o+1] = 0; buf[o+2] = 0; buf[o+3] = 0
                }
            }
        }
        return ctx.makeImage() ?? img
    }

    func clearSelection(commit: Bool) {
        if commit, let fi = floatImage {
            engine.snapshotForUndo()
            let H = engine.canvasSize.height
            let ctx = engine.context!
            ctx.draw(fi, in: CGRect(x: floatRect.minX, y: H - floatRect.maxY,
                                    width: floatRect.width, height: floatRect.height))
            engine.bumpRevision()
        }
        floatImage = nil
        selectionRect = nil
        rubberBand = nil
        lassoPoints = []
        engine.selectionInfo = nil
        needsDisplay = true
    }

    func selectAll() {
        clearSelection(commit: true)
        engine.tool = .select
        selectionRect = CGRect(origin: .zero, size: engine.canvasSize)
        engine.selectionInfo = engine.canvasSize
        needsDisplay = true
    }

    func deleteSelection() {
        if floatImage != nil {
            floatImage = nil
            engine.selectionInfo = nil
            needsDisplay = true
        } else if let sel = selectionRect {
            engine.snapshotForUndo()
            let H = engine.canvasSize.height
            punchHole(cgRect: CGRect(x: sel.minX, y: H - sel.maxY,
                                     width: sel.width, height: sel.height))
            engine.bumpRevision()
            selectionRect = nil
            engine.selectionInfo = nil
        }
    }

    func cropToSelection() {
        if floatImage != nil { clearSelection(commit: true) }
        guard let sel = selectionRect else { return }
        selectionRect = nil
        engine.selectionInfo = nil
        engine.crop(to: sel)
    }

    func copySelection(cut: Bool) {
        var img: CGImage?
        if let fi = floatImage {
            img = fi
            if cut { floatImage = nil; engine.selectionInfo = nil }
        } else if let sel = selectionRect, let full = engine.image {
            let H = engine.canvasSize.height
            img = full.cropping(to: CGRect(x: sel.minX, y: H - sel.maxY, width: sel.width, height: sel.height))
            if cut { deleteSelection() }
        } else if let full = engine.image {
            img = full
        }
        guard let out = img else { return }
        let rep = NSBitmapImageRep(cgImage: out)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)
        let nsimg = NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
        pb.writeObjects([nsimg])
        needsDisplay = true
    }

    func paste() {
        guard let imgs = NSPasteboard.general.readObjects(forClasses: [NSImage.self]) as? [NSImage],
              let ns = imgs.first,
              let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        clearSelection(commit: true)
        engine.tool = .select
        // grow canvas if pasted image is bigger (Paint behaviour)
        let needW = max(engine.canvasSize.width, CGFloat(cg.width))
        let needH = max(engine.canvasSize.height, CGFloat(cg.height))
        if needW > engine.canvasSize.width || needH > engine.canvasSize.height {
            engine.resizeCanvas(to: CGSize(width: needW, height: needH), stretch: false)
        }
        floatImage = cg
        floatRect = CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height))
        engine.selectionInfo = floatRect.size
        needsDisplay = true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:   // esc
            if textBox != nil { cancelText() }
            else if floatImage != nil || selectionRect != nil { clearSelection(commit: true) }
            else { resetShapeState() }
        case 51, 117:   // delete / fwd delete
            deleteSelection()
        case 36 where polyPoints.count > 2:   // return closes polygon
            finishPolygon()
        case 123, 124, 125, 126:   // arrows nudge floating selection
            if floatImage != nil {
                let d: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
                switch event.keyCode {
                case 123: floatRect.origin.x -= d
                case 124: floatRect.origin.x += d
                case 125: floatRect.origin.y += d
                case 126: floatRect.origin.y -= d
                default: break
                }
                needsDisplay = true
            } else { super.keyDown(with: event) }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Text tool

    private func beginTextEditing(at p: CGPoint) {
        commitTextIfAny()
        let width = min(max(180, engine.fontSize * 10), max(40, engine.canvasSize.width - p.x))
        textBoxRect = CGRect(x: p.x, y: p.y, width: width,
                             height: engine.fontSize * 2 + TextBoxView.margin * 2)
        let box = TextBoxView(frame: .zero)
        box.textView.delegate = self
        textBoxHeightIsManual = false
        box.onMoved = { [weak self] origin in
            guard let self else { return }
            self.textBoxRect.origin = CGPoint(x: origin.x / self.zoom, y: origin.y / self.zoom)
            self.clampTextBox()
            self.layoutTextBox()
        }
        box.onResized = { [weak self] frame in
            guard let self else { return }
            self.textBoxRect = CGRect(x: frame.minX / self.zoom, y: frame.minY / self.zoom,
                                      width: frame.width / self.zoom,
                                      height: frame.height / self.zoom)
            // An explicit height wins over auto-growth, otherwise the box springs
            // back the moment another character is typed.
            self.textBoxHeightIsManual = true
            self.clampTextBox()
            self.layoutTextBox()
        }
        addSubview(box)
        textBox = box
        layoutTextBox()
        applyTextStyle()
        window?.makeFirstResponder(box.textView)
    }

    /// Keeps the box on the canvas, leaving a little of it reachable.
    private func clampTextBox() {
        let minSide = TextBoxView.minSide
        textBoxRect.size.width = max(minSide, textBoxRect.width)
        textBoxRect.size.height = max(minSide, textBoxRect.height)
        let maxX = max(0, engine.canvasSize.width - 24)
        let maxY = max(0, engine.canvasSize.height - 16)
        textBoxRect.origin.x = min(max(-TextBoxView.margin, textBoxRect.origin.x), maxX)
        textBoxRect.origin.y = min(max(-TextBoxView.margin, textBoxRect.origin.y), maxY)
    }

    /// Positions the box from its canvas-space rect, so it tracks the zoom.
    private func layoutTextBox() {
        guard let box = textBox else { return }
        box.frame = NSRect(x: textBoxRect.minX * zoom, y: textBoxRect.minY * zoom,
                           width: textBoxRect.width * zoom, height: textBoxRect.height * zoom)
        box.needsLayout = true
        box.needsDisplay = true
        window?.invalidateCursorRects(for: box)
    }

    /// Pushes the current font and colours into the live editor, so a change in
    /// the ribbon shows up in the text being typed rather than only on commit.
    private func applyTextStyle() {
        guard let box = textBox else { return }
        let tv = box.textView
        let font = currentFont(scaled: zoom)
        tv.font = font
        tv.textColor = engine.color1
        tv.drawsBackground = engine.textOpaqueBackground
        tv.backgroundColor = engine.textOpaqueBackground ? engine.color2 : .clear
        tv.insertionPointColor = engine.color1

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: engine.color1,
        ]
        if engine.fontUnderline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        tv.typingAttributes = attrs
        if let storage = tv.textStorage, storage.length > 0 {
            let all = NSRange(location: 0, length: storage.length)
            storage.setAttributes(attrs, range: all)
        }
        growTextBoxToFit()
    }

    private func growTextBoxToFit() {
        guard let box = textBox, !textBoxHeightIsManual else { return }
        let needed = box.fittingHeight() / zoom
        if needed > textBoxRect.height - 0.5 {
            textBoxRect.size.height = needed
            layoutTextBox()
        }
    }

    private func currentFont(scaled: CGFloat) -> NSFont {
        var font = NSFont(name: engine.fontName, size: engine.fontSize * scaled)
            ?? NSFont.systemFont(ofSize: engine.fontSize * scaled)
        var traits: NSFontTraitMask = []
        if engine.fontBold { traits.insert(.boldFontMask) }
        if engine.fontItalic { traits.insert(.italicFontMask) }
        if !traits.isEmpty {
            font = NSFontManager.shared.convert(font, toHaveTrait: traits)
        }
        return font
    }

    func commitTextIfAny() {
        guard let box = textBox else { return }
        let text = box.textView.string
        let rect = textBoxRect
        box.removeFromSuperview()
        textBox = nil
        guard !text.isEmpty else { return }

        var attrs: [NSAttributedString.Key: Any] = [
            .font: currentFont(scaled: 1),
            .foregroundColor: engine.color1,
        ]
        if engine.fontUnderline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if engine.textOpaqueBackground { attrs[.backgroundColor] = engine.color2 }
        let str = NSAttributedString(string: text, attributes: attrs)

        // Wrap to the same width the editor used, so what was typed is what lands.
        let inset = TextBoxView.margin
        let wrapWidth = max(8, rect.width - inset * 2)
        let drawOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let bounds = str.boundingRect(
            with: CGSize(width: wrapWidth, height: .greatestFiniteMagnitude),
            options: drawOptions)
        let w = max(1, Int(ceil(bounds.width))), h = max(1, Int(ceil(bounds.height)))

        // Render into its own top-left-origin bitmap first. Drawing text straight
        // into the bottom-up layer context means juggling two y conventions at
        // once, which is how the flood-fill mirroring bug happened.
        guard let tctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        NSGraphicsContext.saveGraphicsState()
        // `flipped:` only *declares* the coordinate system; it applies no
        // transform. Passing true over a bottom-up CGContext makes AppKit lay
        // text out y-down into a y-up context, which renders it mirrored.
        NSGraphicsContext.current = NSGraphicsContext(cgContext: tctx, flipped: false)
        str.draw(with: NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)),
                 options: drawOptions)
        NSGraphicsContext.restoreGraphicsState()
        guard let rendered = tctx.makeImage() else { return }

        engine.snapshotForUndo()
        let H = engine.canvasSize.height
        let originX = rect.minX + inset
        let originY = rect.minY + inset
        engine.context.draw(rendered, in: CGRect(x: originX, y: H - originY - CGFloat(h),
                                                 width: CGFloat(w), height: CGFloat(h)))
        engine.bumpRevision()
    }

    private func cancelText() {
        textBox?.removeFromSuperview()
        textBox = nil
    }

    func textDidChange(_ notification: Notification) {
        growTextBoxToFit()
    }

    func textDidEndEditing(_ notification: Notification) {
        // Losing focus to the ribbon must not commit: changing the font there is
        // the whole point of being able to see it update.
        guard window?.firstResponder !== textBox?.textView else { return }
    }
}

// MARK: - SwiftUI wrapper (scroll view + canvas)

/// Forwards pinch gestures to the canvas even when the pointer is over the grey
/// surround rather than the picture itself.
final class PaintScrollView: NSScrollView {
    private var canvas: CanvasNSView? { documentView as? CanvasNSView }

    override func magnify(with event: NSEvent) {
        guard let canvas else { return super.magnify(with: event) }
        canvas.applyPinch(magnification: event.magnification,
                          at: canvas.convert(event.locationInWindow, from: nil))
    }

    override func smartMagnify(with event: NSEvent) {
        guard let canvas else { return super.smartMagnify(with: event) }
        canvas.smartMagnify(with: event)
    }
}

struct CanvasHost: NSViewRepresentable {
    @ObservedObject var engine: PaintEngine
    let registrar: (CanvasNSView) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let canvas = CanvasNSView(engine: engine)
        registrar(canvas)
        let scroll = PaintScrollView()
        scroll.documentView = canvas
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.allowsMagnification = false
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(calibratedWhite: 0.82, alpha: 1)
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
