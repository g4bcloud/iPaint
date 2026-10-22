import AppKit

/// The editing box the Text tool puts on the canvas: a dashed frame you can
/// grab by its border to move, with the text view itself inset inside it.
///
/// Paint works the same way — the border is the handle, the middle is for
/// typing — which also avoids the obvious trap of making a drag inside the text
/// move the box instead of selecting words.
final class TextBoxView: NSView {
    let textView = NSTextView()
    /// Called with the box's proposed new origin, in the canvas view's coordinates.
    var onMoved: ((CGPoint) -> Void)?
    /// Width of the grab border around the text.
    static let margin: CGFloat = 9

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.allowsUndo = true
        textView.autoresizingMask = [.width, .height]
        addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        textView.frame = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        textView.textContainer?.containerSize = NSSize(
            width: textView.frame.width, height: .greatestFiniteMagnitude)
    }

    /// Called with the box's proposed new frame, in the canvas view's coordinates.
    var onResized: ((CGRect) -> Void)?

    /// The eight grab points, as in Paint.
    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
        var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
        var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    }

    static let handleSize: CGFloat = 7
    /// Smallest box worth having: the border plus a little text.
    static let minSide: CGFloat = margin * 2 + 12

    /// Handles sit just inside the border so they are always hit-testable.
    private func handleRects() -> [(Handle, CGRect)] {
        let s = Self.handleSize, half = s / 2
        let xs = [bounds.minX + half, bounds.midX, bounds.maxX - half]
        let ys = [bounds.minY + half, bounds.midY, bounds.maxY - half]
        func box(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            CGRect(x: x - half, y: y - half, width: s, height: s)
        }
        return [
            (.topLeft, box(xs[0], ys[0])), (.top, box(xs[1], ys[0])),
            (.topRight, box(xs[2], ys[0])), (.right, box(xs[2], ys[1])),
            (.bottomRight, box(xs[2], ys[2])), (.bottom, box(xs[1], ys[2])),
            (.bottomLeft, box(xs[0], ys[2])), (.left, box(xs[0], ys[1])),
        ]
    }

    /// Which handle is under a point, with a little slack for easier grabbing.
    func handle(at point: NSPoint) -> Handle? {
        handleRects().first { $0.1.insetBy(dx: -2.5, dy: -2.5).contains(point) }?.0
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 1, dy: 1)
        ctx.setLineWidth(1)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.stroke(r)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(r)

        ctx.setLineDash(phase: 0, lengths: [])
        for (_, rect) in handleRects() {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(rect)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    /// The border and its handles belong to the box (to drag and resize); the
    /// inside belongs to the text view, so clicks there place the caret.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let local = superview?.convert(point, to: self) else { return nil }
        guard bounds.contains(local) else { return nil }
        if handle(at: local) != nil { return self }
        return bounds.insetBy(dx: Self.margin, dy: Self.margin).contains(local) ? textView : self
    }

    private var dragAnchor: NSPoint?
    private var dragStartFrame: NSRect = .zero
    private var activeHandle: Handle?

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        dragAnchor = local
        dragStartFrame = frame
        activeHandle = handle(at: local)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = dragAnchor else { return }
        let here = convert(event.locationInWindow, from: nil)
        let dx = here.x - anchor.x, dy = here.y - anchor.y

        guard let grabbed = activeHandle else {
            onMoved?(CGPoint(x: frame.origin.x + dx, y: frame.origin.y + dy))
            return
        }

        var proposed = dragStartFrame
        // y grows downward here, so "top" is minY.
        if grabbed.movesLeft {
            let shift = min(dx, proposed.width - Self.minSide)
            proposed.origin.x += shift
            proposed.size.width -= shift
        }
        if grabbed.movesRight {
            proposed.size.width = max(Self.minSide, proposed.width + dx)
        }
        if grabbed.movesTop {
            let shift = min(dy, proposed.height - Self.minSide)
            proposed.origin.y += shift
            proposed.size.height -= shift
        }
        if grabbed.movesBottom {
            proposed.size.height = max(Self.minSide, proposed.height + dy)
        }
        onResized?(proposed)
    }

    override func mouseUp(with event: NSEvent) {
        dragAnchor = nil
        activeHandle = nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
        addCursorRect(bounds.insetBy(dx: Self.margin, dy: Self.margin), cursor: .iBeam)
        // AppKit exposes no diagonal resize cursor, so corners get the crosshair.
        for (handle, rect) in handleRects() {
            let cursor: NSCursor
            switch handle {
            case .left, .right: cursor = .resizeLeftRight
            case .top, .bottom: cursor = .resizeUpDown
            default: cursor = .crosshair
            }
            addCursorRect(rect.insetBy(dx: -2.5, dy: -2.5), cursor: cursor)
        }
    }

    /// Height the text needs at the current width, including the border.
    func fittingHeight() -> CGFloat {
        guard let container = textView.textContainer,
              let manager = textView.layoutManager else { return bounds.height }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).height
        return max(used, textView.font?.pointSize ?? 12) + Self.margin * 2
    }
}
