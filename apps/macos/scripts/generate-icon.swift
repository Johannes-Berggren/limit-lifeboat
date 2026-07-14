// Renders a deterministic app icon from AppKit vector primitives. The white
// lifebuoy doubles as a usage gauge, while the plate keeps the product's
// purple-to-cyan palette. No SF Symbols or external assets are used.
import AppKit

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let canvas: CGFloat = 1024
let center = NSPoint(x: canvas / 2, y: canvas / 2)

func rotated(_ path: NSBezierPath, around point: NSPoint, degrees: CGFloat) -> NSBezierPath {
    let result = path.copy() as! NSBezierPath
    var transform = AffineTransform()
    transform.translate(x: point.x, y: point.y)
    transform.rotate(byDegrees: degrees)
    transform.translate(x: -point.x, y: -point.y)
    result.transform(using: transform)
    return result
}

func point(onRadius radius: CGFloat, degrees: CGFloat) -> NSPoint {
    let radians = degrees * .pi / 180
    return NSPoint(
        x: center.x + cos(radians) * radius,
        y: center.y + sin(radians) * radius
    )
}

let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high

// Big Sur icon grid: an 824pt rounded plate centered on a transparent canvas.
let plateSize: CGFloat = 824
let plateOrigin = (canvas - plateSize) / 2
let plate = NSRect(x: plateOrigin, y: plateOrigin, width: plateSize, height: plateSize)
let platePath = NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185)
let plateGradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.32, green: 0.20, blue: 0.71, alpha: 1),
    NSColor(calibratedRed: 0.12, green: 0.55, blue: 0.76, alpha: 1),
])
plateGradient?.draw(in: platePath, angle: -60)

NSColor.white.withAlphaComponent(0.14).setStroke()
platePath.lineWidth = 6
platePath.stroke()

// A thick ring and four diagonal bands form the lifebuoy silhouette.
let outerRadius: CGFloat = 252
let innerRadius: CGFloat = 150
let outerRect = NSRect(
    x: center.x - outerRadius,
    y: center.y - outerRadius,
    width: outerRadius * 2,
    height: outerRadius * 2
)
let innerRect = NSRect(
    x: center.x - innerRadius,
    y: center.y - innerRadius,
    width: innerRadius * 2,
    height: innerRadius * 2
)
let ring = NSBezierPath()
ring.appendOval(in: outerRect)
ring.appendOval(in: innerRect)
ring.windingRule = .evenOdd

NSGraphicsContext.saveGraphicsState()
let symbolShadow = NSShadow()
symbolShadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
symbolShadow.shadowBlurRadius = 18
symbolShadow.shadowOffset = NSSize(width: 0, height: -10)
symbolShadow.set()
NSColor.white.withAlphaComponent(0.97).setFill()
ring.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
ring.addClip()
let bandColor = NSColor(calibratedRed: 0.18, green: 0.34, blue: 0.67, alpha: 1)
bandColor.setFill()
let band = NSBezierPath(
    roundedRect: NSRect(
        x: center.x - 51,
        y: center.y + innerRadius - 22,
        width: 102,
        height: outerRadius - innerRadius + 44
    ),
    xRadius: 28,
    yRadius: 28
)
for angle: CGFloat in [45, 135, 225, 315] {
    rotated(band, around: center, degrees: angle).fill()
}
NSGraphicsContext.restoreGraphicsState()

// Crisp circular edges keep the ring legible at menu-bar icon sizes.
NSColor.white.withAlphaComponent(0.78).setStroke()
let outerEdge = NSBezierPath(ovalIn: outerRect)
outerEdge.lineWidth = 9
outerEdge.stroke()
let innerEdge = NSBezierPath(ovalIn: innerRect)
innerEdge.lineWidth = 9
innerEdge.stroke()

// The lifebuoy's center is a compact usage gauge with fixed vector geometry.
let gaugeRadius: CGFloat = 112
let gauge = NSBezierPath()
gauge.appendArc(
    withCenter: center,
    radius: gaugeRadius,
    startAngle: 205,
    endAngle: -25,
    clockwise: true
)
gauge.lineWidth = 21
gauge.lineCapStyle = .round
NSColor.white.withAlphaComponent(0.94).setStroke()
gauge.stroke()

for angle: CGFloat in [205, 147.5, 90, 32.5, -25] {
    let tickCenter = point(onRadius: gaugeRadius, degrees: angle)
    let tick = NSBezierPath(ovalIn: NSRect(
        x: tickCenter.x - 8,
        y: tickCenter.y - 8,
        width: 16,
        height: 16
    ))
    NSColor.white.setFill()
    tick.fill()
}

let needleTip = point(onRadius: 92, degrees: 42)
let needle = NSBezierPath()
needle.move(to: center)
needle.line(to: needleTip)
needle.lineWidth = 25
needle.lineCapStyle = .round
NSColor.white.setStroke()
needle.stroke()

let hub = NSBezierPath(ovalIn: NSRect(
    x: center.x - 24,
    y: center.y - 24,
    width: 48,
    height: 48
))
NSColor.white.setFill()
hub.fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("Failed to render icon PNG\n".utf8))
    exit(1)
}

do {
    try png.write(to: URL(fileURLWithPath: outputPath))
    print("Wrote \(outputPath)")
} catch {
    FileHandle.standardError.write(Data("Failed to write \(outputPath): \(error)\n".utf8))
    exit(1)
}
