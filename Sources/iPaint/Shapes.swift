import AppKit

/// Builds CGPaths for the Windows 11 Paint shape gallery.
/// Paths are produced in canvas (top-left origin) coordinates within `rect`.
enum ShapePath {

    static func path(for kind: ShapeKind, in rect: CGRect, start: CGPoint, end: CGPoint,
                     curveControls: [CGPoint] = []) -> CGPath {
        let p = CGMutablePath()
        let r = rect.standardized
        switch kind {
        case .line:
            p.move(to: start); p.addLine(to: end)
        case .curve:
            p.move(to: start)
            if curveControls.count >= 2 {
                p.addCurve(to: end, control1: curveControls[0], control2: curveControls[1])
            } else if curveControls.count == 1 {
                p.addQuadCurve(to: end, control: curveControls[0])
            } else {
                p.addLine(to: end)
            }
        case .oval:
            p.addEllipse(in: r)
        case .rectangle:
            p.addRect(r)
        case .roundedRectangle:
            let rad = min(r.width, r.height) * 0.18
            p.addRoundedRect(in: r, cornerWidth: rad, cornerHeight: rad)
        case .polygon:
            // handled interactively by the canvas (multi-click); fallback: triangle
            fallthrough
        case .triangle:
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        case .rightTriangle:
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        case .diamond:
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.midY))
            p.closeSubpath()
        case .pentagon:
            addRegularPolygon(p, in: r, sides: 5)
        case .hexagon:
            addRegularPolygon(p, in: r, sides: 6)
        case .arrowRight:
            addArrow(p, in: r, rotationQuarter: 0)
        case .arrowLeft:
            addArrow(p, in: r, rotationQuarter: 2)
        case .arrowUp:
            addArrow(p, in: r, rotationQuarter: 3)
        case .arrowDown:
            addArrow(p, in: r, rotationQuarter: 1)
        case .star4:
            addStar(p, in: r, points: 4, innerRatio: 0.35)
        case .star5:
            addStar(p, in: r, points: 5, innerRatio: 0.45)
        case .star6:
            addStar(p, in: r, points: 6, innerRatio: 0.55)
        case .calloutRounded:
            addRoundedCallout(p, in: r)
        case .calloutOval:
            addOvalCallout(p, in: r)
        case .calloutCloud:
            addCloudCallout(p, in: r)
        case .heart:
            addHeart(p, in: r)
        case .lightning:
            addLightning(p, in: r)
        }
        return p
    }

    private static func addRegularPolygon(_ p: CGMutablePath, in r: CGRect, sides: Int) {
        let cx = r.midX, cy = r.midY
        let rx = r.width / 2, ry = r.height / 2
        for i in 0..<sides {
            let a = -CGFloat.pi / 2 + CGFloat(i) * 2 * .pi / CGFloat(sides)
            let pt = CGPoint(x: cx + rx * cos(a), y: cy + ry * sin(a))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        p.closeSubpath()
    }

    private static func addStar(_ p: CGMutablePath, in r: CGRect, points: Int, innerRatio: CGFloat) {
        let cx = r.midX, cy = r.midY
        let rx = r.width / 2, ry = r.height / 2
        for i in 0..<(points * 2) {
            let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / CGFloat(points)
            let k: CGFloat = i.isMultiple(of: 2) ? 1 : innerRatio
            let pt = CGPoint(x: cx + rx * k * cos(a), y: cy + ry * k * sin(a))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        p.closeSubpath()
    }

    /// Right-pointing block arrow, rotated by quarter turns inside `r`.
    private static func addArrow(_ p: CGMutablePath, in r: CGRect, rotationQuarter: Int) {
        // unit-space right arrow
        let pts: [CGPoint] = [
            CGPoint(x: 0, y: 0.30), CGPoint(x: 0.60, y: 0.30), CGPoint(x: 0.60, y: 0.0),
            CGPoint(x: 1.0, y: 0.5), CGPoint(x: 0.60, y: 1.0), CGPoint(x: 0.60, y: 0.70),
            CGPoint(x: 0, y: 0.70),
        ]
        let rot = pts.map { pt -> CGPoint in
            var u = pt
            for _ in 0..<(rotationQuarter % 4) {
                u = CGPoint(x: 1 - u.y, y: u.x)   // 90° clockwise in unit space
            }
            return u
        }
        let mapped = rot.map { CGPoint(x: r.minX + $0.x * r.width, y: r.minY + $0.y * r.height) }
        p.move(to: mapped[0])
        for pt in mapped.dropFirst() { p.addLine(to: pt) }
        p.closeSubpath()
    }

    /// Point on the ellipse inscribed in `rect`. y grows downward here, so
    /// `t == .pi / 2` is the bottom of the ellipse.
    private static func ellipsePoint(_ rect: CGRect, _ t: CGFloat) -> CGPoint {
        CGPoint(x: rect.midX + rect.width / 2 * cos(t),
                y: rect.midY + rect.height / 2 * sin(t))
    }

    // Callouts are built as ONE continuous outline. Drawing the body and the
    // tail as separate closed subpaths would stroke the tail's base straight
    // across the body, and would wall the tail off as its own region so that
    // filling the body could never reach it.

    private static func addOvalCallout(_ p: CGMutablePath, in r: CGRect) {
        let body = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.72)
        let tip = CGPoint(x: r.minX + r.width * 0.16, y: r.maxY)
        // The tail leaves the ellipse along its lower-left arc.
        let from: CGFloat = 155 * .pi / 180
        let to: CGFloat = 115 * .pi / 180

        p.move(to: ellipsePoint(body, from))
        // Sweep the long way round, leaving the from...to arc open for the tail.
        let end = to + 2 * .pi
        let step: CGFloat = 2 * .pi / 180
        var t = from
        while t < end {
            t = min(t + step, end)
            p.addLine(to: ellipsePoint(body, t))
        }
        p.addLine(to: tip)
        p.closeSubpath()
    }

    private static func addRoundedCallout(_ p: CGMutablePath, in r: CGRect) {
        let body = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.72)
        let rad = min(body.width, body.height) * 0.18
        let tip = CGPoint(x: r.minX + r.width * 0.14, y: r.maxY)
        // Where the tail meets the bottom edge, kept clear of the rounded corners.
        let left = min(max(r.minX + r.width * 0.22, body.minX + rad), body.maxX - rad)
        let right = min(max(r.minX + r.width * 0.40, left + 1), body.maxX - rad)

        p.move(to: CGPoint(x: body.minX + rad, y: body.minY))
        p.addLine(to: CGPoint(x: body.maxX - rad, y: body.minY))
        p.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY),
                 tangent2End: CGPoint(x: body.maxX, y: body.minY + rad), radius: rad)
        p.addLine(to: CGPoint(x: body.maxX, y: body.maxY - rad))
        p.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY),
                 tangent2End: CGPoint(x: body.maxX - rad, y: body.maxY), radius: rad)
        // along the bottom edge, detouring out to the tail tip and back
        p.addLine(to: CGPoint(x: right, y: body.maxY))
        p.addLine(to: tip)
        p.addLine(to: CGPoint(x: left, y: body.maxY))
        p.addLine(to: CGPoint(x: body.minX + rad, y: body.maxY))
        p.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY),
                 tangent2End: CGPoint(x: body.minX, y: body.maxY - rad), radius: rad)
        p.addLine(to: CGPoint(x: body.minX, y: body.minY + rad))
        p.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY),
                 tangent2End: CGPoint(x: body.minX + rad, y: body.minY), radius: rad)
        p.closeSubpath()
    }

    private static func addCloudCallout(_ p: CGMutablePath, in r: CGRect) {
        let body = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.72)
        addCloudOutline(p, in: body)
        // Paint trails a cloud callout with separate puffs rather than a solid
        // tail, so these are deliberately their own subpaths.
        let d = min(r.width, r.height)
        p.addEllipse(in: CGRect(x: r.minX + r.width * 0.26, y: r.minY + r.height * 0.74,
                                width: d * 0.11, height: d * 0.11))
        p.addEllipse(in: CGRect(x: r.minX + r.width * 0.18, y: r.minY + r.height * 0.87,
                                width: d * 0.07, height: d * 0.07))
    }

    /// A scalloped closed outline: points around an inset ellipse joined by
    /// curves that bulge outward. Overlapping circles would leave every internal
    /// arc visible and would fill one lobe at a time.
    private static func addCloudOutline(_ p: CGMutablePath, in rect: CGRect, bumps: Int = 11) {
        let inset = CGRect(x: rect.minX + rect.width * 0.09,
                           y: rect.minY + rect.height * 0.11,
                           width: rect.width * 0.82, height: rect.height * 0.78)
        let pts = (0..<bumps).map {
            ellipsePoint(inset, CGFloat($0) / CGFloat(bumps) * 2 * .pi)
        }
        let bulge = min(rect.width, rect.height) * 0.17
        p.move(to: pts[0])
        for i in 0..<bumps {
            let a = pts[i], b = pts[(i + 1) % bumps]
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let dx = mid.x - inset.midX, dy = mid.y - inset.midY
            let len = max(0.0001, hypot(dx, dy))
            p.addQuadCurve(to: b, control: CGPoint(x: mid.x + dx / len * bulge,
                                                   y: mid.y + dy / len * bulge))
        }
        p.closeSubpath()
    }

    private static func addHeart(_ p: CGMutablePath, in r: CGRect) {
        let w = r.width, h = r.height
        p.move(to: CGPoint(x: r.minX + w / 2, y: r.minY + h * 0.30))
        p.addCurve(to: CGPoint(x: r.minX, y: r.minY + h * 0.30),
                   control1: CGPoint(x: r.minX + w * 0.38, y: r.minY - h * 0.08),
                   control2: CGPoint(x: r.minX, y: r.minY + h * 0.02))
        p.addCurve(to: CGPoint(x: r.minX + w / 2, y: r.maxY),
                   control1: CGPoint(x: r.minX, y: r.minY + h * 0.62),
                   control2: CGPoint(x: r.minX + w * 0.32, y: r.minY + h * 0.78))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.minY + h * 0.30),
                   control1: CGPoint(x: r.minX + w * 0.68, y: r.minY + h * 0.78),
                   control2: CGPoint(x: r.maxX, y: r.minY + h * 0.62))
        p.addCurve(to: CGPoint(x: r.minX + w / 2, y: r.minY + h * 0.30),
                   control1: CGPoint(x: r.maxX, y: r.minY + h * 0.02),
                   control2: CGPoint(x: r.minX + w * 0.62, y: r.minY - h * 0.08))
        p.closeSubpath()
    }

    private static func addLightning(_ p: CGMutablePath, in r: CGRect) {
        let pts: [CGPoint] = [
            CGPoint(x: 0.42, y: 0.0), CGPoint(x: 0.80, y: 0.0), CGPoint(x: 0.55, y: 0.38),
            CGPoint(x: 0.78, y: 0.38), CGPoint(x: 0.28, y: 1.0), CGPoint(x: 0.42, y: 0.55),
            CGPoint(x: 0.20, y: 0.55),
        ].map { CGPoint(x: r.minX + $0.x * r.width, y: r.minY + $0.y * r.height) }
        p.move(to: pts[0])
        for pt in pts.dropFirst() { p.addLine(to: pt) }
        p.closeSubpath()
    }

    /// Small preview image for the shape gallery buttons.
    static func previewImage(for kind: ShapeKind, size: CGFloat = 18, color: NSColor = .labelColor) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let inset = rect.insetBy(dx: 2, dy: 2)
            let path = path(for: kind, in: inset,
                            start: CGPoint(x: inset.minX, y: inset.maxY),
                            end: CGPoint(x: inset.maxX, y: inset.minY),
                            curveControls: [CGPoint(x: inset.midX, y: inset.minY),
                                            CGPoint(x: inset.midX, y: inset.maxY)])
            ctx.addPath(path)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(1.4)
            ctx.setLineJoin(.round)
            ctx.strokePath()
            return true
        }
    }
}
