// Headless checks for the iPaint pixel engine.
// Build: swiftc -o /tmp/ipaint-tests Sources/iPaint/PaintEngine.swift Sources/iPaint/Shapes.swift tests/EngineTests.swift
import AppKit

var failures = 0
var checks = 0

func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    checks += 1
    if cond {
        print("  ok   \(name)")
    } else {
        failures += 1
        print("  FAIL \(name) \(detail)")
    }
}

/// Reads a pixel in canvas (top-left origin) coordinates.
/// Redraws into a freshly owned buffer so no pixel memory is borrowed from a temporary.
func px(_ e: PaintEngine, _ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
    guard let img = e.image else { return (-1, -1, -1, -1) }
    let w = img.width, h = img.height
    guard x >= 0, x < w, y >= 0, y < h else { return (-1, -1, -1, -1) }
    let count = w * h * 4
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
    buf.initialize(repeating: 0, count: count)
    defer { buf.deallocate() }
    guard let ctx = CGContext(data: buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return (-1, -1, -1, -1) }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let o = y * w * 4 + x * 4   // bitmap row 0 is the top scanline, same as canvas y
    return (Int(buf[o]), Int(buf[o + 1]), Int(buf[o + 2]), Int(buf[o + 3]))
}

func isWhite(_ p: (Int, Int, Int, Int)) -> Bool { p.0 > 240 && p.1 > 240 && p.2 > 240 }
func isRed(_ p: (Int, Int, Int, Int)) -> Bool { p.0 > 200 && p.1 < 60 && p.2 < 60 }

print("\n=== iPaint engine tests ===\n")

// ---------------------------------------------------------------- canvas init
print("canvas initialisation")
let e = PaintEngine()
check("default size is 1152x648", e.canvasSize == CGSize(width: 1152, height: 648),
      "got \(e.canvasSize)")
check("starts white", isWhite(px(e, 10, 10)), "got \(px(e, 10, 10))")
check("opaque alpha", px(e, 10, 10).3 == 255)
check("not dirty on open", e.isDirty == false)

// ---------------------------------------------------------------- flood fill
print("\nflood fill")
e.floodFill(at: CGPoint(x: 100, y: 100), color: .red)
check("fills at click point", isRed(px(e, 100, 100)), "got \(px(e, 100, 100))")
check("fills far corner (whole region)", isRed(px(e, 1140, 640)), "got \(px(e, 1140, 640))")
check("marks document dirty", e.isDirty == true)
check("pushes an undo step", e.canUndo == true)

// ------------------------------------------------------------- undo and redo
print("\nundo / redo")
e.undo()
check("undo restores white", isWhite(px(e, 100, 100)), "got \(px(e, 100, 100))")
check("redo becomes available", e.canRedo == true)
e.redo()
check("redo reapplies fill", isRed(px(e, 100, 100)), "got \(px(e, 100, 100))")
e.undo()
check("back to white for next tests", isWhite(px(e, 100, 100)))

// --------------------------------------------------------------- pick colour
print("\ncolour picker")
e.floodFill(at: CGPoint(x: 5, y: 5), color: .blue)
let picked = e.pickColor(at: CGPoint(x: 300, y: 300))?.usingColorSpace(.deviceRGB)
check("picks the colour under the cursor",
      (picked?.blueComponent ?? 0) > 0.9 && (picked?.redComponent ?? 1) < 0.1,
      "got \(String(describing: picked))")
e.undo()

// ------------------------------------------------------- flood fill boundary
print("\nflood fill respects boundaries")
let e2 = PaintEngine()
// draw a solid black vertical wall at x=50 across the full height
e2.context.setFillColor(CGColor.black)
e2.context.fill(CGRect(x: 50, y: 0, width: 4, height: e2.canvasSize.height))
e2.bumpRevision()
e2.floodFill(at: CGPoint(x: 10, y: 10), color: .red)
check("fills left of the wall", isRed(px(e2, 20, 20)), "got \(px(e2, 20, 20))")
check("does not leak past the wall", isWhite(px(e2, 200, 20)), "got \(px(e2, 200, 20))")
check("wall itself untouched", px(e2, 52, 20).0 < 40, "got \(px(e2, 52, 20))")

// ------------------------------------- vertical orientation (regression: y-flip)
// These use a HORIZONTAL divider and a top/bottom asymmetry, so a vertically
// mirrored buffer index cannot pass them.
print("\nvertical orientation")
let ev = PaintEngine()
ev.resizeCanvas(to: CGSize(width: 40, height: 40), stretch: false)
// paint the TOP half red directly: CG y 20..40 is the top half
ev.context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
ev.context.fill(CGRect(x: 0, y: 20, width: 40, height: 20))
ev.bumpRevision()
check("top half reads as red", isRed(px(ev, 20, 5)), "got \(px(ev, 20, 5))")
check("bottom half reads as white", isWhite(px(ev, 20, 35)), "got \(px(ev, 20, 35))")
check("eyedropper on the top half returns red",
      (ev.pickColor(at: CGPoint(x: 20, y: 5))?.usingColorSpace(.deviceRGB)?.redComponent ?? 0) > 0.9 &&
      (ev.pickColor(at: CGPoint(x: 20, y: 5))?.usingColorSpace(.deviceRGB)?.greenComponent ?? 1) < 0.3,
      "got \(String(describing: ev.pickColor(at: CGPoint(x: 20, y: 5))))")
