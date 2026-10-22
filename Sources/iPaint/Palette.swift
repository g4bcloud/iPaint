import AppKit

/// Paint's default 20 swatches, with the names Paint shows on hover.
enum Palette {
    static let rows: [[(name: String, color: NSColor)]] = [
        [
            ("Black", NSColor(hex: 0x000000)), ("Grey 50%", NSColor(hex: 0x7F7F7F)),
            ("Dark red", NSColor(hex: 0x880015)), ("Red", NSColor(hex: 0xED1C24)),
            ("Orange", NSColor(hex: 0xFF7F27)), ("Yellow", NSColor(hex: 0xFFF200)),
            ("Green", NSColor(hex: 0x22B14C)), ("Turquoise", NSColor(hex: 0x00A2E8)),
            ("Indigo", NSColor(hex: 0x3F48CC)), ("Purple", NSColor(hex: 0xA349A4)),
        ],
        [
            ("White", NSColor(hex: 0xFFFFFF)), ("Grey 25%", NSColor(hex: 0xC3C3C3)),
            ("Brown", NSColor(hex: 0xB97A57)), ("Rose", NSColor(hex: 0xFFAEC9)),
            ("Gold", NSColor(hex: 0xFFC90E)), ("Light yellow", NSColor(hex: 0xEFE4B0)),
            ("Lime", NSColor(hex: 0xB5E61D)), ("Light turquoise", NSColor(hex: 0x99D9EA)),
            ("Blue grey", NSColor(hex: 0x7092BE)), ("Lavender", NSColor(hex: 0xC8BFE7)),
        ],
    ]
}

extension NSColor {
    convenience init(hex: Int) {
        self.init(deviceRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    func isClose(to other: NSColor) -> Bool {
        guard let a = usingColorSpace(.deviceRGB), let b = other.usingColorSpace(.deviceRGB) else {
            return false
        }
        return abs(a.redComponent - b.redComponent) < 0.02 &&
               abs(a.greenComponent - b.greenComponent) < 0.02 &&
               abs(a.blueComponent - b.blueComponent) < 0.02
    }
}
