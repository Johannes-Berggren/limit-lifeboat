// Renders the app icon: a Big Sur-style rounded rectangle with a gradient
// and a white gauge symbol. Run via scripts/generate-icon.sh; the resulting
// AppIcon.icns is committed so builds stay deterministic across macOS
// releases (SF Symbol rasterization varies between OS versions).
import AppKit

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let canvas: CGFloat = 1024

let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

// Big Sur icon grid: 824pt rounded rect centered on a 1024pt canvas.
let plateSize: CGFloat = 824
let plateOrigin = (canvas - plateSize) / 2
let plate = NSRect(x: plateOrigin, y: plateOrigin, width: plateSize, height: plateSize)
let platePath = NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185)

let gradient = NSGradient(
    colors: [
        NSColor(calibratedRed: 0.32, green: 0.20, blue: 0.71, alpha: 1.0),
        NSColor(calibratedRed: 0.12, green: 0.55, blue: 0.76, alpha: 1.0),
    ]
)
gradient?.draw(in: platePath, angle: -60)

// The outline variant keeps the needle and tick detail when tinted a single
// color; the .fill variant collapses into a plain disk.
let symbolName = "gauge.with.needle"
let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    ?? NSImage(systemSymbolName: "gauge", accessibilityDescription: nil)

if let symbol {
    let configuration = NSImage.SymbolConfiguration(pointSize: 560, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    if let configured = symbol.withSymbolConfiguration(configuration) {
        let aspect = configured.size.width / configured.size.height
        let targetHeight: CGFloat = 470
        let targetWidth = targetHeight * aspect
        let symbolRect = NSRect(
            x: (canvas - targetWidth) / 2,
            y: (canvas - targetHeight) / 2,
            width: targetWidth,
            height: targetHeight
        )
        configured.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }
}

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