check("eyedropper on the bottom half returns white",
      (ev.pickColor(at: CGPoint(x: 20, y: 35))?.usingColorSpace(.deviceRGB)?.greenComponent ?? 0) > 0.9,
      "got \(String(describing: ev.pickColor(at: CGPoint(x: 20, y: 35))))")

// flood fill must fill the half that was actually clicked
let ef = PaintEngine()
ef.resizeCanvas(to: CGSize(width: 40, height: 40), stretch: false)
ef.context.setFillColor(CGColor.black)
ef.context.fill(CGRect(x: 0, y: 19, width: 40, height: 2))   // horizontal wall across the middle
ef.bumpRevision()
ef.floodFill(at: CGPoint(x: 20, y: 5), color: .red)          // click the TOP half
check("flood fill paints the clicked (top) half", isRed(px(ef, 20, 5)), "got \(px(ef, 20, 5))")
check("flood fill does not paint the opposite half", isWhite(px(ef, 20, 35)), "got \(px(ef, 20, 35))")

// ------------------------------------------------------------------ rotation
print("\nrotate / flip")
let e3 = PaintEngine()
e3.resizeCanvas(to: CGSize(width: 100, height: 40), stretch: false)
// mark the top-left corner red
e3.context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
e3.context.fill(CGRect(x: 0, y: 30, width: 10, height: 10))   // CG coords = canvas top-left
e3.bumpRevision()
check("marker starts at canvas top-left", isRed(px(e3, 5, 5)), "got \(px(e3, 5, 5))")

e3.rotate90(clockwise: true)
check("90deg cw swaps dimensions", e3.canvasSize == CGSize(width: 40, height: 100),
      "got \(e3.canvasSize)")
check("90deg cw moves top-left to top-right", isRed(px(e3, 34, 5)), "got \(px(e3, 34, 5))")

e3.rotate90(clockwise: false)
check("rotating back restores dimensions", e3.canvasSize == CGSize(width: 100, height: 40),
      "got \(e3.canvasSize)")
check("rotating back restores position", isRed(px(e3, 5, 5)), "got \(px(e3, 5, 5))")

e3.flip(horizontal: true)
check("horizontal flip moves marker to the right edge", isRed(px(e3, 94, 5)), "got \(px(e3, 94, 5))")
e3.flip(horizontal: true)
e3.flip(horizontal: false)
check("vertical flip moves marker to the bottom edge", isRed(px(e3, 5, 34)), "got \(px(e3, 5, 34))")
e3.flip(horizontal: false)

e3.rotate180()
check("180deg moves top-left to bottom-right", isRed(px(e3, 94, 34)), "got \(px(e3, 94, 34))")
e3.rotate180()

// -------------------------------------------------------------------- invert
print("\ninvert colours")
let e4 = PaintEngine()
e4.resizeCanvas(to: CGSize(width: 20, height: 20), stretch: false)
e4.invertColors()
let inv = px(e4, 10, 10)
check("white inverts to black", inv.0 < 20 && inv.1 < 20 && inv.2 < 20, "got \(inv)")
e4.invertColors()
check("inverting twice returns to white", isWhite(px(e4, 10, 10)), "got \(px(e4, 10, 10))")

// ---------------------------------------------------------------------- crop
print("\ncrop")
let e5 = PaintEngine()
e5.resizeCanvas(to: CGSize(width: 100, height: 100), stretch: false)
e5.floodFill(at: CGPoint(x: 50, y: 50), color: .red)
e5.crop(to: CGRect(x: 10, y: 10, width: 30, height: 20))
check("crop sets the new canvas size", e5.canvasSize == CGSize(width: 30, height: 20),
      "got \(e5.canvasSize)")
check("cropped content preserved", isRed(px(e5, 15, 10)), "got \(px(e5, 15, 10))")

// -------------------------------------------------------------- resize modes
print("\nresize")
let e6 = PaintEngine()
e6.resizeCanvas(to: CGSize(width: 50, height: 50), stretch: false)
e6.floodFill(at: CGPoint(x: 25, y: 25), color: .red)
e6.resizeCanvas(to: CGSize(width: 100, height: 100), stretch: true)
check("stretch scales content to fill", isRed(px(e6, 90, 90)), "got \(px(e6, 90, 90))")

let e7 = PaintEngine()
e7.resizeCanvas(to: CGSize(width: 50, height: 50), stretch: false)
e7.floodFill(at: CGPoint(x: 25, y: 25), color: .red)
e7.resizeCanvas(to: CGSize(width: 100, height: 100), stretch: false)
check("no-stretch anchors content top-left", isRed(px(e7, 10, 10)), "got \(px(e7, 10, 10))")
check("no-stretch leaves new area blank", isWhite(px(e7, 90, 90)), "got \(px(e7, 90, 90))")

// ---------------------------------------------------------------------- skew
print("\nskew")
let e8 = PaintEngine()
e8.resizeCanvas(to: CGSize(width: 100, height: 100), stretch: false)
let beforeSkew = e8.canvasSize
e8.skew(horizontalDeg: 20, verticalDeg: 0)
check("horizontal skew widens the canvas", e8.canvasSize.width > beforeSkew.width,
      "got \(e8.canvasSize)")
