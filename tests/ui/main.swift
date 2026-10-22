import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

var fails = 0
func check(_ n: String, _ c: Bool, _ d: String = "") {
    print(c ? "  ok   \(n)" : "  FAIL \(n) \(d)"); if !c { fails += 1 }
}

/// canvas in a real scroll view, like the app
func make(canvas size: CGSize, visible: CGSize) -> (PaintEngine, CanvasNSView, NSScrollView) {
    let e = PaintEngine()
    e.resizeCanvas(to: size, stretch: false)
    let v = CanvasNSView(engine: e)
    let s = PaintScrollView()
    s.documentView = v
    s.frame = NSRect(origin: .zero, size: visible)
    let w = NSWindow(contentRect: NSRect(origin: .zero, size: visible),
                     styleMask: [.titled], backing: .buffered, defer: false)
    w.contentView = s
    s.layoutSubtreeIfNeeded()
    return (e, v, s)
}

print("\nframe tracks zoom (regression: frame lagged one step behind)")
do {
    let (e, v, _) = make(canvas: CGSize(width: 200, height: 100), visible: CGSize(width: 400, height: 300))
    e.zoom = 1; check("zoom 1 -> 200x100", v.frame.size == NSSize(width: 200, height: 100), "got \(v.frame.size)")
    e.zoom = 2; check("zoom 2 -> 400x200", v.frame.size == NSSize(width: 400, height: 200), "got \(v.frame.size)")
    e.zoom = 4; check("zoom 4 -> 800x400", v.frame.size == NSSize(width: 800, height: 400), "got \(v.frame.size)")
    e.zoom = 0.5; check("zoom 0.5 -> 100x50", v.frame.size == NSSize(width: 100, height: 50), "got \(v.frame.size)")
    e.resizeCanvas(to: CGSize(width: 50, height: 50), stretch: false)
    check("canvas resize keeps current zoom", v.frame.size == NSSize(width: 25, height: 25), "got \(v.frame.size)")
}

print("\npinch zooms continuously")
do {
    let (e, v, _) = make(canvas: CGSize(width: 400, height: 300), visible: CGSize(width: 400, height: 300))
    check("starts at 100%", e.zoom == 1)
    v.applyPinch(magnification: 0.1, at: CGPoint(x: 200, y: 150))
    check("pinch out raises zoom", e.zoom > 1.05 && e.zoom < 1.15, "got \(e.zoom)")
    check("lands off the fixed steps (continuous)", !PaintEngine.zoomSteps.contains(e.zoom))
    let afterOut = e.zoom
    v.applyPinch(magnification: -0.1, at: CGPoint(x: 200, y: 150))
    check("pinch in lowers zoom", e.zoom < afterOut, "got \(e.zoom)")
    check("view frame follows the pinch",
          abs(v.frame.width - 400 * e.zoom) < 0.01, "got \(v.frame.width) for zoom \(e.zoom)")
}

print("\npinch respects the zoom limits")
do {
    let (e, v, _) = make(canvas: CGSize(width: 400, height: 300), visible: CGSize(width: 400, height: 300))
    for _ in 0..<200 { v.applyPinch(magnification: 0.2, at: CGPoint(x: 10, y: 10)) }
    check("cannot pinch beyond 800%", e.zoom == 8, "got \(e.zoom)")
    for _ in 0..<400 { v.applyPinch(magnification: -0.2, at: CGPoint(x: 10, y: 10)) }
    check("cannot pinch below 12.5%", e.zoom == 0.125, "got \(e.zoom)")
    check("frame stays positive at the floor", v.frame.width > 0, "got \(v.frame.width)")
}

