# AGENTS.md

Instructions for AI agents and new contributors working on iPaint. Read this
before changing code. `README.md` is for *users*; this file is for *builders*.

## What this project is

A native macOS recreation of **Windows 11 Paint**, for people who switched from
Windows and miss the real thing. It began as a gift for a primary-school teacher
who had built a teaching workflow around Paint and lost it when she moved to a
Mac.

That origin is the product spec, so keep two things in mind:

1. **The target user is not technical.** She will never open a terminal, read a
   release note, or recover from a confusing state. Features must be
   discoverable by hovering and clicking.
2. **Fidelity to Paint beats native-Mac instinct.** The point is that her
   existing muscle memory keeps working. "More Mac-like" is not automatically
   better here.

## Build, run, test

```bash
swift build                 # compile check, fastest feedback
./scripts/run-tests.sh      # both check suites; run before every commit
./scripts/build-app.sh      # produces ./iPaint.app (ad-hoc signed)
open iPaint.app             # run it
```

Requires macOS 14+ and a Swift 5.9+ toolchain. There are no third-party
dependencies and there should remain none — a contributor should be able to
clone and build with nothing but Xcode's command line tools.

`swift run` is not useful: the app needs a bundle for its icon, menu bar and
document types. Always test through `./scripts/build-app.sh`.

## Layout

| File | Responsibility |
|---|---|
| `Sources/iPaint/PaintEngine.swift` | The bitmap and everything done to it: undo/redo, flood fill, rotate/flip/crop/resize/skew, file I/O. No UI. |
| `Sources/iPaint/CanvasView.swift` | `CanvasNSView`: the drawing surface. Tool input, brush stamping, selections, text, pinch zoom. The largest and trickiest file. |
| `Sources/iPaint/Layer.swift` | One layer's bitmap and compositing settings, plus `DocumentState` for undo. |
| `Sources/iPaint/LayerOperations.swift` | Add, duplicate, delete, reorder, merge, flatten. |
| `Sources/iPaint/LayersPanel.swift` | The layers list UI. |
| `Sources/iPaint/TextBox.swift` | The Text tool's editing box: dashed border, drag-to-move, hit testing. |
| `Sources/iPaint/Shapes.swift` | `CGPath` geometry for all 23 shapes, plus their toolbar previews. |
| `Sources/iPaint/RibbonView.swift` | The ribbon and status bar. |
| `Sources/iPaint/Tooltip.swift` | Hover cards: timing, placement, the `.paintTip()` modifier. |
| `Sources/iPaint/Palette.swift` | The 20 named default colours. |
| `Sources/iPaint/Presets.swift` | Canvas size presets. |
| `Sources/iPaint/iPaintApp.swift` | App entry, menu commands, Resize/Skew sheet. |
| `tests/main.swift` | Engine suite: pixel-level checks, no GUI. |
| `tests/ui/main.swift` | Canvas suite: drives real `NSView`/`NSScrollView`. |
| `docs/index.html` | The GitHub Pages site. Self-contained: no build step, no dependencies — keep it that way. |

Keep `PaintEngine` free of SwiftUI and AppKit *views*. If a new feature needs
pixels changed, it belongs in the engine and should be testable without a window.

## Invariants

Every item below is a bug that has already shipped and been fixed here. They are
easy to reintroduce and most of them fail *silently* or look like something else.

### 1. A `@Published` sink must never read the property it observes

`@Published` emits in `willSet`, so inside the sink the property still holds the
**old** value. Act on the value handed to the closure.

```swift
// WRONG - engine.tool is still the previous tool here
engine.$tool.sink { _ in self.toolChanged() }
// RIGHT
engine.$tool.sink { [weak self] newTool in self?.toolChanged(to: newTool) }
```

This caused three separate bugs: stale selections when switching tools, and a
canvas frame that lagged one zoom step behind (making half the picture
unreachable above 100% zoom).

### 2. Core Graphics has two conflicting vertical conventions

A `CGContext`'s **drawing origin is bottom-left**, but its **pixel buffer row 0
is the top scanline**. So:

- Drawing with `CGContext` calls? y grows **upward**. Convert with
  `canvasHeight - y`.
- Indexing `context.data` directly? Row 0 is the **top**, matching canvas y
  with no flip.