check("horizontal skew keeps the height", e8.canvasSize.height == beforeSkew.height,
      "got \(e8.canvasSize)")

// -------------------------------------------------------------- save / load
print("\nsave / load round-trip")
let e9 = PaintEngine()
e9.resizeCanvas(to: CGSize(width: 60, height: 40), stretch: false)
e9.floodFill(at: CGPoint(x: 30, y: 20), color: .red)
let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ipaint-test-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

for ext in ["png", "jpg", "bmp", "tiff"] {
    let url = dir.appendingPathComponent("out.\(ext)")
    let saved = e9.save(to: url)
    let exists = FileManager.default.fileExists(atPath: url.path)
    let bytes = (try? Data(contentsOf: url).count) ?? 0
    check("saves .\(ext)", saved && exists && bytes > 0, "saved=\(saved) bytes=\(bytes)")
}
check("save clears the dirty flag", e9.isDirty == false)
check("save records the document URL", e9.documentURL != nil)

let e10 = PaintEngine()
let ok = e10.load(url: dir.appendingPathComponent("out.png"))
check("loads a PNG", ok)
check("loaded size matches saved size", e10.canvasSize == CGSize(width: 60, height: 40),
      "got \(e10.canvasSize)")
check("loaded pixels match", isRed(px(e10, 30, 20)), "got \(px(e10, 30, 20))")
check("freshly loaded file is not dirty", e10.isDirty == false)
try? FileManager.default.removeItem(at: dir)

// -------------------------------------------------------------- clear canvas
print("\nclear canvas")
let e11 = PaintEngine()
e11.floodFill(at: CGPoint(x: 50, y: 50), color: .red)
e11.clearAll()
check("clear fills the canvas white", isWhite(px(e11, 50, 50)), "got \(px(e11, 50, 50))")
check("clear is undoable", e11.canUndo)
e11.undo()
check("undo restores cleared content", isRed(px(e11, 50, 50)), "got \(px(e11, 50, 50))")

// ------------------------------------------------------------------- shapes
print("\nshape geometry")
let box = CGRect(x: 0, y: 0, width: 100, height: 100)
var emptyShapes: [String] = []
var outOfBounds: [String] = []
for kind in ShapeKind.allCases {
    let p = ShapePath.path(for: kind, in: box,
                           start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 100),
                           curveControls: [CGPoint(x: 20, y: 80), CGPoint(x: 80, y: 20)])
    if p.isEmpty { emptyShapes.append(kind.rawValue) }
    let bb = p.boundingBox
    // allow a small overshoot for curve control points and callout tails
    if bb.minX < -12 || bb.minY < -12 || bb.maxX > 112 || bb.maxY > 112 {
        outOfBounds.append("\(kind.rawValue)\(bb)")
    }
}
check("all \(ShapeKind.allCases.count) shapes produce a path", emptyShapes.isEmpty,
      "empty: \(emptyShapes)")
check("all shapes stay within their drag rect", outOfBounds.isEmpty, "stray: \(outOfBounds)")

var badPreviews: [String] = []
for kind in ShapeKind.allCases {
    let img = ShapePath.previewImage(for: kind)
    if img.size.width != 18 || img.tiffRepresentation == nil { badPreviews.append(kind.rawValue) }
}
check("all shapes render a toolbar preview", badPreviews.isEmpty, "bad: \(badPreviews)")

// -------------------------------------------------------------- undo depth
print("\nundo stack")
let e12 = PaintEngine()
for i in 0..<70 {
    e12.snapshotForUndo()
    e12.context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    e12.context.fill(CGRect(x: i, y: 0, width: 1, height: 1))
}
var depth = 0
while e12.canUndo { e12.undo(); depth += 1 }
check("undo history is capped (no unbounded memory)", depth <= 60 && depth >= 50, "depth=\(depth)")

// ------------------------------------------------- zoom stepping (regression)
// The minus control used to appear dead; the step maths is asserted here so a
// regression shows up as a test failure rather than a dead-feeling button.
print("\nzoom stepping")
let ez = PaintEngine()
check("starts at 100%", ez.zoom == 1)
ez.zoomOut()
check("zoom out from 100% goes to 75%", ez.zoom == 0.75, "got \(ez.zoom)")
ez.zoomIn()
check("zoom in returns to 100%", ez.zoom == 1, "got \(ez.zoom)")

ez.zoom = 1
var seenDown: [CGFloat] = []
for _ in 0..<20 { ez.zoomOut(); seenDown.append(ez.zoom) }
check("zoom out reaches the 12.5% floor and stops", ez.zoom == 0.125, "got \(ez.zoom)")
check("zoom out is strictly decreasing until the floor",
      zip(seenDown, seenDown.dropFirst()).allSatisfy { $0 >= $1 })

ez.zoom = 1
for _ in 0..<20 { ez.zoomIn() }
check("zoom in reaches the 800% ceiling and stops", ez.zoom == 8, "got \(ez.zoom)")

// stepping off a value the slider can produce must still move
ez.zoom = 1.37
ez.zoomOut()
check("zoom out from an off-step slider value still moves", ez.zoom == 1, "got \(ez.zoom)")
ez.zoom = 1.37
ez.zoomIn()
check("zoom in from an off-step slider value still moves", ez.zoom == 1.5, "got \(ez.zoom)")

