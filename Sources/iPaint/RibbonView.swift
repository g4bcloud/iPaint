import SwiftUI
import AppKit

// MARK: - Ribbon

struct RibbonView: View {
    @ObservedObject var engine: PaintEngine
    var canvasAccess: () -> CanvasNSView?
    var onResizeDialog: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                clipboardGroup
                divider
                imageGroup
                divider
                toolsGroup
                divider
                brushesGroup
                divider
                shapesGroup
                divider
                sizeGroup
                divider
                colorsGroup
                divider
                layersGroup
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(height: 86)
            .background(RibbonBackground())

            if engine.tool == .text {
                textOptionsBar
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 60)
    }

    // MARK: Clipboard

    private var clipboardGroup: some View {
        GroupBoxV(label: "Clipboard") {
            HStack(spacing: 4) {
                BigButton(symbol: "doc.on.clipboard", title: "Paste") {
                    canvasAccess()?.paste()
                }
                .paintTip("Paste  ⌘V", "Paste a copied picture onto the canvas.")
                VStack(spacing: 2) {
                    SmallButton(symbol: "scissors") { canvasAccess()?.copySelection(cut: true) }
                        .paintTip("Cut  ⌘X", "Remove the selection and put it on the clipboard.")
                    SmallButton(symbol: "doc.on.doc") { canvasAccess()?.copySelection(cut: false) }
                        .paintTip("Copy  ⌘C", "Copy the selection to the clipboard.")
                }
            }
        }
    }

    // MARK: Image

    private var imageGroup: some View {
        GroupBoxV(label: "Image") {
            HStack(spacing: 4) {
                Menu {
                    Button("Rectangular selection") { engine.tool = .select }
                    Button("Free-form selection") { engine.tool = .freeSelect }
                    Divider()
                    Button("Select all") { canvasAccess()?.selectAll() }
                    Button("Delete") { canvasAccess()?.deleteSelection() }
                    Divider()
                    Toggle("Transparent selection", isOn: $engine.transparentSelection)
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "rectangle.dashed").font(.system(size: 17))
                        Text("Select").font(.system(size: 10))
                    }
                    .frame(width: 48, height: 46)
                } primaryAction: {
                    engine.tool = .select
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .background(toolHighlight(engine.tool == .select || engine.tool == .freeSelect))
                .paintTip("Select", "Select part of the picture to move, copy or delete. Use the arrow for free-form selection.")

                VStack(spacing: 2) {
                    SmallButton(symbol: "crop") { canvasAccess()?.cropToSelection() }
                        .paintTip("Crop  ⇧⌘K", "Trim the picture down to whatever is selected.")
                    SmallButton(symbol: "arrow.up.left.and.arrow.down.right") { onResizeDialog() }
                        .paintTip("Resize and skew  ⇧⌘W", "Change the size of the picture, or slant it.")
                    Menu {
                        Button("Rotate right 90°") { engine.rotate90(clockwise: true) }
                        Button("Rotate left 90°") { engine.rotate90(clockwise: false) }
                        Button("Rotate 180°") { engine.rotate180() }
                        Divider()
                        Button("Flip horizontal") { engine.flip(horizontal: true) }
                        Button("Flip vertical") { engine.flip(horizontal: false) }
                    } label: {
                        Image(systemName: "rotate.right").font(.system(size: 12))
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 24, height: 18)
                    .paintTip("Rotate or flip", "Turn the whole picture, or mirror it.")
                }
            }
        }
    }

    // MARK: Tools

    private var toolsGroup: some View {
        GroupBoxV(label: "Tools") {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 3), count: 3), spacing: 3) {
                ToolButton(symbol: "pencil", active: engine.tool == .pencil) { engine.tool = .pencil }
                    .paintTip("Pencil", "Draw a thin freehand line.")
                ToolButton(symbol: "drop.fill", active: engine.tool == .fill) { engine.tool = .fill }
                    .paintTip("Fill with colour", "Click an area to flood it with colour.")
                ToolButton(symbol: "textformat", active: engine.tool == .text) { engine.tool = .text }
                    .paintTip("Text", "Click the canvas and type. Click away to place the text.")
                ToolButton(symbol: "eraser", active: engine.tool == .eraser) { engine.tool = .eraser }
                    .paintTip("Eraser", "Rub out part of the picture, leaving Colour 2 behind.")
                ToolButton(symbol: "eyedropper", active: engine.tool == .picker) { engine.tool = .picker }
                    .paintTip("Colour picker", "Click the picture to copy that colour into Colour 1.")
                ToolButton(symbol: "magnifyingglass", active: engine.tool == .magnifier) { engine.tool = .magnifier }
                    .paintTip("Magnifier", "Click to zoom in, right-click to zoom out.")
            }
        }
    }

    // MARK: Brushes

    private var isBrushActive: Bool {
        if case .brush = engine.tool { return true }
        return false
    }

    private var brushesGroup: some View {
        GroupBoxV(label: "Brushes") {
            Menu {
                ForEach(BrushKind.allCases) { kind in
                    Button {
                        engine.lastBrush = kind
                        engine.tool = .brush(kind)
                    } label: {
                        Label(kind.rawValue, systemImage: kind.symbol)
                    }
                }
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: engine.lastBrush.symbol).font(.system(size: 17))
                    Text("Brushes").font(.system(size: 10))
                }
                .frame(width: 54, height: 46)
            } primaryAction: {
                engine.tool = .brush(engine.lastBrush)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .background(toolHighlight(isBrushActive))
            .paintTip("Brushes — \(engine.lastBrush.rawValue)",
                      "\(engine.lastBrush.detail) Click the arrow to pick a different brush.")
        }
    }

    // MARK: Shapes

    private var shapesGroup: some View {
        GroupBoxV(label: "Shapes") {
            HStack(spacing: 6) {
                ScrollView(.vertical) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 2), count: 6), spacing: 2) {
                        ForEach(ShapeKind.allCases) { kind in
                            ShapeButton(kind: kind, active: engine.tool == .shape(kind)) {
                                engine.lastShape = kind
                                engine.tool = .shape(kind)
                            }
                            .paintTip(kind.rawValue, kind.detail)
                        }
                    }
                    .padding(.trailing, 7)   // room for the scroller
                }
                .scrollIndicators(.visible)
                .frame(width: 158, height: 52)
                // There are twice as many shapes as fit, so fade the bottom edge:
                // without a hint that it scrolls, half the gallery is undiscoverable.
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.86),
                            .init(color: .black.opacity(0.15), location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom)
                )

                VStack(spacing: 3) {
                    Menu {
                        ForEach(OutlineStyle.allCases) { s in
                            Button {
                                engine.shapeOutline = s
                                // Outline and fill both off would draw nothing at
                                // all, with no hint as to why. Keep one of them on.
                                if s == .none, engine.shapeFill == .none {
                                    engine.shapeFill = .solid
                                }
                            } label: {
                                HStack {
                                    Text(s.rawValue)
                                    if engine.shapeOutline == s { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    } label: {
                        Text(engine.shapeOutline == .none ? "Outline: off" : "Outline")
                            .font(.system(size: 10))
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .paintTip("Outline", "Whether the shape gets a border, drawn in Colour 1.")
                    Menu {
                        ForEach(FillStyle.allCases) { s in
                            Button {
                                engine.shapeFill = s
                                if s == .none, engine.shapeOutline == .none {
                                    engine.shapeOutline = .solid
                                }
                            } label: {
                                HStack {
                                    Text(s.rawValue)
                                    if engine.shapeFill == s { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    } label: {
                        Text(engine.shapeFill == .none ? "Fill" : "Fill: on")
                            .font(.system(size: 10))
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .paintTip("Fill", "Whether the inside of the shape is filled, using Colour 2.")
                }
            }
        }
    }

    // MARK: Size

    private var sizeGroup: some View {
        GroupBoxV(label: "Size") {
            Menu {
                ForEach([1, 2, 3, 5, 8, 12, 16, 24, 30, 40], id: \.self) { s in
                    Button {
                        engine.strokeSize = CGFloat(s)
                    } label: {
                        HStack {
                            Text("\(s) px")
                            if Int(engine.strokeSize) == s { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                VStack(spacing: 4) {
                    VStack(spacing: 3) {
                        ForEach([1.5, 3, 5], id: \.self) { h in
                            Capsule().fill(Color.primary).frame(width: 26, height: h)
                        }
                    }
                    Text("Size").font(.system(size: 10))
                }
                .frame(width: 44, height: 46)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .paintTip("Size — \(Int(engine.strokeSize)) px",
                      "How thick the pencil, brushes, eraser and shape outlines draw.")
        }
    }

    // MARK: Layers

    private var layersGroup: some View {
        GroupBoxV(label: "Layers") {
            HStack(spacing: 4) {
                Button {
                    engine.showLayersPanel.toggle()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "square.stack.3d.up").font(.system(size: 17))
                        Text("Layers").font(.system(size: 10))
                    }
                    .frame(width: 48, height: 46)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(engine.showLayersPanel ? Color.accentColor.opacity(0.18) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .paintTip("Layers  ⇧⌘L",
                          engine.layers.count > 1
                            ? "\(engine.layers.count) layers. Draw on one without touching the others."
                            : "Stack drawings in separate layers, so you can move or hide one without disturbing the rest.")

                VStack(spacing: 2) {
                    SmallButton(symbol: "plus") { engine.addLayer() }
                        .paintTip("New layer  ⇧⌘N", "Adds an empty layer above the current one.")
                    SmallButton(symbol: "arrow.triangle.merge") { engine.mergeLayerDown() }
                        .paintTip("Merge down  ⌘E", "Combines this layer with the one below it.")
                    SmallButton(symbol: "square.stack.3d.down.forward") { engine.flattenLayers() }
                        .paintTip("Flatten  ⇧⌘E", "Combines every layer into one.")
                }
            }
        }
    }

    // MARK: Colours

    private var colorsGroup: some View {
        GroupBoxV(label: "Colours") {
            HStack(spacing: 8) {
                VStack(spacing: 3) {
                    ColorWell(color: engine.color1, label: "1", selected: engine.activeColorSlot == 1) {
                        engine.activeColorSlot = 1
                    }
                    ColorWell(color: engine.color2, label: "2", selected: engine.activeColorSlot == 2) {
                        engine.activeColorSlot = 2
                    }
                }
                VStack(spacing: 3) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: 3) {
                            ForEach(0..<10, id: \.self) { col in
                                let entry = Palette.rows[row][col]
                                swatch(entry.color)
                                    .paintTip(entry.name, swatchHint)
                            }
                            if row == 0 {
                                ForEach(Array(engine.customColors.prefix(4).enumerated()), id: \.offset) { _, c in
                                    swatch(c).paintTip("Custom colour", swatchHint)
                                }
                            }
                        }
                    }
                }
                Button {
                    openColorPanel()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "paintpalette").font(.system(size: 15))
                        Text("Edit").font(.system(size: 9))
                    }
                    .frame(width: 36, height: 42)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .paintTip("Edit colours",
                          "Mix your own colour. It is added to the palette for reuse.")
            }
        }
    }

    /// The palette sets whichever colour slot is currently armed, so say which.
    private var swatchHint: String {
        engine.activeColorSlot == 2 ? "Sets Colour 2 (right mouse button)."
                                    : "Sets Colour 1 (left mouse button)."
    }

    private func swatch(_ c: NSColor) -> some View {
        Button {
            if engine.activeColorSlot == 2 { engine.color2 = c } else { engine.color1 = c }
        } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: c))
                .frame(width: 16, height: 16)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.25), lineWidth: 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openColorPanel() {
        let panel = NSColorPanel.shared
        panel.setTarget(ColorPanelBridge.shared)
        panel.setAction(#selector(ColorPanelBridge.colorChanged(_:)))
        ColorPanelBridge.shared.engine = engine
        panel.color = engine.activeColorSlot == 2 ? engine.color2 : engine.color1
        panel.makeKeyAndOrderFront(nil)
    }

    private func toolHighlight(_ on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(on ? Color.accentColor.opacity(0.18) : Color.clear)
    }

    // MARK: Text options bar

    private var textOptionsBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $engine.fontName) {
                ForEach(["Helvetica", "Arial", "Times New Roman", "Courier New", "Georgia",
                         "Verdana", "Comic Sans MS", "Impact", "Trebuchet MS"], id: \.self) { f in
                    Text(f).tag(f)
                }
            }
            .frame(width: 180)
            Picker("", selection: $engine.fontSize) {
                ForEach([8, 10, 12, 14, 18, 24, 36, 48, 72], id: \.self) { s in
                    Text("\(s)").tag(CGFloat(s))
                }
            }
            .frame(width: 70)
            Toggle("B", isOn: $engine.fontBold).toggleStyle(.button).font(.system(size: 12, weight: .bold))
            Toggle("I", isOn: $engine.fontItalic).toggleStyle(.button).italic()
            Toggle("U", isOn: $engine.fontUnderline).toggleStyle(.button).underline()
            Toggle("Opaque background", isOn: $engine.textOpaqueBackground).font(.system(size: 11))
            Spacer()
            Text("Click the canvas, type, then click away to place the text")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
    }
}

// MARK: - Colour panel target

final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    weak var engine: PaintEngine?

    @objc func colorChanged(_ sender: NSColorPanel) {
        guard let engine else { return }
        let c = sender.color
        if engine.activeColorSlot == 2 { engine.color2 = c } else { engine.color1 = c }
        if !engine.customColors.contains(where: { $0.isClose(to: c) }) {
            engine.customColors.append(c)
            if engine.customColors.count > 4 { engine.customColors.removeFirst() }
        }
    }
}


// MARK: - Small components

struct RibbonBackground: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .overlay(Divider(), alignment: .bottom)
    }
}

struct GroupBoxV<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 2) {
            content.frame(maxHeight: .infinity)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct BigButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 18))
                Text(title).font(.system(size: 10))
            }
            .frame(width: 46, height: 46)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

