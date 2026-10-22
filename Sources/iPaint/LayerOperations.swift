import AppKit

/// Adding, removing, reordering and merging layers.
///
/// Every one of these changes the stack rather than just one layer's pixels, so
/// they all take a full document snapshot for undo.
extension PaintEngine {

    var canDeleteLayer: Bool { layers.count > 1 }
    var canMoveLayerUp: Bool { activeLayerIndex < layers.count - 1 }
    var canMoveLayerDown: Bool { activeLayerIndex > 0 }
    /// Merging needs something underneath to merge into.
    var canMergeLayerDown: Bool { activeLayerIndex > 0 }

    /// A name like "Layer 3" that is not already taken.
    private func nextLayerName() -> String {
        var n = layers.count + 1
        let taken = Set(layers.map(\.name))
        while taken.contains("Layer \(n)") { n += 1 }
        return "Layer \(n)"
    }

    /// Adds a transparent layer directly above the active one and selects it.
    func addLayer() {
        guard let fresh = Layer(name: nextLayerName(), size: canvasSize, fillWhite: false) else {
            return
        }
        snapshotDocumentForUndo()
        let at = clampedIndex(activeLayerIndex) + 1
        var updated = layers
        updated.insert(fresh, at: at)
        setLayers(updated, active: at)
    }

    func duplicateLayer() {
        let source = activeLayer
        guard let copy = Layer(name: "\(source.name) copy", size: canvasSize, fillWhite: false)
        else { return }
        copy.copyingSettings(from: source)
        if let img = source.image {
            copy.context.draw(img, in: CGRect(origin: .zero, size: canvasSize))
        }
        snapshotDocumentForUndo()
        let at = clampedIndex(activeLayerIndex) + 1
        var updated = layers
        updated.insert(copy, at: at)
        setLayers(updated, active: at)
    }

    func deleteLayer() {
        guard canDeleteLayer else { return }
        snapshotDocumentForUndo()
        var updated = layers
        let removing = clampedIndex(activeLayerIndex)
        updated.remove(at: removing)
        setLayers(updated, active: min(removing, updated.count - 1))
    }

    /// Moves the active layer one step towards the front.
    func moveLayerUp() {
        guard canMoveLayerUp else { return }
        snapshotDocumentForUndo()
        var updated = layers
        let from = clampedIndex(activeLayerIndex)
        updated.swapAt(from, from + 1)
        setLayers(updated, active: from + 1)
    }

    func moveLayerDown() {
        guard canMoveLayerDown else { return }
        snapshotDocumentForUndo()
        var updated = layers
        let from = clampedIndex(activeLayerIndex)
        updated.swapAt(from, from - 1)
        setLayers(updated, active: from - 1)
    }

    /// Flattens the active layer onto the one below, honouring its opacity, and
    /// keeps the lower layer's name.
    func mergeLayerDown() {
        guard canMergeLayerDown else { return }
        let upperIndex = clampedIndex(activeLayerIndex)
        let upper = layers[upperIndex]
        let lower = layers[upperIndex - 1]
        snapshotDocumentForUndo()
        if upper.visible, upper.opacity > 0, let img = upper.image {
            lower.context.saveGState()
            lower.context.setAlpha(upper.opacity)
            lower.context.draw(img, in: CGRect(origin: .zero, size: canvasSize))
            lower.context.restoreGState()
        }
        var updated = layers
        updated.remove(at: upperIndex)
        setLayers(updated, active: upperIndex - 1)
    }

    /// Collapses everything into a single opaque layer.
    func flattenLayers() {
        guard layers.count > 1 else { return }
        snapshotDocumentForUndo()
        guard let flat = Layer(name: "Background", size: canvasSize, fillWhite: true),
              let composite = image else { return }
        flat.context.draw(composite, in: CGRect(origin: .zero, size: canvasSize))
        setLayers([flat], active: 0)
    }

    func setLayerVisible(_ visible: Bool, at index: Int) {
        guard layers.indices.contains(index) else { return }
        snapshotDocumentForUndo()
        layers[index].visible = visible
        bumpRevision()
    }

    func toggleLayerVisible(at index: Int) {
        guard layers.indices.contains(index) else { return }
        setLayerVisible(!layers[index].visible, at: index)
    }

    /// Live opacity dragging would push a snapshot per frame, so the caller
    /// snapshots once when the drag begins and passes `recordUndo: false` after.
    func setLayerOpacity(_ opacity: CGFloat, at index: Int, recordUndo: Bool = true) {
        guard layers.indices.contains(index) else { return }
        if recordUndo { snapshotDocumentForUndo() }
        layers[index].opacity = min(1, max(0, opacity))
        bumpRevision()
    }

    func renameLayer(_ name: String, at index: Int) {
        guard layers.indices.contains(index) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != layers[index].name else { return }
        snapshotDocumentForUndo()
        layers[index].name = trimmed
        bumpRevision()
    }

    func selectLayer(at index: Int) {
        activeLayerIndex = clampedIndex(index)
    }

    private func clampedIndex(_ i: Int) -> Int {
        layers.isEmpty ? 0 : min(max(0, i), layers.count - 1)
    }
}