check("every zoom step is reachable and ordered",
      PaintEngine.zoomSteps == PaintEngine.zoomSteps.sorted())

// ------------------------------------------ shape visibility (regression)
// "No outline" + "No fill" draws nothing at all. The ribbon now keeps one of
// the two switched on; this asserts the invisible combination is the only one
// that produces no marks, so the guard has something to protect.
print("\nshape style visibility")
check("default style draws an outline", e.shapeOutline == .solid && e.shapeFill == .none)
check("fill styles are just none/solid", FillStyle.allCases.count == 2,
      "got \(FillStyle.allCases.map(\.rawValue))")
check("outline styles are just solid/none", OutlineStyle.allCases.count == 2,
      "got \(OutlineStyle.allCases.map(\.rawValue))")

// ------------------------------------------------------------ hover tooltips
print("\ntooltip placement")
let win = CGSize(width: 1240, height: 860)
let card = CGSize(width: 200, height: 44)

let mid = TooltipOverlay.position(anchor: CGRect(x: 600, y: 20, width: 26, height: 24),
                                  card: card, container: win)
check("card is centred under a ribbon control", abs(mid.x - (613 - 100)) < 0.01, "got \(mid.x)")
check("card sits below a ribbon control", mid.y == 51, "got \(mid.y)")

let leftEdge = TooltipOverlay.position(anchor: CGRect(x: 4, y: 20, width: 26, height: 24),
                                       card: card, container: win)
check("card never runs off the left edge", leftEdge.x >= 8, "got \(leftEdge.x)")

let rightEdge = TooltipOverlay.position(anchor: CGRect(x: 1230, y: 20, width: 26, height: 24),
                                        card: card, container: win)
check("card never runs off the right edge",
      rightEdge.x + card.width <= win.width - 8 + 0.01, "got \(rightEdge.x)")

// a status-bar control near the bottom must flip above, not get clipped
let bottom = TooltipOverlay.position(anchor: CGRect(x: 1100, y: 836, width: 22, height: 18),
                                     card: card, container: win)
check("card flips above a control at the bottom edge", bottom.y < 836, "got \(bottom.y)")
check("flipped card stays inside the window", bottom.y >= 4, "got \(bottom.y)")

// a card too tall for either side must still land on screen
let huge = TooltipOverlay.position(anchor: CGRect(x: 600, y: 400, width: 20, height: 20),
                                   card: CGSize(width: 260, height: 900), container: win)
check("an oversized card is still positioned on screen", huge.y >= 4 && huge.x >= 8,
      "got \(huge)")

print("\ntooltip content")
check("every brush has a description", BrushKind.allCases.allSatisfy { !$0.detail.isEmpty })
check("every shape has a description", ShapeKind.allCases.allSatisfy { !$0.detail.isEmpty })
check("shapes needing a gesture hint mention it",
      ShapeKind.curve.detail.contains("click") && ShapeKind.polygon.detail.contains("double-click"))
check("Shift hint is present on rectangle and oval",
      ShapeKind.rectangle.detail.contains("Shift") && ShapeKind.oval.detail.contains("Shift"))

let names = Palette.rows.flatMap { $0 }
check("all 20 palette swatches are named", names.count == 20 && names.allSatisfy { !$0.name.isEmpty },
      "got \(names.count)")
check("palette names are unique", Set(names.map(\.name)).count == 20)
check("first swatch is Black, eleventh is White",
      Palette.rows[0][0].name == "Black" && Palette.rows[1][0].name == "White")

// --------------------------------------------------------- tooltip behaviour
print("\ntooltip timing")
func pump(_ seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.current.run(mode: .default, before: end) }
}
let tips = TooltipModel()
let tipAnchor = CGRect(x: 10, y: 10, width: 20, height: 20)

check("no card before anything is hovered", tips.info == nil)
tips.schedule(title: "Pencil", subtitle: "Draw a thin freehand line.", anchor: tipAnchor)
pump(0.35)
check("card still hidden a third of a second in", tips.info == nil)
pump(0.45)
check("card appears after the full delay", tips.info?.title == "Pencil",
      "got \(String(describing: tips.info?.title))")

// Moving to the next control must drop the old text at once, then show the new
// card after a brief pause — never leave the previous control's text on screen.
tips.schedule(title: "Eraser", subtitle: nil, anchor: tipAnchor)
check("stale card is removed the moment the pointer moves on", tips.info == nil)
pump(0.3)
check("replacement card appears shortly after", tips.info?.title == "Eraser",
      "got \(String(describing: tips.info?.title))")
check("replacement is quicker than a first-time hover",
      TooltipModel.reshowDelay < TooltipModel.delay)

tips.cancel()
pump(0.2)
check("card hides when the pointer leaves", tips.info == nil)

// Sweeping the pointer across the ribbon must not strobe tooltips.
tips.schedule(title: "Fill", subtitle: nil, anchor: tipAnchor)
pump(0.1)
tips.cancel()
pump(0.8)
check("a quick pass-over never flashes a card", tips.info == nil)