Mixing them mirrors the image vertically. This made flood fill paint the wrong
region and the eyedropper sample a mirrored row. Canvas coordinates throughout
this project are **top-left origin**.

### 3. Never hold a pointer into a temporary

```swift
// WRONG - the CFData is released at the end of the statement
let p = CFDataGetBytePtr(img.dataProvider!.data!)
// WRONG - the NSString is a temporary
String(format: "%s", (name as NSString).utf8String!)
```

Both crash or read freed memory, intermittently. Copy into an owned buffer, or
draw the image into a `CGContext` you allocated. This pattern has bitten three
times, twice in test code.

### 4. SwiftUI hit targets need an explicit shape

With `.buttonStyle(.plain)`, the clickable area is the rendered glyph. A thin
symbol like `minus` is about 2pt tall, so the button looks fine and is
effectively unclickable. Always:

```swift
Image(systemName: "minus").frame(width: 22, height: 18).contentShape(Rectangle())
```

### 5. Measurement overlays must not steal clicks

A `GeometryReader`/`Color.clear` layer used to measure a frame will swallow every
click unless you add `.allowsHitTesting(false)`. See `PaintTooltipModifier`.

### 6. A shape must be one closed subpath

Each entry in `ShapePath` should produce a **single** closed subpath. Two closed
subpaths mean the seam between them gets stroked as a visible line across the
shape's interior, and it walls regions off so Fill cannot reach them. The oval
and rounded callouts build one continuous outline that detours out to the tail
tip and rejoins. The cloud callout is the one deliberate exception: its trailing
puffs are separate, as they are in Paint.

### 7. Colour 1 and Colour 2 have fixed meanings

Colour 1 is the **left** mouse button and shape **outlines**. Colour 2 is the
**right** mouse button, shape **fills**, and what the eraser leaves behind.
Right-button drawing swaps them. Do not "simplify" this; it is core Paint
behaviour and the right-button habit is deeply ingrained in Paint users.

### 8. Fill blends anti-aliased edges by coverage

Shapes are anti-aliased, so a fill that stops at the first blended pixel leaves
a pale fringe tracing every outline. `floodFill` traverses using a tight
tolerance, then feathers edge pixels **one pixel deep**, weighted by how much of
each pixel belongs to the region. Two guards exist and must survive any change:
blending only applies to pixels on a colour gradient (so a neighbouring solid
colour never picks up a tinted border), and the feather never spreads (so a 1px
outline still holds the fill in).

### 9. Layers: draw on one, transform all

`engine.context` is the **active layer's** context, which is why every tool kept
working when layers arrived. Two rules follow:

- **Pixel edits** go to the active layer. Call `snapshotForUndo()`, which
  snapshots that one layer.
- **Geometry** (rotate, flip, crop, resize, skew) must go through `mapLayers`
  so every layer is transformed together — transforming only the active one
  misaligns the stack with no way to put it right. Call
  `snapshotDocumentForUndo()` for these, and for anything that adds, removes,
  reorders or merges.

