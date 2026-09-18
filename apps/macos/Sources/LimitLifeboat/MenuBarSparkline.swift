import AppKit
import LimitLifeboatCore

/// Draws the optional memory graph beside the status-item lifebuoy. Pure and
/// static, like `MenuBarTitleFormatter`, so it can be tested without a menu bar.
enum MenuBarSparkline {
    static let graphSize = NSSize(width: 26, height: 12)
    static let gap: CGFloat = 4

    static func image(
        icon: NSImage?,
        trend: MemoryTrend,
        level: MemoryGuardLevel
    ) -> NSImage {
        let iconSize = icon?.size ?? .zero
        let graphX = iconSize.width > 0 ? iconSize.width + gap : 0
        let size = NSSize(
            width: graphX + graphSize.width,
            height: max(iconSize.height, graphSize.height)
        )

        let image = NSImage(size: size, flipped: false) { _ in
            icon?.draw(in: NSRect(
                x: 0,
                y: (size.height - iconSize.height) / 2,
                width: iconSize.width,
                height: iconSize.height
            ))
            drawGraph(
                samples: trend.samples,
                span: trend.displaySpan,
                color: color(for: level),
                in: NSRect(
                    x: graphX,
                    y: (size.height - graphSize.height) / 2,
                    width: graphSize.width,
                    height: graphSize.height
                )
            )
            return true
        }
        image.isTemplate = false
        return image
    }

    static func color(for level: MemoryGuardLevel) -> NSColor {
        switch level {
        case .ok:
            return .secondaryLabelColor
        case .caution:
            return .systemOrange
        case .critical:
            return .systemRed
        }
    }

    /// Graph-space points for the samples: x by age within `span`, y by the
    /// fixed 0...1 used fraction, so the line reads as level and trend at once.
    static func points(for samples: [MemoryTrendSample], span: TimeInterval, in rect: NSRect) -> [NSPoint] {
        guard let end = samples.last?.date else { return [] }
        // Inset so the stroke's half-width is not clipped at the edges.
        let plot = rect.insetBy(dx: 0.75, dy: 0.75)
        return samples.compactMap { sample in
            let age = end.timeIntervalSince(sample.date)
            guard age <= span else { return nil }
            return NSPoint(
                x: plot.maxX - CGFloat(age / span) * plot.width,
                y: plot.minY + CGFloat(sample.usedFraction) * plot.height
            )
        }
    }

    private static func drawGraph(
        samples: [MemoryTrendSample],
        span: TimeInterval,
        color: NSColor,
        in rect: NSRect
    ) {
        // A hairline floor keeps the graph's footprint visible before it fills.
        color.withAlphaComponent(0.25).setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 0.5).fill()

        var points = points(for: samples, span: span, in: rect)
        guard let last = points.last else { return }
        if points.count == 1 {
            points.insert(NSPoint(x: max(rect.minX, last.x - 1), y: last.y), at: 0)
        }

        let line = NSBezierPath()
        line.move(to: points[0])
        points.dropFirst().forEach(line.line(to:))

        let area = line.copy() as! NSBezierPath
        area.line(to: NSPoint(x: last.x, y: rect.minY))
        area.line(to: NSPoint(x: points[0].x, y: rect.minY))
        area.close()
        color.withAlphaComponent(0.18).setFill()
        area.fill()

        line.lineWidth = 1.25
        line.lineJoinStyle = .round
        line.lineCapStyle = .round
        color.setStroke()
        line.stroke()
    }
}