// Sliding across six adjacent tool icons, pausing on none of them, must leave
// nothing on screen — this is the twitchiness the delays exist to prevent.
tips.schedule(title: "Pencil", subtitle: nil, anchor: tipAnchor)
pump(0.7)
check("a card is up before the sweep starts", tips.info != nil)
for name in ["Fill", "Text", "Eraser", "Picker", "Magnifier"] {
    tips.cancel()
    tips.schedule(title: name, subtitle: nil, anchor: tipAnchor)
    pump(0.05)   // moving faster than the reshow delay
}
check("sweeping past icons shows no card mid-sweep", tips.info == nil,
      "got \(String(describing: tips.info?.title))")
pump(0.3)
check("the icon settled on does get its card", tips.info?.title == "Magnifier",
      "got \(String(describing: tips.info?.title))")

// ---------------------------------------------------------------- layers
print("\nlayers")
let el = PaintEngine()
el.resizeCanvas(to: CGSize(width: 80, height: 60), stretch: false)
check("a new document has one layer", el.layers.count == 1, "got \(el.layers.count)")
check("the one layer is the background", el.layers[0].name == "Background")
check("the background is opaque white", isWhite(px(el, 40, 30)), "got \(px(el, 40, 30))")
check("cannot delete the only layer", el.canDeleteLayer == false)
check("nothing to merge into yet", el.canMergeLayerDown == false)

// paint red on the background, then add a layer and paint blue on it
el.context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
el.context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
el.bumpRevision()
el.addLayer()
check("adding a layer selects it", el.activeLayerIndex == 1, "got \(el.activeLayerIndex)")
check("there are now two layers", el.layers.count == 2)
check("the new layer starts transparent, so red still shows",
      isRed(px(el, 40, 30)), "got \(px(el, 40, 30))")

el.context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
el.context.fill(CGRect(x: 0, y: 30, width: 80, height: 30))   // CG coords: top half
el.bumpRevision()
func isBlue(_ p: (Int, Int, Int, Int)) -> Bool { p.2 > 200 && p.0 < 60 && p.1 < 60 }
check("painting on the upper layer covers the lower one",
      isBlue(px(el, 40, 10)), "got \(px(el, 40, 10))")
check("the lower layer still shows where the upper is empty",
      isRed(px(el, 40, 50)), "got \(px(el, 40, 50))")

// drawing must not have touched the layer below
el.selectLayer(at: 0)
check("selecting the lower layer works", el.activeLayerIndex == 0)
let lowerAlone = el.activeLayerImage
check("the lower layer is untouched by what was drawn above",
      lowerAlone != nil)
el.selectLayer(at: 1)

// hiding
el.toggleLayerVisible(at: 1)
check("hiding a layer reveals what is underneath",
      isRed(px(el, 40, 10)), "got \(px(el, 40, 10))")
el.toggleLayerVisible(at: 1)
check("showing it again brings it back", isBlue(px(el, 40, 10)), "got \(px(el, 40, 10))")

// opacity
el.setLayerOpacity(0.5, at: 1)
let halfway = px(el, 40, 10)
check("50% opacity blends the two layers",
      halfway.0 > 80 && halfway.0 < 190 && halfway.2 > 80 && halfway.2 < 190,
      "got \(halfway)")
el.setLayerOpacity(1, at: 1)

// order
check("the upper layer can move down", el.canMoveLayerDown)
el.moveLayerDown()
check("moving down follows the layer", el.activeLayerIndex == 0, "got \(el.activeLayerIndex)")
check("the formerly lower layer now paints over the top",
      isRed(px(el, 40, 10)), "got \(px(el, 40, 10))")
el.moveLayerUp()
check("moving back restores the stacking", isBlue(px(el, 40, 10)), "got \(px(el, 40, 10))")

// rename, duplicate
el.renameLayer("Labels", at: 1)
check("a layer can be renamed", el.layers[1].name == "Labels", "got \(el.layers[1].name)")
el.duplicateLayer()
check("duplicating adds a layer", el.layers.count == 3)
check("the duplicate carries the pixels across", isBlue(px(el, 40, 10)))
el.deleteLayer()
check("deleting removes it again", el.layers.count == 2)

// merging
el.selectLayer(at: 1)
el.mergeLayerDown()
check("merging down leaves one layer", el.layers.count == 1, "got \(el.layers.count)")
check("the merged result keeps the upper pixels", isBlue(px(el, 40, 10)), "got \(px(el, 40, 10))")
check("the merged result keeps the lower pixels", isRed(px(el, 40, 50)), "got \(px(el, 40, 50))")

// flatten
let ef2 = PaintEngine()
ef2.resizeCanvas(to: CGSize(width: 40, height: 40), stretch: false)
ef2.addLayer()
ef2.context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
ef2.context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
ef2.bumpRevision()
ef2.flattenLayers()
check("flattening leaves exactly one layer", ef2.layers.count == 1, "got \(ef2.layers.count)")
check("flattening keeps what was visible",
      px(ef2, 20, 30).1 > 200, "got \(px(ef2, 20, 30))")

print("\nlayers and undo")
let eu = PaintEngine()
eu.resizeCanvas(to: CGSize(width: 40, height: 40), stretch: false)
eu.addLayer()
check("two layers before undo", eu.layers.count == 2)
eu.undo()
check("undo removes the added layer", eu.layers.count == 1, "got \(eu.layers.count)")
eu.redo()
check("redo puts it back", eu.layers.count == 2, "got \(eu.layers.count)")

