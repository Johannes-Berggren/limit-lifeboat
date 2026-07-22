// Renders the provider marks shown in the menu bar as monochrome (black on
// transparent) vector PDFs. They are drawn as template images at runtime, so the
// menu bar tints them to its own foreground color in light and dark appearances.
//
// These are custom single-color renditions, not the official brand binaries. To
// use the exact marks, drop replacement PDFs at the same paths — the loading code
// in DesignSystem.providerMarkImage is asset-agnostic.
//
// Usage: swift generate-provider-marks.swift [output-dir]
import AppKit

let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Sources/LimitLifeboat/Resources/ProviderMarks"

// A square viewBox keeps the marks optically centered in the attachment bounds.
let box: CGFloat = 100
let center = CGPoint(x: box / 2, y: box / 2)

func writePDF(named name: String, _ draw: (CGContext) -> Void) {
    let url = URL(fileURLWithPath: outputDir).appendingPathComponent("\(name).pdf")
    var mediaBox = CGRect(x: 0, y: 0, width: box, height: box)
    guard let consumer = CGDataConsumer(url: url as CFURL),
          let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
        FileHandle.standardError.write(Data("Failed to create PDF context for \(url.path)\n".utf8))
        exit(1)
    }
    ctx.beginPDFPage(nil)
    ctx.setFillColor(NSColor.black.cgColor)
    draw(ctx)
    ctx.endPDFPage()
    ctx.closePDF()
    print("Wrote \(url.path)")
}

func fill(_ path: NSBezierPath, in ctx: CGContext, evenOdd: Bool = false) {
    ctx.addPath(path.cgPath)
    if evenOdd {
        ctx.fillPath(using: .evenOdd)
    } else {
        ctx.fillPath()
    }
}

// Anthropic-style sunburst: tapered rays radiating from a small hub. An odd ray
// count gives the mark its characteristic asymmetry.
func sunburst(rayCount: Int, inner: CGFloat, outer: CGFloat, baseHalfWidthDegrees: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let half = baseHalfWidthDegrees * .pi / 180
    for i in 0..<rayCount {
        let angle = (CGFloat(i) / CGFloat(rayCount)) * 2 * .pi
        let tip = CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer)
        let b1 = CGPoint(x: center.x + cos(angle - half) * inner, y: center.y + sin(angle - half) * inner)
        let b2 = CGPoint(x: center.x + cos(angle + half) * inner, y: center.y + sin(angle + half) * inner)
        path.move(to: b1)
        path.line(to: tip)
        path.line(to: b2)
        path.close()
    }
    // A filled hub fuses the ray bases into one solid mark.
    path.appendOval(in: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
    return path
}

// OpenAI-style flower: rounded capsule petals in six-fold rotational symmetry.
func flower(petals: Int, inner: CGFloat, outer: CGFloat, width: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    for i in 0..<petals {
        let angle = (CGFloat(i) / CGFloat(petals)) * 2 * .pi
        let capsule = NSBezierPath(
            roundedRect: CGRect(x: -width / 2, y: inner, width: width, height: outer - inner),
            xRadius: width / 2,
            yRadius: width / 2
        )
        var transform = AffineTransform()
        transform.translate(x: center.x, y: center.y)
        transform.rotate(byRadians: Double(angle))
        capsule.transform(using: transform)
        path.append(capsule)
    }
    return path
}

writePDF(named: "claude") { ctx in
    fill(sunburst(rayCount: 11, inner: 15, outer: 46, baseHalfWidthDegrees: 9), in: ctx)
}

writePDF(named: "codex") { ctx in
    fill(flower(petals: 6, inner: 8, outer: 46, width: 22), in: ctx)
}