struct SmallButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 24, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ToolButton: View {
    let symbol: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(active ? Color.accentColor.opacity(0.22) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .stroke(active ? Color.accentColor : Color.clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ShapeButton: View {
    let kind: ShapeKind
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(nsImage: ShapePath.previewImage(for: kind))
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(active ? Color.accentColor.opacity(0.22) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(active ? Color.accentColor : Color.clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ColorWell: View {
    let color: NSColor
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: color))
                    .frame(width: 18, height: 18)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.3), lineWidth: 0.5))
                Text("Colour \(label)").font(.system(size: 9))
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(selected ? Color.accentColor.opacity(0.22) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .paintTip(
            label == "1" ? "Colour 1" : "Colour 2",
            label == "1"
                ? "The colour the left mouse button draws with. Click here, then pick a swatch to change it."
                : "The colour the right mouse button draws with. Also used by the eraser and shape fills."
        )
    }
}

// MARK: - Status bar

struct StatusBarView: View {
    @ObservedObject var engine: PaintEngine
    /// Opens the Resize and skew sheet, which handles any size the presets miss.
    var onCustomSize: () -> Void = {}

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Image(systemName: "plus.viewfinder").font(.system(size: 11))
                Text(engine.cursorPos.map { "\(Int($0.x)), \(Int($0.y)) px" } ?? "")
                    .frame(width: 90, alignment: .leading)
            }
            .paintTip("Pointer position", "Where the pointer is on the canvas, in pixels.")
            HStack(spacing: 4) {
                Image(systemName: "rectangle.dashed").font(.system(size: 11))
                Text(engine.selectionInfo.map { "\(Int($0.width)) × \(Int($0.height)) px" } ?? "")
                    .frame(width: 90, alignment: .leading)
            }
            .paintTip("Selection size", "The size of the current selection, in pixels.")
            canvasSizeMenu
            Spacer()
            HStack(spacing: 8) {
                ZoomButton(symbol: "minus") { engine.zoomOut() }
                    .paintTip("Zoom out  ⌘−", "Show more of the picture, smaller.")
                Slider(value: zoomBinding, in: 0.125...8).frame(width: 120)
                    .paintTip("Zoom", "Drag to zoom between 12.5% and 800%.")
                ZoomButton(symbol: "plus") { engine.zoomIn() }
                    .paintTip("Zoom in  ⌘+", "Magnify the picture to work on fine detail.")
                Text("\(Int(engine.zoom * 100))%").frame(width: 44, alignment: .trailing)
                    .paintTip("Zoom level", "Press ⌘0 to go back to 100%.")
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(Divider(), alignment: .top)
    }