// a pixel edit on an upper layer must undo without disturbing the stack
eu.context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
eu.snapshotForUndo()
eu.context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
eu.bumpRevision()
check("the upper layer is painted", isRed(px(eu, 20, 20)))
eu.undo()
check("undoing the paint keeps both layers", eu.layers.count == 2, "got \(eu.layers.count)")
check("undoing the paint restores transparency", isWhite(px(eu, 20, 20)), "got \(px(eu, 20, 20))")

// deleting a layer then undoing must bring its pixels back
eu.selectLayer(at: 1)
eu.context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
eu.snapshotForUndo()
eu.context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
eu.bumpRevision()
eu.deleteLayer()
check("layer deleted", eu.layers.count == 1)
eu.undo()
check("undo restores the deleted layer", eu.layers.count == 2, "got \(eu.layers.count)")
check("undo restores its pixels too", isRed(px(eu, 20, 20)), "got \(px(eu, 20, 20))")

print("\ngeometry keeps layers aligned")
let eg = PaintEngine()
eg.resizeCanvas(to: CGSize(width: 60, height: 40), stretch: false)
eg.addLayer()
// a red mark at the top-left of the upper layer
eg.context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
eg.context.fill(CGRect(x: 0, y: 30, width: 10, height: 10))
eg.bumpRevision()
check("mark is top-left", isRed(px(eg, 5, 5)), "got \(px(eg, 5, 5))")
eg.rotate90(clockwise: true)
check("rotation resizes every layer",
      eg.layers.allSatisfy { $0.size == CGSize(width: 40, height: 60) },
      "got \(eg.layers.map(\.size))")
check("the mark rotated with its layer", isRed(px(eg, 34, 5)), "got \(px(eg, 34, 5))")
eg.rotate90(clockwise: false)
check("rotating back restores it", isRed(px(eg, 5, 5)), "got \(px(eg, 5, 5))")
eg.flip(horizontal: true)
check("flip applies to the upper layer too", isRed(px(eg, 54, 5)), "got \(px(eg, 54, 5))")
eg.flip(horizontal: true)
check("both layers survived the geometry ops", eg.layers.count == 2)

// Crop's vertical convention was never actually pinned down: the old test used a
// uniformly filled canvas, which cannot detect a y offset.
print("\ncrop keeps the right part of the picture")
let ec2 = PaintEngine()
ec2.resizeCanvas(to: CGSize(width: 60, height: 60), stretch: false)
ec2.context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
ec2.context.fill(CGRect(x: 0, y: 50, width: 60, height: 10))   // CG: top 10 rows
ec2.context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
ec2.context.fill(CGRect(x: 0, y: 0, width: 60, height: 10))    // CG: bottom 10 rows
ec2.bumpRevision()
check("red band is at the top before cropping", isRed(px(ec2, 30, 5)), "got \(px(ec2, 30, 5))")
check("blue band is at the bottom", isBlue(px(ec2, 30, 55)), "got \(px(ec2, 30, 55))")
ec2.crop(to: CGRect(x: 10, y: 0, width: 40, height: 12))       // canvas coords: the top strip
check("crop takes the requested size", ec2.canvasSize == CGSize(width: 40, height: 12),
      "got \(ec2.canvasSize)")
check("crop kept the top strip, not the bottom one", isRed(px(ec2, 20, 5)),
      "got \(px(ec2, 20, 5)) — blue here would mean crop reads y upside down")

print("\nfill works across layers")
let efl = PaintEngine()
efl.resizeCanvas(to: CGSize(width: 80, height: 80), stretch: false)
// an outlined box on the background layer
efl.context.setShouldAntialias(true)
efl.context.setStrokeColor(CGColor.black)
efl.context.setLineWidth(3)
efl.context.stroke(CGRect(x: 15, y: 15, width: 50, height: 50))
efl.bumpRevision()
efl.addLayer()      // fill onto an empty layer above
efl.color1 = .red
efl.floodFill(at: CGPoint(x: 40, y: 40), color: .red)
check("filling an empty layer still respects the shape you can see",
      isRed(px(efl, 40, 40)), "got \(px(efl, 40, 40))")
check("the fill did not escape the outline", isWhite(px(efl, 3, 3)), "got \(px(efl, 3, 3))")
check("the paint landed on the upper layer, leaving the outline layer alone",
      efl.activeLayerIndex == 1)
efl.toggleLayerVisible(at: 1)
check("hiding the fill layer leaves the outline behind",
      isWhite(px(efl, 40, 40)), "got \(px(efl, 40, 40))")

// ------------------------------------------- fill against anti-aliased edges
// Shapes are drawn anti-aliased. A fill that stops at the first blended pixel
// leaves a pale fringe tracing every outline, which is what "the fill does not
// follow the line" looks like.
print("\nfill meets anti-aliased edges")
func isGreyish(_ p: (Int, Int, Int, Int)) -> Bool {
    abs(p.0 - p.1) < 14 && abs(p.1 - p.2) < 14
}
func isFillish(_ p: (Int, Int, Int, Int)) -> Bool {
    p.0 > 140 && p.1 < 110 && p.2 < 110
}
/// Pale, untinted pixels sitting right against the fill — the fringe.
func fringeCount(_ e: PaintEngine) -> Int {
    let w = Int(e.canvasSize.width), h = Int(e.canvasSize.height)
    var n = 0
    for y in 1..<(h - 1) {
        for x in 1..<(w - 1) {
            let p = px(e, x, y)
            guard isGreyish(p), p.0 > 100, p.0 < 252 else { continue }
            if isFillish(px(e, x - 1, y)) || isFillish(px(e, x + 1, y))
                || isFillish(px(e, x, y - 1)) || isFillish(px(e, x, y + 1)) {
                n += 1
            }
        }
    }
    return n
}

