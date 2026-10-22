// Renders the iPaint app icon (macOS-style rounded square, palette artwork).
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// transparent margin like real macOS icons (~10%)
let inset = size * 0.1
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let path = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil)

// background gradient (blue, Fluent-ish like Win11 Paint)
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
let colors = [NSColor(calibratedRed: 0.36, green: 0.65, blue: 0.95, alpha: 1).cgColor,
              NSColor(calibratedRed: 0.13, green: 0.36, blue: 0.78, alpha: 1).cgColor] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: size / 2, y: size - inset), end: CGPoint(x: size / 2, y: inset), options: [])

// white canvas sheet
let sheet = CGRect(x: rect.minX + rect.width * 0.17, y: rect.minY + rect.height * 0.17,
                   width: rect.width * 0.66, height: rect.height * 0.66)
let sheetPath = CGPath(roundedRect: sheet, cornerWidth: 28, cornerHeight: 28, transform: nil)
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(sheetPath)
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)

// colourful brush stroke across the sheet
ctx.addPath(sheetPath)
ctx.clip()
let strokeColors: [(NSColor, CGFloat)] = [
    (NSColor(calibratedRed: 0.93, green: 0.26, blue: 0.21, alpha: 1), 0.68),
    (NSColor(calibratedRed: 1.00, green: 0.72, blue: 0.10, alpha: 1), 0.55),
    (NSColor(calibratedRed: 0.20, green: 0.72, blue: 0.35, alpha: 1), 0.42),
    (NSColor(calibratedRed: 0.25, green: 0.52, blue: 0.95, alpha: 1), 0.29),
]
for (color, yFrac) in strokeColors {
    ctx.setStrokeColor(color.cgColor)
    ctx.setLineWidth(sheet.height * 0.09)
    ctx.setLineCap(.round)
    let y = sheet.minY + sheet.height * yFrac
    ctx.move(to: CGPoint(x: sheet.minX + sheet.width * 0.12, y: y))
    ctx.addCurve(to: CGPoint(x: sheet.maxX - sheet.width * 0.12, y: y + sheet.height * 0.06),
                 control1: CGPoint(x: sheet.minX + sheet.width * 0.4, y: y + sheet.height * 0.12),
                 control2: CGPoint(x: sheet.maxX - sheet.width * 0.4, y: y - sheet.height * 0.08))
    ctx.strokePath()
}
ctx.resetClip()

// brush handle diagonal
ctx.setStrokeColor(NSColor(calibratedRed: 0.45, green: 0.28, blue: 0.16, alpha: 1).cgColor)
ctx.setLineWidth(56)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: rect.maxX - rect.width * 0.16, y: rect.minY + rect.height * 0.12))
ctx.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.38, y: rect.minY + rect.height * 0.40))
ctx.strokePath()
ctx.setStrokeColor(NSColor(calibratedRed: 0.78, green: 0.78, blue: 0.80, alpha: 1).cgColor)
ctx.setLineWidth(60)
ctx.move(to: CGPoint(x: rect.maxX - rect.width * 0.38, y: rect.minY + rect.height * 0.40))
ctx.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.44, y: rect.minY + rect.height * 0.475))
ctx.strokePath()
ctx.setStrokeColor(NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.12, alpha: 1).cgColor)
ctx.setLineWidth(52)
ctx.move(to: CGPoint(x: rect.maxX - rect.width * 0.44, y: rect.minY + rect.height * 0.475))
ctx.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.52, y: rect.minY + rect.height * 0.57))
ctx.strokePath()

img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
