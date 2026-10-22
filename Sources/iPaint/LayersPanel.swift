import SwiftUI
import AppKit

/// The layers list down the right-hand side: topmost layer at the top, as in
/// every other editor that has layers.
struct LayersPanel: View {
    @ObservedObject var engine: PaintEngine
    @State private var renaming: UUID?
    @State private var draftName: String = ""
    /// Opacity dragging records one undo step for the whole drag, not per frame.
    @State private var opacityDragging = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            opacityRow
            Divider()
            toolbar
        }
        .frame(width: 228)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Layers").font(.system(size: 12, weight: .semibold))
            Spacer()
            Button {
                engine.showLayersPanel = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .paintTip("Hide layers", "You can bring the panel back from the Layers button.")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                // reversed so the front-most layer sits at the top of the list
                ForEach(Array(engine.layers.enumerated()).reversed(), id: \.element.id) { index, layer in
                    row(index: index, layer: layer)
                }
            }
            .padding(6)
        }
        .frame(maxHeight: .infinity)
    }

    private func row(index: Int, layer: Layer) -> some View {
        let selected = index == min(max(0, engine.activeLayerIndex), engine.layers.count - 1)
        return HStack(spacing: 7) {
            Button {
                engine.toggleLayerVisible(at: index)
            } label: {
                Image(systemName: layer.visible ? "eye" : "eye.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(layer.visible ? Color.primary : Color.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(layer.visible ? "Hide this layer" : "Show this layer")

            thumbnail(for: layer)

            if renaming == layer.id {
                TextField("", text: $draftName, onCommit: {
                    engine.renameLayer(draftName, at: index)
                    renaming = nil
                })
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
            } else {
                Text(layer.name)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .opacity(layer.visible ? 1 : 0.45)
                Spacer(minLength: 0)
                if layer.opacity < 0.999 {
                    Text("\(Int(layer.opacity * 100))%")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.20) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        // The double-tap must be attached first: SwiftUI matches gestures in
        // order, so a single-tap registered ahead of it swallows every click and
        // rename-by-double-click never fires.
        .onTapGesture(count: 2) {
            engine.selectLayer(at: index)
            draftName = layer.name
            renaming = layer.id
        }
        .onTapGesture { engine.selectLayer(at: index) }
        .contextMenu {
            Button("Rename…") { draftName = layer.name; renaming = layer.id }
            Button(layer.visible ? "Hide" : "Show") { engine.toggleLayerVisible(at: index) }
            Divider()
            Button("Duplicate") { engine.selectLayer(at: index); engine.duplicateLayer() }
            Button("Merge Down") { engine.selectLayer(at: index); engine.mergeLayerDown() }
                .disabled(index == 0)
            Divider()
            Button("Delete") { engine.selectLayer(at: index); engine.deleteLayer() }
                .disabled(engine.layers.count <= 1)
        }
    }

    private func thumbnail(for layer: Layer) -> some View {
        let box = CGSize(width: 34, height: 26)
        return ZStack {
            CheckerboardBackground()
            if let thumb = layer.thumbnail(fitting: box) {
                Image(nsImage: NSImage(cgImage: thumb,
                                       size: NSSize(width: thumb.width, height: thumb.height)))
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: box.width, height: box.height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(
            RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.18), lineWidth: 0.5)
        )
        // regenerate when the picture changes
        .id("\(layer.id)-\(engine.revision)")
    }

    // MARK: Opacity

    private var opacityRow: some View {
        let index = min(max(0, engine.activeLayerIndex), max(0, engine.layers.count - 1))
        return HStack(spacing: 8) {
            Text("Opacity").font(.system(size: 11)).foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { engine.layers.indices.contains(index) ? engine.layers[index].opacity : 1 },
                    set: { value in
                        // one undo step per drag, taken on the first change
                        engine.setLayerOpacity(value, at: index, recordUndo: !opacityDragging)
                        opacityDragging = true
                    }
                ),
                in: 0...1,
                onEditingChanged: { editing in if !editing { opacityDragging = false } }
            )
            Text("\(Int((engine.layers.indices.contains(index) ? engine.layers[index].opacity : 1) * 100))%")
                .font(.system(size: 10))
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 2) {
            PanelButton(symbol: "plus", help: "New layer",
                        tip: ("New layer", "Adds an empty layer above this one.")) {
                engine.addLayer()
            }
            PanelButton(symbol: "plus.square.on.square", help: "Duplicate layer",
                        tip: ("Duplicate layer", "Copies this layer, including what is drawn on it.")) {
                engine.duplicateLayer()
            }
            PanelButton(symbol: "arrow.up", help: "Move up", enabled: engine.canMoveLayerUp,
                        tip: ("Move up", "Brings this layer in front of the one above.")) {
                engine.moveLayerUp()
            }
            PanelButton(symbol: "arrow.down", help: "Move down", enabled: engine.canMoveLayerDown,
                        tip: ("Move down", "Sends this layer behind the one below.")) {
                engine.moveLayerDown()
            }
            PanelButton(symbol: "arrow.triangle.merge", help: "Merge down",
                        enabled: engine.canMergeLayerDown,
                        tip: ("Merge down", "Stamps this layer onto the one below and combines them.")) {
                engine.mergeLayerDown()
            }
            Spacer(minLength: 0)
            PanelButton(symbol: "trash", help: "Delete layer", enabled: engine.canDeleteLayer,
                        tip: ("Delete layer", "Removes this layer and everything on it. ⌘Z undoes it.")) {
                engine.deleteLayer()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

private struct PanelButton: View {
    let symbol: String
    let help: String
    var enabled: Bool = true
    var tip: (String, String)? = nil
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)

        if let tip {
            return AnyView(button.paintTip(tip.0, tip.1))
        }
        return AnyView(button.help(help))
    }
}

/// The usual grey chequerboard standing in for transparency.
struct CheckerboardBackground: View {
    var square: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let cols = Int(ceil(size.width / square))
                let rows = Int(ceil(size.height / square))
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
                for r in 0..<max(0, rows) {
                    for c in 0..<max(0, cols) where (r + c).isMultiple(of: 2) {
                        let rect = CGRect(x: CGFloat(c) * square, y: CGFloat(r) * square,
                                          width: square, height: square)
                        ctx.fill(Path(rect), with: .color(Color(white: 0.82)))
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}