let eaa = PaintEngine()
eaa.resizeCanvas(to: CGSize(width: 120, height: 120), stretch: false)
eaa.context.setShouldAntialias(true)
eaa.context.setStrokeColor(CGColor.black)
eaa.context.setLineWidth(3)
eaa.context.strokeEllipse(in: CGRect(x: 15, y: 15, width: 90, height: 90))
eaa.bumpRevision()
eaa.floodFill(at: CGPoint(x: 60, y: 60), color: .red)
check("fill reaches the anti-aliased outline with no pale fringe",
      fringeCount(eaa) == 0, "fringe pixels: \(fringeCount(eaa))")
check("fill stayed inside the circle", isWhite(px(eaa, 2, 2)), "got \(px(eaa, 2, 2))")
check("centre is solidly filled", isRed(px(eaa, 60, 60)), "got \(px(eaa, 60, 60))")
// the pixel just inside the outline should be part-way between fill and line
var blendedFound = false
for x in 15..<60 {
    let p = px(eaa, x, 60)
    if p.0 > 120, p.0 < 250, p.1 < 110, p.0 - (p.1 + p.2) / 2 > 40 { blendedFound = true; break }
}
check("edge pixels are blended by coverage, not left grey", blendedFound)

// A fill must not bleed a tinted border into a neighbouring solid colour.
print("\nfill respects a neighbouring solid colour")
let esolid = PaintEngine()
esolid.resizeCanvas(to: CGSize(width: 100, height: 60), stretch: false)
esolid.context.setShouldAntialias(false)
esolid.context.setFillColor(CGColor(gray: 0.5, alpha: 1))
esolid.context.fill(CGRect(x: 50, y: 0, width: 50, height: 60))
esolid.bumpRevision()
esolid.floodFill(at: CGPoint(x: 10, y: 30), color: .red)
let border = px(esolid, 50, 30)     // first column of the solid block
let inside = px(esolid, 70, 30)     // well inside the block, definitely untouched
check("the white side is filled", isRed(px(esolid, 10, 30)), "got \(px(esolid, 10, 30))")
check("the block's edge is identical to its interior, so it picked up no tint",
      border == inside, "edge \(border) vs interior \(inside)")
check("the block is still grey, not red-tinted", isGreyish(border), "got \(border)")

// A thin anti-aliased outline must still hold the fill in.
print("\nfill does not escape a thin outline")
let ethin = PaintEngine()
ethin.resizeCanvas(to: CGSize(width: 120, height: 120), stretch: false)
ethin.context.setShouldAntialias(true)
ethin.context.setStrokeColor(CGColor.black)
ethin.context.setLineWidth(1)
ethin.context.strokeEllipse(in: CGRect(x: 15, y: 15, width: 90, height: 90))
ethin.bumpRevision()
ethin.floodFill(at: CGPoint(x: 60, y: 60), color: .red)
check("a 1px outline still contains the fill", isWhite(px(ethin, 2, 2)),
      "got \(px(ethin, 2, 2))")
check("inside the 1px outline is filled", isRed(px(ethin, 60, 60)))

// ------------------------------------------------------- canvas size presets
print("\ncanvas presets")
check("default preset matches the starting canvas",
      CanvasPresets.standard.width == 1152 && CanvasPresets.standard.height == 648)
check("HD is 1920 × 1080",
      CanvasPresets.screen.contains { $0.width == 1920 && $0.height == 1080 })
check("2K is 2560 × 1440",
      CanvasPresets.screen.contains { $0.width == 2560 && $0.height == 1440 })
check("4K is 3840 × 2160",
      CanvasPresets.screen.contains { $0.width == 3840 && $0.height == 2160 })
check("A4 portrait at 150 dpi is 1240 × 1754",
      CanvasPresets.paper.contains { $0.name == "A4 portrait" && $0.width == 1240 && $0.height == 1754 })
check("Letter portrait at 150 dpi is 1275 × 1650",
      CanvasPresets.paper.contains { $0.name == "Letter portrait" && $0.width == 1275 && $0.height == 1650 })
check("every preset has a positive size",
      CanvasPresets.all.allSatisfy { $0.width > 0 && $0.height > 0 })
check("preset names are unique",
      Set(CanvasPresets.all.map(\.name)).count == CanvasPresets.all.count)
check("portrait and landscape pairs are transposes",
      CanvasPresets.paper.contains { $0.name == "A4 landscape" && $0.width == 1754 && $0.height == 1240 })
check("a known size is recognised as its preset",
      CanvasPresets.matching(CGSize(width: 3840, height: 2160))?.name == "4K — UHD")
check("an arbitrary size matches no preset",
      CanvasPresets.matching(CGSize(width: 1234, height: 567)) == nil)