print("\npinch keeps the point under the fingers put")
do {
    // canvas larger than the window so there is room to scroll
    let (e, v, s) = make(canvas: CGSize(width: 1000, height: 800), visible: CGSize(width: 400, height: 300))
    e.zoom = 1
    s.layoutSubtreeIfNeeded()
    guard let clip = v.superview as? NSClipView else { fatalError("no clip view") }

    // put the pointer at a known spot and remember which canvas pixel is there
    let pointerInClip = CGPoint(x: 200, y: 150)
    let viewPt = CGPoint(x: clip.bounds.origin.x + pointerInClip.x,
                         y: clip.bounds.origin.y + pointerInClip.y)
    let canvasPixel = CGPoint(x: viewPt.x / e.zoom, y: viewPt.y / e.zoom)

    v.setZoomAnchored(3, at: viewPt)
    s.layoutSubtreeIfNeeded()

    // where is that same canvas pixel now, relative to the visible area?
    let nowInView = CGPoint(x: canvasPixel.x * e.zoom, y: canvasPixel.y * e.zoom)
    let nowInClip = CGPoint(x: nowInView.x - clip.bounds.origin.x,
                            y: nowInView.y - clip.bounds.origin.y)
    print("    pointer was at \(pointerInClip), that pixel is now at \(nowInClip)")
    check("anchored pixel stays within a pixel of the pointer",
          abs(nowInClip.x - pointerInClip.x) < 1.5 && abs(nowInClip.y - pointerInClip.y) < 1.5,
          "drifted to \(nowInClip)")
    check("scroll origin stays in range",
          clip.bounds.origin.x >= 0 && clip.bounds.origin.y >= 0,
          "got \(clip.bounds.origin)")
}

print("\nzoom to fit")
do {
    let (e, v, s) = make(canvas: CGSize(width: 800, height: 600), visible: CGSize(width: 400, height: 300))
    s.layoutSubtreeIfNeeded()
    let f = v.zoomToFit()
    check("fit shrinks an oversized picture", f < 1 && f > 0.3, "got \(f)")
    check("fitted picture is not wider than the window",
          800 * f <= (v.superview?.bounds.width ?? 0) + 0.5, "got \(800 * f)")
    _ = e
}

print("\npinch forwarding from the grey surround")
do {
    let (e, v, s) = make(canvas: CGSize(width: 100, height: 100), visible: CGSize(width: 400, height: 300))
    s.layoutSubtreeIfNeeded()
    check("the scroll view can reach the canvas to forward gestures",
          (s.documentView as? CanvasNSView) === v)
    // exercise the same code path the forwarder uses, at a point outside the picture
    let before = e.zoom
    v.applyPinch(magnification: 0.25, at: CGPoint(x: 350, y: 250))
    check("pinching past the edge of the picture still zooms", e.zoom > before, "got \(e.zoom)")
}


print("\ntooltip yields to open dropdowns")
func pump(_ seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.current.run(mode: .default, before: end) }
}
do {
    let tips = TooltipModel()
    let anchor = CGRect(x: 10, y: 10, width: 20, height: 20)
    tips.schedule(title: "Brushes", subtitle: "A plain round brush.", anchor: anchor)
    pump(0.8)
    check("card is up while hovering the button", tips.info != nil)

    NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
    pump(0.1)
    check("card disappears when the dropdown opens", tips.info == nil,
          "got \(String(describing: tips.info?.title))")

    // The pointer still sits on the button that opened the menu, so hover keeps
    // firing; the card must stay away regardless.
    tips.schedule(title: "Brushes", subtitle: "A plain round brush.", anchor: anchor)
    pump(0.9)
    check("card stays away while the dropdown is open", tips.info == nil,
          "got \(String(describing: tips.info?.title))")

    NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
    pump(0.1)
    check("nothing pops back the instant the menu closes", tips.info == nil)
    tips.schedule(title: "Crayon", subtitle: "A grainy, waxy line.", anchor: anchor)
    pump(0.9)
    check("hovering works again after the menu closes", tips.info?.title == "Crayon",
          "got \(String(describing: tips.info?.title))")
}

do {
    // Drive a real NSMenu, so this covers the actual notifications AppKit posts
    // rather than ones the test made up.
    let tips = TooltipModel()
    let anchor = CGRect(x: 10, y: 10, width: 20, height: 20)
    tips.schedule(title: "Size", subtitle: nil, anchor: anchor)
    pump(0.8)
    check("card up before opening a real menu", tips.info != nil)

    let menu = NSMenu(title: "Brushes")
    menu.addItem(NSMenuItem(title: "Brush", action: nil, keyEquivalent: ""))
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                       styleMask: [.titled], backing: .buffered, defer: false)
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    win.contentView = host
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { menu.cancelTracking() }
    menu.popUp(positioning: nil, at: NSPoint(x: 20, y: 20), in: host)
    pump(0.1)
    check("a real NSMenu opening clears the card", tips.info == nil,
          "got \(String(describing: tips.info?.title))")
}