`engine.image` is the flattened composite and is cached; `bumpRevision()`
invalidates it, so call that after touching pixels or the cache goes stale.
`activeLayerImage` is the active layer alone. Sample the composite for anything
answering "what does the user see" (the eyedropper, flood fill's region) and
write to the active layer.

A hole punched by moving or deleting a selection is filled with Colour 2 only on
the bottom layer; above it the hole must be cleared to transparent, or it masks
the layers below.

### 10. Never assign a property inside its own `didSet`

It re-enters and recurses until the stack overflows, which presents as a bare
segfault. `activeLayerIndex` is clamped by its readers for exactly this reason.

### 11. Text renders through its own bitmap

`commitTextIfAny` draws the string into a separate top-left-origin context and
then places that image, rather than drawing into the layer's bottom-up context
directly. Mixing `NSAttributedString` layout with the layer's y convention is
how invariant 2 bites; keep the two separated.

The editing box stores its position in **canvas** coordinates (`textBoxRect`)
and derives its view frame from that, so it survives zooming. Its border is the
drag handle and its interior belongs to the text view — see `hitTest`, and note
that a drag inside the text must select words, not move the box.

## Testing

Two suites, both plain executables rather than XCTest, so they run anywhere with
just a toolchain:

- **`tests/main.swift`** — the engine. Pure pixels, no window.
- **`tests/ui/main.swift`** — the canvas. Builds a real `NSWindow` and
  `NSScrollView`, synthesizes `NSEvent`s, reads pixels back.

Add a check for any behaviour you fix. Conventions that matter:

- **Assert on pixels, not on "it didn't crash."** Read the bitmap back and check
  colours at known coordinates.
- **Make fixtures asymmetric.** A symmetric test cannot detect a mirrored image;
  the original flood-fill tests passed while the y-flip bug was live because
  they used a uniform canvas and a *vertical* dividing wall. The
  `vertical orientation` group exists to catch exactly that.
- **Gesture events cannot be synthesized.** `NSEvent.magnification` throws on a
  constructed mouse event. Put the logic in a plain method
  (`applyPinch(magnification:at:)`) and test that; let the `magnify(with:)`
  override be a one-line forward.
- **Prefer relative assertions to magic numbers.** Compare a filled region's
  edge pixel to its own interior rather than to a hardcoded RGB value — colour
  space conversions move absolute values around.

## Design guidelines

- **Match Paint's naming and behaviour** by default, British spellings included
  ("Colour 1", "Fill with colour"). When a Paint behaviour and a macOS
  convention genuinely conflict, keyboard shortcuts follow macOS (⌘Z, ⌘S) and
  everything else follows Paint.
- **No silent dead ends.** Every control's state must be visible. Setting
  "Outline: off" with no fill once made every shape invisible forever with no
  indication why; the dropdowns now show their state and refuse that
  combination. Prefer making state legible over adding a warning.
- **Every control gets a `.paintTip()`** with its name and a plain-English line
  about what it does. Write for someone who has never used a Mac. No jargon.
- **Destructive actions must be undoable.** Call `engine.snapshotForUndo()`
  before mutating pixels. The undo stack is capped at 60 entries.
- **Prefer native controls** for the ribbon. Pixel-replicating Paint's Fluent
  chrome is explicitly not a goal; looking at home on macOS is.

## Known gaps

Good first contributions, roughly in order of value to users:

- **Saving layers.** Layers are session-only; a layered format (or a sidecar)
  would let work be put down and picked up again.
- **Single-key tool shortcuts** (P for pencil, B for brush, …) as Paint has.
  Must not fire while the text tool has focus.
- **Text editing after placement.** Text rasterises when you click away and
  cannot be edited again. It can be moved and restyled freely before that.
- **Selection resize handles.** Selections can be moved and nudged, not scaled.
- **Fill performance.** Single-threaded, scans the whole canvas once to feather:
  ~8ms at the default size, ~51ms at 4K.

Not planned: Paint's AI features (Cocreator, Generative erase, Remove
background).

## CI

- **`ci.yml`** builds and checks every pull request, and attaches the built
  `.app` as an artifact for reviewers.
- **`release.yml`** runs on merge to `main` as two jobs. `test` runs both
  suites; `release` declares `needs: test`, so nothing is built or published
  unless every check passed. The gate is a separate job on purpose — keeping the
  checks as an earlier *step* in the same job would rely on step ordering never
  being rearranged. `release` then builds at `1.0.<run number>`, verifies the
  bundle (executable, icon, Info.plist version, code signature), packages with
  `ditto`, verifies the zip unpacks to a still-valid bundle, and publishes a
  GitHub Release quoting the number of checks that passed.

`run-tests.sh` is the gate, so it must stay honest: it runs **both** suites even
if the first fails (one combined report beats fix-push-wait-discover), and exits
non-zero if either had a failing check or failed to compile. If you change it,
re-prove the gate by injecting a deliberately failing check and confirming a
non-zero exit — a gate that silently passes is worse than none.

`scripts/build-app.sh` reads `IPAINT_VERSION`, defaulting to `1.0.0-dev`. CI
supplies the real one. Keep the scripts as the single source of truth for how
the app is built — the workflows should only ever call them, never reimplement
the steps, or local and CI builds will drift.

## Before you open a pull request

1. `./scripts/run-tests.sh` passes.
2. `./scripts/build-app.sh` succeeds and the app launches.
3. You added a check covering what you changed.
4. You actually clicked the thing. Several bugs here were invisible to tests and
   obvious in one second of use — an unclickable button, a tooltip over a menu,
   a line across a filled shape. Screenshots in the PR are welcome and were how
   the callout bug was finally identified.
5. New comments explain *why*, not what. Match the surrounding density.