check("dimensions read back for the menu label",
      CanvasPresets.standard.dimensions == "1152 × 648",
      "got \(CanvasPresets.standard.dimensions)")

print("\napplying a preset")
let ep = PaintEngine()
// a red block in the top-left corner, to tell anchoring from stretching
ep.resizeCanvas(to: CGSize(width: 400, height: 300), stretch: false)
ep.context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
ep.context.fill(CGRect(x: 0, y: 280, width: 20, height: 20))
ep.bumpRevision()
check("marker is at the top-left before resizing", isRed(px(ep, 10, 10)), "got \(px(ep, 10, 10))")

let hd = CanvasPresets.screen.first { $0.width == 1920 }!
ep.resizeCanvas(to: hd.size, stretch: false)
check("canvas takes the preset size exactly", ep.canvasSize == CGSize(width: 1920, height: 1080),
      "got \(ep.canvasSize)")
check("picture is kept at its original scale, not stretched",
      isRed(px(ep, 10, 10)) && isWhite(px(ep, 100, 100)),
      "corner \(px(ep, 10, 10)), beyond \(px(ep, 100, 100))")
check("new area is blank", isWhite(px(ep, 1900, 1070)), "got \(px(ep, 1900, 1070))")
check("resizing to a preset is undoable", ep.canUndo)
ep.undo()
check("undo restores the previous canvas size", ep.canvasSize == CGSize(width: 400, height: 300),
      "got \(ep.canvasSize)")
check("undo restores the picture", isRed(px(ep, 10, 10)), "got \(px(ep, 10, 10))")

// shrinking must not fail or lose the anchor
ep.resizeCanvas(to: CGSize(width: 100, height: 100), stretch: false)
check("shrinking to a smaller canvas keeps the top-left corner",
      ep.canvasSize == CGSize(width: 100, height: 100) && isRed(px(ep, 10, 10)),
      "size \(ep.canvasSize), corner \(px(ep, 10, 10))")

// the largest preset must allocate cleanly
let ep4k = PaintEngine()
let uhd = CanvasPresets.screen.first { $0.width == 3840 }!
ep4k.resizeCanvas(to: uhd.size, stretch: false)
check("4K canvas allocates and is blank white",
      ep4k.canvasSize == CGSize(width: 3840, height: 2160) && isWhite(px(ep4k, 3800, 2100)),
      "size \(ep4k.canvasSize)")

// ---------------------------------------------------------- tool enumeration
print("\ntool coverage")
check("9 brushes available", BrushKind.allCases.count == 9, "got \(BrushKind.allCases.count)")
check("23 shapes available", ShapeKind.allCases.count == 23, "got \(ShapeKind.allCases.count)")
check("every brush has an icon", BrushKind.allCases.allSatisfy { !$0.symbol.isEmpty })

// ---------------------------------------------------------- update checker
print("\nupdate version compare")
check("newer patch is greater", AppVersion("1.0.4") > AppVersion("1.0.3"))
check("double-digit patch beats single", AppVersion("1.0.10") > AppVersion("1.0.9"),
      "numeric, not lexicographic")
check("minor bump beats patch", AppVersion("1.1.0") > AppVersion("1.0.99"))
check("equal versions are not greater",
      !(AppVersion("1.0.3") > AppVersion("1.0.3")) && AppVersion("1.0.3") == AppVersion("1.0.3"))
check("leading v is ignored", AppVersion("v1.0.3") == AppVersion("1.0.3"))
check("dev build is older than the same release number",
      AppVersion("1.0.0-dev") < AppVersion("1.0.0"),
      "a local dev build must never claim to be up to date against a real 1.0.0")
check("dev build is still older than a higher release",
      AppVersion("1.0.0-dev") < AppVersion("1.0.3"))
check("missing components default to zero", AppVersion("1.0") == AppVersion("1.0.0"))

print("\nrelease JSON parse")
let sampleJSON: [String: Any] = [
    "tag_name": "v1.0.4",
    "html_url": "https://github.com/g4bcloud/iPaint/releases/tag/v1.0.4",
    "assets": [
        ["name": "checksum.txt", "browser_download_url": "https://example/checksum.txt"],
        ["name": "iPaint-1.0.4.zip",
         "browser_download_url": "https://github.com/g4bcloud/iPaint/releases/download/v1.0.4/iPaint-1.0.4.zip",
         "digest": "sha256:ABCDEF0123"]
    ]
]
if let rel = LatestRelease(json: sampleJSON) {
    check("parses the tag", rel.tag == "v1.0.4")
    check("picks the .zip asset, not checksum.txt", rel.assetName == "iPaint-1.0.4.zip")
    check("captures the download URL", rel.assetDownloadURL.hasSuffix("iPaint-1.0.4.zip"))
    check("normalises the digest to lowercase hex without prefix",
          rel.assetSHA256 == "abcdef0123", "got \(rel.assetSHA256 ?? "nil")")
    check("version is derived from the tag", rel.version == AppVersion("1.0.4"))
} else {
    check("release JSON parses", false, "LatestRelease returned nil")
}
check("malformed JSON (no assets) yields nil",
      LatestRelease(json: ["tag_name": "v1.0.4", "html_url": "x"]) == nil)

print("\n=== \(checks - failures)/\(checks) checks passed ===\n")
exit(failures == 0 ? 0 : 1)
