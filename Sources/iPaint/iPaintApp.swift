import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct IPaintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var engine = PaintEngine()
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("iPaint", id: "main") {
            ContentView(engine: engine, state: state)
                .onAppear { state.engine = engine }
        }
        .defaultSize(width: 1240, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New") { state.newDocument() }.keyboardShortcut("n")
                Button("Open…") { state.openDocument() }.keyboardShortcut("o")
                Divider()
                Button("Save") { state.saveDocument(forceAsk: false) }.keyboardShortcut("s")
                Button("Save As…") { state.saveDocument(forceAsk: true) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { engine.undo() }.keyboardShortcut("z")
                Button("Redo") { engine.redo() }.keyboardShortcut("y")
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") { state.canvas?.copySelection(cut: true) }.keyboardShortcut("x")
                Button("Copy") { state.canvas?.copySelection(cut: false) }.keyboardShortcut("c")
                Button("Paste") { state.canvas?.paste() }.keyboardShortcut("v")
                Button("Delete") { state.canvas?.deleteSelection() }
                Divider()
                Button("Select All") { state.canvas?.selectAll() }.keyboardShortcut("a")
            }
            CommandMenu("Image") {
                Button("Resize and Skew…") { state.showResizeSheet = true }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                Button("Crop to Selection") { state.canvas?.cropToSelection() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Divider()
                Button("Rotate Right 90°") { engine.rotate90(clockwise: true) }.keyboardShortcut("r")
                Button("Rotate Left 90°") { engine.rotate90(clockwise: false) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Rotate 180°") { engine.rotate180() }
                Button("Flip Horizontal") { engine.flip(horizontal: true) }
                Button("Flip Vertical") { engine.flip(horizontal: false) }
                Divider()
                Button("Invert Colours") { engine.invertColors() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Clear Canvas") { engine.clearAll() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
            }
            CommandMenu("Layers") {
                Toggle("Show Layers Panel", isOn: $engine.showLayersPanel)
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Divider()
                Button("New Layer") { engine.addLayer() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Duplicate Layer") { engine.duplicateLayer() }
                Button("Delete Layer") { engine.deleteLayer() }
                    .disabled(!engine.canDeleteLayer)
                Divider()
                Button("Bring Layer Forward") { engine.moveLayerUp() }
                    .disabled(!engine.canMoveLayerUp)
                Button("Send Layer Backward") { engine.moveLayerDown() }
                    .disabled(!engine.canMoveLayerDown)
                Divider()
                Button("Merge Layer Down") { engine.mergeLayerDown() }
                    .keyboardShortcut("e", modifiers: [.command])
                    .disabled(!engine.canMergeLayerDown)
                Button("Flatten Image") { engine.flattenLayers() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(engine.layers.count <= 1)
            }
            CommandMenu("View") {
                Button("Zoom In") { engine.zoomIn() }.keyboardShortcut("+")
                Button("Zoom Out") { engine.zoomOut() }.keyboardShortcut("-")
                Button("Actual Size") { engine.zoom = 1 }.keyboardShortcut("0")
                Divider()
                Toggle("Gridlines", isOn: $engine.showGrid).keyboardShortcut("g")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Shared state / file operations

final class AppState: ObservableObject {
    weak var engine: PaintEngine?
    var canvas: CanvasNSView?
    @Published var showResizeSheet = false

    private func confirmDiscardIfDirty() -> Bool {
        guard let engine, engine.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save changes to \(engine.documentName)?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveDocument(forceAsk: false)
            return !(engine.isDirty)
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func newDocument() {
        guard confirmDiscardIfDirty() else { return }
        canvas?.clearSelection(commit: false)
        engine?.newDocument()
    }

    func openDocument() {
        guard confirmDiscardIfDirty() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .bmp, .gif, .tiff, .heic, .webP]
        if panel.runModal() == .OK, let url = panel.url {
            _ = engine?.load(url: url)
        }
    }

    func saveDocument(forceAsk: Bool) {
        guard let engine else { return }
        canvas?.commitTextIfAny()
        canvas?.clearSelection(commit: true)
        if !forceAsk, let url = engine.documentURL {
            engine.save(to: url)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .bmp, .tiff]
        panel.nameFieldStringValue = engine.documentURL?.lastPathComponent ?? "Untitled.png"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            engine.save(to: url)
        }
    }
}

// MARK: - Main window content

struct ContentView: View {
    @ObservedObject var engine: PaintEngine
    @ObservedObject var state: AppState

    @StateObject private var tips = TooltipModel()

    var body: some View {
        GeometryReader { root in
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    RibbonView(engine: engine,
                               canvasAccess: { state.canvas },
                               onResizeDialog: { state.showResizeSheet = true })
                    HStack(spacing: 0) {
                        CanvasHost(engine: engine) { canvas in
                            DispatchQueue.main.async { state.canvas = canvas }
                        }
                        if engine.showLayersPanel {
                            Divider()
                            LayersPanel(engine: engine)
                        }
                    }
                    StatusBarView(engine: engine) { state.showResizeSheet = true }
                }
                if let info = tips.info {
                    TooltipOverlay(info: info, container: root.size)
                }
            }
            .coordinateSpace(name: TooltipModel.space)
        }
        .environmentObject(tips)
        .sheet(isPresented: $state.showResizeSheet) {
            ResizeSkewSheet(engine: engine)
        }
        .navigationTitle("\(engine.documentName)\(engine.isDirty ? " — Edited" : "") – iPaint")
    }
}

// MARK: - Resize & Skew dialog (like Paint's)

struct ResizeSkewSheet: View {
    @ObservedObject var engine: PaintEngine
    @Environment(\.dismiss) private var dismiss

    @State private var byPercent = false
    @State private var width: String = ""
    @State private var height: String = ""
    @State private var keepAspect = true
    @State private var stretch = true
    @State private var skewH: String = "0"
    @State private var skewV: String = "0"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Resize and skew").font(.headline)

            GroupBox("Resize") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("By:", selection: $byPercent) {
                        Text("Pixels").tag(false)
                        Text("Percentage").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()

                    HStack {
                        Text("Horizontal:").frame(width: 80, alignment: .trailing)
                        TextField("", text: $width).frame(width: 80)
                            .onChange(of: width) { _, new in syncAspect(fromWidth: true, value: new) }
                    }
                    HStack {
                        Text("Vertical:").frame(width: 80, alignment: .trailing)
                        TextField("", text: $height).frame(width: 80)
                            .onChange(of: height) { _, new in syncAspect(fromWidth: false, value: new) }
                    }
                    Toggle("Maintain aspect ratio", isOn: $keepAspect)
                    Toggle("Stretch image contents", isOn: $stretch)
                }
                .padding(6)
            }

            GroupBox("Skew (degrees)") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Horizontal:").frame(width: 80, alignment: .trailing)
                        TextField("", text: $skewH).frame(width: 80)
                    }
                    HStack {
                        Text("Vertical:").frame(width: 80, alignment: .trailing)
                        TextField("", text: $skewV).frame(width: 80)
                    }
                }
                .padding(6)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK") { apply() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear {
            width = byPercent ? "100" : String(Int(engine.canvasSize.width))
            height = byPercent ? "100" : String(Int(engine.canvasSize.height))
        }
        .onChange(of: byPercent) { _, pct in
            width = pct ? "100" : String(Int(engine.canvasSize.width))
            height = pct ? "100" : String(Int(engine.canvasSize.height))
        }
    }

    private var isSyncing: Bool { syncing }
    @State private var syncing = false

    private func syncAspect(fromWidth: Bool, value: String) {
        guard keepAspect, !syncing, let v = Double(value), v > 0 else { return }
        syncing = true
        defer { syncing = false }
        let ratio = engine.canvasSize.height / engine.canvasSize.width
        if byPercent {
            if fromWidth { height = value } else { width = value }
        } else if fromWidth {
            height = String(Int((CGFloat(v) * ratio).rounded()))
        } else {
            width = String(Int((CGFloat(v) / ratio).rounded()))
        }
    }

    private func apply() {
        let w = Double(width) ?? 0
        let h = Double(height) ?? 0
        if w > 0 && h > 0 {
            let newSize: CGSize
            if byPercent {
                newSize = CGSize(width: engine.canvasSize.width * w / 100,
                                 height: engine.canvasSize.height * h / 100)
            } else {
                newSize = CGSize(width: w, height: h)
            }
            if newSize != engine.canvasSize {
                engine.resizeCanvas(to: newSize, stretch: stretch)
            }
        }
        let sh = Double(skewH) ?? 0, sv = Double(skewV) ?? 0
        if sh != 0 || sv != 0 {
            engine.skew(horizontalDeg: CGFloat(max(-89, min(89, sh))),
                        verticalDeg: CGFloat(max(-89, min(89, sv))))
        }
        dismiss()
    }
}