print("\nclicking dismisses the card")
do {
    let tips = TooltipModel()
    let anchor = CGRect(x: 10, y: 10, width: 20, height: 20)
    tips.schedule(title: "Pencil", subtitle: nil, anchor: anchor)
    pump(0.8)
    check("card is up before the click", tips.info != nil)
    tips.dismiss()
    check("card goes away on click", tips.info == nil)
    // A click resets the timer, so the card must not spring straight back while
    // the pointer is still resting on the button that was clicked.
    tips.schedule(title: "Pencil", subtitle: nil, anchor: anchor)
    pump(0.3)
    check("after a click the next card waits the full delay again", tips.info == nil)
    pump(0.5)
    check("and then it appears", tips.info?.title == "Pencil")
}


print("\nselection moves only the active layer")
do {
    let W = 300.0, H = 240.0
    let e = PaintEngine()
    e.resizeCanvas(to: CGSize(width: W, height: H), stretch: false)
    // red on the background layer
    e.context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    e.context.fill(CGRect(origin: .zero, size: CGSize(width: W, height: H)))
    e.bumpRevision()
    // blue square on a layer above it
    e.addLayer()
    e.context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    // CG y counts from the bottom, so this lands on canvas rows 40...120,
    // which is the area the selection below grabs.
    e.context.fill(CGRect(x: 40, y: H - 120, width: 80, height: 80))
    e.bumpRevision()

    let v = CanvasNSView(engine: e)
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                       styleMask: [.titled], backing: .buffered, defer: false)
    v.frame = NSRect(x: 0, y: 0, width: W, height: H)
    win.contentView = v
    func ev(_ t: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: t, location: NSPoint(x: p.x, y: H - p.y), modifierFlags: [],
                           timestamp: 0, windowNumber: win.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        guard let img = e.image else { return (-1,-1,-1) }
        let w = img.width, h = img.height, n = w*h*4
        let bp = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
        bp.initialize(repeating: 0, count: n); defer { bp.deallocate() }
        let c = CGContext(data: bp, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let o = y*w*4 + x*4
        return (Int(bp[o]), Int(bp[o+1]), Int(bp[o+2]))
    }

    // blue square sits over red, on the upper layer
    let before = rgb(80, 80)
    check("blue square is visible over the red background", before.2 > 200 && before.0 < 60,
          "got \(before)")

    // select part of the blue square and drag it away
    e.tool = .select
    v.mouseDown(with: ev(.leftMouseDown, CGPoint(x: 50, y: 50)))
    v.mouseDragged(with: ev(.leftMouseDragged, CGPoint(x: 110, y: 110)))
    v.mouseUp(with: ev(.leftMouseUp, CGPoint(x: 110, y: 110)))
    v.mouseDown(with: ev(.leftMouseDown, CGPoint(x: 80, y: 80)))      // grab inside it
    v.mouseDragged(with: ev(.leftMouseDragged, CGPoint(x: 200, y: 80)))
    v.mouseUp(with: ev(.leftMouseUp, CGPoint(x: 200, y: 80)))

    // the hole left behind must reveal the red background, not be painted white
    let hole = rgb(70, 70)
    check("the hole left behind shows the layer underneath, not white paint",
          hole.0 > 200 && hole.2 < 60, "got \(hole) — white here means the hole was painted over")
    v.clearSelection(commit: true)
    check("both layers still exist after moving a selection", e.layers.count == 2,
          "got \(e.layers.count)")
}


