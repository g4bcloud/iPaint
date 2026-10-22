import Foundation

/// A named canvas size offered in the status-bar size menu.
struct CanvasPreset: Identifiable, Equatable {
    let name: String
    let width: Int
    let height: Int

    var id: String { name }
    var size: CGSize { CGSize(width: width, height: height) }
    /// e.g. "1920 × 1080"
    var dimensions: String { "\(width) × \(height)" }
}

enum CanvasPresets {
    /// Paint's own starting size.
    static let standard = CanvasPreset(name: "Default", width: 1152, height: 648)

    static let screen: [CanvasPreset] = [
        standard,
        CanvasPreset(name: "HD — 1080p", width: 1920, height: 1080),
        CanvasPreset(name: "2K — QHD", width: 2560, height: 1440),
        CanvasPreset(name: "4K — UHD", width: 3840, height: 2160),
    ]

    /// Paper at 150 dpi, which prints cleanly without being unwieldy to edit —
    /// useful for worksheets and handouts.
    static let paper: [CanvasPreset] = [
        CanvasPreset(name: "A4 portrait", width: 1240, height: 1754),
        CanvasPreset(name: "A4 landscape", width: 1754, height: 1240),
        CanvasPreset(name: "Letter portrait", width: 1275, height: 1650),
        CanvasPreset(name: "Letter landscape", width: 1650, height: 1275),
    ]

    static let square: [CanvasPreset] = [
        CanvasPreset(name: "Square — small", width: 800, height: 800),
        CanvasPreset(name: "Square — large", width: 2048, height: 2048),
    ]

    static var all: [CanvasPreset] { screen + paper + square }

    /// The preset matching `size` exactly, if there is one.
    static func matching(_ size: CGSize) -> CanvasPreset? {
        all.first { $0.width == Int(size.width) && $0.height == Int(size.height) }
    }
}