    private var zoomBinding: Binding<CGFloat> {
        Binding(get: { engine.zoom }, set: { engine.zoom = $0 })
    }

    // MARK: Canvas size

    private var canvasSizeMenu: some View {
        Menu {
            Section("Screen") {
                ForEach(CanvasPresets.screen) { preset in presetButton(preset) }
            }
            Section("Paper — 150 dpi") {
                ForEach(CanvasPresets.paper) { preset in presetButton(preset) }
            }
            Section("Square") {
                ForEach(CanvasPresets.square) { preset in presetButton(preset) }
            }
            Divider()
            Button("Custom size…") { onCustomSize() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "photo").font(.system(size: 11))
                Text("\(Int(engine.canvasSize.width)) × \(Int(engine.canvasSize.height)) px")
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 7))
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .paintTip("Picture size",
                  "The size of the whole canvas. Click to choose a preset or a custom size.")
    }

    private func presetButton(_ preset: CanvasPreset) -> some View {
        Button {
            guard Int(engine.canvasSize.width) != preset.width
                    || Int(engine.canvasSize.height) != preset.height else { return }
            // Keep the picture at its original scale rather than stretching it
            // onto the new canvas; ⌘Z puts it back.
            engine.resizeCanvas(to: preset.size, stretch: false)
        } label: {
            HStack {
                Text("\(preset.name)  —  \(preset.dimensions)")
                if Int(engine.canvasSize.width) == preset.width,
                   Int(engine.canvasSize.height) == preset.height {
                    Image(systemName: "checkmark")
                }
            }
        }
    }
}

/// A symbol button with an explicit hit area. Without one, a glyph as thin as
/// "minus" is only a couple of points tall and is nearly impossible to click.
struct ZoomButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}