print("\ntext tool")
func pumpRL(_ seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.current.run(mode: .default, before: end) }
}
func inkBox(_ e: PaintEngine) -> CGRect? {
    guard let img = e.image else { return nil }
    let w = img.width, h = img.height, n = w*h*4
    let bp = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
    bp.initialize(repeating: 0, count: n); defer { bp.deallocate() }
    let c = CGContext(data: bp, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h { for x in 0..<w {
        let o = y*w*4 + x*4
        if bp[o] < 200 || bp[o+1] < 200 || bp[o+2] < 200 {
            minX = min(minX,x); maxX = max(maxX,x); minY = min(minY,y); maxY = max(maxY,y)
        }
    }}
    guard maxX >= 0 else { return nil }
    return CGRect(x: minX, y: minY, width: maxX-minX+1, height: maxY-minY+1)
}
func textHarness() -> (PaintEngine, CanvasNSView, NSWindow, Double) {
    let TW = 400.0, TH = 300.0
    let e = PaintEngine()
    e.resizeCanvas(to: CGSize(width: TW, height: TH), stretch: false)
    e.color1 = .black
    let v = CanvasNSView(engine: e)
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: TW, height: TH),
                       styleMask: [.titled], backing: .buffered, defer: false)
    v.frame = NSRect(x: 0, y: 0, width: TW, height: TH)
    win.contentView = v
    return (e, v, win, TH)
}
func clickText(_ v: CanvasNSView, _ win: NSWindow, _ TH: Double, _ p: CGPoint) {
    func ev(_ t: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(with: t, location: NSPoint(x: p.x, y: TH - p.y), modifierFlags: [],
                           timestamp: 0, windowNumber: win.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    v.mouseDown(with: ev(.leftMouseDown)); v.mouseUp(with: ev(.leftMouseUp))
}
func box(_ v: CanvasNSView) -> TextBoxView? {
    v.subviews.compactMap { $0 as? TextBoxView }.first
}

// a box appears where you click, and typing commits there
do {
    let (e, v, win, TH) = textHarness()
    e.tool = .text
    clickText(v, win, TH, CGPoint(x: 60, y: 40))
    check("clicking with the text tool opens an editor", box(v) != nil)
    box(v)?.textView.string = "Hi"
    v.commitTextIfAny()
    check("the editor closes on commit", box(v) == nil)
    guard let r = inkBox(e) else { check("text was drawn", false); exit(1) }
    check("text lands near where it was clicked",
          r.minX > 50 && r.minX < 90 && r.minY > 30 && r.minY < 80, "ink at \(r)")
    check("text is not drawn at the canvas origin", r.minX > 20, "ink at \(r)")
}

// changing the font size while editing changes what gets drawn
do {
    var heights: [CGFloat] = []
    for size in [CGFloat(14), CGFloat(48)] {
        let (e, v, win, TH) = textHarness()
        e.tool = .text
        clickText(v, win, TH, CGPoint(x: 30, y: 30))
        box(v)?.textView.string = "Ag"
        e.fontSize = size            // changed AFTER the editor opened
        pumpRL(0.15)                 // the live refresh is deferred one turn
        let live = box(v)?.textView.font?.pointSize ?? -1
        check("editor font follows the ribbon (\(Int(size))pt)", abs(live - size) < 0.6,
              "editor shows \(live)pt")
        v.commitTextIfAny()
        heights.append(inkBox(e)?.height ?? 0)
    }
    check("a bigger font really draws bigger text",
          heights[1] > heights[0] * 1.8, "heights \(heights)")
}

// bold changes the drawn weight
do {
    func inkCount(_ bold: Bool) -> Int {
        let (e, v, win, TH) = textHarness()
        e.tool = .text
        e.fontSize = 36
        clickText(v, win, TH, CGPoint(x: 20, y: 20))
        box(v)?.textView.string = "MMM"
        e.fontBold = bold
        pumpRL(0.15)
        v.commitTextIfAny()
        guard let img = e.image else { return 0 }
        let w = img.width, h = img.height, n = w*h*4
        let bp = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
        bp.initialize(repeating: 0, count: n); defer { bp.deallocate() }
        let c = CGContext(data: bp, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var k = 0
        for i in stride(from: 0, to: n, by: 4) where bp[i] < 150 { k += 1 }
        return k
    }
    let plain = inkCount(false), heavy = inkCount(true)
    check("bold draws visibly heavier text", heavy > plain, "plain \(plain), bold \(heavy)")
}

// the box can be dragged, and the text lands where it was dragged to
do {
    let (e, v, win, TH) = textHarness()
    e.tool = .text
    clickText(v, win, TH, CGPoint(x: 40, y: 40))
    guard let b = box(v) else { check("editor opened for the drag test", false); exit(1) }
    b.textView.string = "Move me"
    let startFrame = b.frame
    // Grab plain border: along the top edge but clear of the corner and mid
    // handles, which now take precedence over moving.
    let grab = NSPoint(x: startFrame.minX + startFrame.width * 0.3,
                       y: TH - (startFrame.minY + 3))
    let drop = NSPoint(x: grab.x + 150, y: grab.y - 90)
    func mev(_ t: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: 0,
                           windowNumber: win.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    check("plain border drags rather than types",
          b.hitTest(NSPoint(x: startFrame.minX + startFrame.width * 0.3,
                            y: startFrame.minY + 3)) === b)
    check("plain border is not mistaken for a resize handle",
          b.handle(at: NSPoint(x: b.bounds.minX + b.bounds.width * 0.3,
                               y: b.bounds.minY + 3)) == nil)
    check("the middle of the box still belongs to the text view",
          b.hitTest(NSPoint(x: startFrame.midX, y: startFrame.midY)) === b.textView)
    b.mouseDown(with: mev(.leftMouseDown, grab))
    b.mouseDragged(with: mev(.leftMouseDragged, drop))
    b.mouseUp(with: mev(.leftMouseUp, drop))
    check("dragging the border moves the box", b.frame.minX > startFrame.minX + 100,
          "moved from \(startFrame.minX) to \(b.frame.minX)")
    v.commitTextIfAny()
    guard let r = inkBox(e) else { check("dragged text was drawn", false); exit(1) }
    check("the text is drawn where the box was dragged to",
          r.minX > 170 && r.minY > 110, "ink at \(r)")
}

// Esc throws the text away
do {
    let (e, v, win, TH) = textHarness()
    e.tool = .text
    clickText(v, win, TH, CGPoint(x: 40, y: 40))
    box(v)?.textView.string = "discard me"
    v.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: 0, windowNumber: win.windowNumber, context: nil,
                                     characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                     isARepeat: false, keyCode: 53)!)
    check("Esc closes the editor", box(v) == nil)
    check("Esc leaves nothing drawn", inkBox(e) == nil, "ink at \(String(describing: inkBox(e)))")
}

// an empty box commits nothing
do {
    let (e, v, win, TH) = textHarness()
    e.tool = .text
    // the harness resizes the canvas, which records its own step, so compare
    let undoBefore = e.canUndo
    clickText(v, win, TH, CGPoint(x: 40, y: 40))
    v.commitTextIfAny()
    check("an empty editor draws nothing", inkBox(e) == nil)
    check("an empty editor adds no undo step", e.canUndo == undoBefore)
}


print("\ntext box resizing")
do {
    let (e, v, win, TH) = textHarness()
    e.tool = .text
    clickText(v, win, TH, CGPoint(x: 40, y: 40))
    guard let b = box(v) else { check("editor opened for resize test", false); exit(1) }
    let start = b.frame

    check("all eight handles exist", TextBoxView.Handle.allCases.count == 8)
    // every handle must be grabbable, and must win over the move region
    var grabbable = 0
    for h in TextBoxView.Handle.allCases {
        let s = TextBoxView.handleSize / 2
        let pts: [NSPoint] = [
            NSPoint(x: b.bounds.minX + s, y: b.bounds.minY + s),
            NSPoint(x: b.bounds.midX, y: b.bounds.minY + s),
            NSPoint(x: b.bounds.maxX - s, y: b.bounds.minY + s),
            NSPoint(x: b.bounds.maxX - s, y: b.bounds.midY),
            NSPoint(x: b.bounds.maxX - s, y: b.bounds.maxY - s),
            NSPoint(x: b.bounds.midX, y: b.bounds.maxY - s),
            NSPoint(x: b.bounds.minX + s, y: b.bounds.maxY - s),
            NSPoint(x: b.bounds.minX + s, y: b.bounds.midY),
        ]
        if b.handle(at: pts[TextBoxView.Handle.allCases.firstIndex(of: h)!]) == h { grabbable += 1 }
        _ = h
    }
    check("every handle is hit-testable at its own spot", grabbable == 8, "got \(grabbable)/8")
    check("the box centre is still the text view, not a handle",
          b.handle(at: NSPoint(x: b.bounds.midX, y: b.bounds.midY)) == nil)

    func drag(_ from: NSPoint, _ to: NSPoint) {
        func mev(_ t: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: 0,
                               windowNumber: win.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        b.mouseDown(with: mev(.leftMouseDown, from))
        b.mouseDragged(with: mev(.leftMouseDragged, to))
        b.mouseUp(with: mev(.leftMouseUp, to))
    }
    // window coords: y is flipped relative to the box's own flipped space
    func win_(_ localX: CGFloat, _ localY: CGFloat) -> NSPoint {
        NSPoint(x: b.frame.minX + localX, y: TH - (b.frame.minY + localY))
    }

    // drag the bottom-right handle outward
    let s = TextBoxView.handleSize / 2
    drag(win_(b.bounds.maxX - s, b.bounds.maxY - s), win_(b.bounds.maxX + 60, b.bounds.maxY + 40))
    check("dragging the bottom-right handle grows the box",
          b.frame.width > start.width + 40 && b.frame.height > start.height + 20,
          "was \(start.size), now \(b.frame.size)")
    check("growing from the bottom-right leaves the top-left put",
          abs(b.frame.minX - start.minX) < 0.6 && abs(b.frame.minY - start.minY) < 0.6,
          "origin moved to \(b.frame.origin)")

    // drag the top-left handle inward: origin should move, size shrink
    let afterGrow = b.frame
    drag(win_(b.bounds.minX + s, b.bounds.minY + s), win_(b.bounds.minX + 30, b.bounds.minY + 20))
    check("dragging the top-left handle moves the origin and shrinks the box",
          b.frame.minX > afterGrow.minX + 20 && b.frame.width < afterGrow.width - 20,
          "was \(afterGrow), now \(b.frame)")

    // it must refuse to collapse to nothing
    let big = b.frame
    drag(win_(b.bounds.maxX - s, b.bounds.maxY - s), win_(b.bounds.minX - 400, b.bounds.minY - 400))
    check("the box will not collapse below its minimum",
          b.frame.width >= TextBoxView.minSide - 0.6 && b.frame.height >= TextBoxView.minSide - 0.6,
          "collapsed to \(b.frame.size)")
    _ = big
    v.commitTextIfAny()
}

// a narrower box must re-wrap the committed text
do {
    func commitWidth(_ widen: CGFloat) -> CGRect {
        let (e, v, win, TH) = textHarness()
        e.tool = .text
        e.fontSize = 18
        clickText(v, win, TH, CGPoint(x: 20, y: 20))
        guard let b = box(v) else { return .zero }
        b.textView.string = "the quick brown fox jumps over the lazy dog"
        // resize via the right-middle handle
        let s = TextBoxView.handleSize / 2
        func mev(_ t: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: 0,
                               windowNumber: win.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let from = NSPoint(x: b.frame.maxX - s, y: TH - b.frame.midY)
        let to = NSPoint(x: from.x + widen, y: from.y)
        b.mouseDown(with: mev(.leftMouseDown, from))
        b.mouseDragged(with: mev(.leftMouseDragged, to))
        b.mouseUp(with: mev(.leftMouseUp, to))
        v.commitTextIfAny()
        return inkBox(e) ?? .zero
    }
    let narrow = commitWidth(-80)
    let wide = commitWidth(140)
    check("a narrower box wraps the text into more lines",
          narrow.height > wide.height, "narrow \(narrow.size) vs wide \(wide.size)")
    check("a wider box lays the text out wider",
          wide.width > narrow.width, "narrow \(narrow.size) vs wide \(wide.size)")
}


print("\ntext is upright (regression: mirrored on commit)")
do {
    // A heavy first line and a nearly-empty second one. If commit mirrors the
    // text vertically, the ink mass lands in the bottom half instead of the top.
    // A single centred line cannot detect this, which is how it got through.
    let (e, v, win, TH) = textHarness()
    e.tool = .text
    e.fontSize = 24
    clickText(v, win, TH, CGPoint(x: 30, y: 30))
    box(v)?.textView.string = "HHHHHH\n."
    v.commitTextIfAny()
    guard let img = e.image else { check("upright text drew", false); exit(1) }
    let w = img.width, h = img.height, n = w*h*4
    let bp = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
    bp.initialize(repeating: 0, count: n); defer { bp.deallocate() }
    let c = CGContext(data: bp, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let r = inkBox(e) else { check("upright text drew", false); exit(1) }
    var topInk = 0, bottomInk = 0
    let midY = Int(r.midY)
    for y in Int(r.minY)...Int(r.maxY) {
        for x in Int(r.minX)...Int(r.maxX) {
            let o = y*w*4 + x*4
            guard bp[o] < 150 else { continue }
            if y < midY { topInk += 1 } else { bottomInk += 1 }
        }
    }
    check("the heavy line is at the TOP of the committed text",
          topInk > bottomInk * 2,
          "top \(topInk) vs bottom \(bottomInk) — bottom-heavy means the text is upside down")
}

print(fails == 0 ? "\nall pinch checks passed\n" : "\n\(fails) FAILED\n")
exit(fails == 0 ? 0 : 1)
