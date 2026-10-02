import LimitLifeboatCore
import SwiftUI

/// A gauge track drawn as the window's own timeline: the usage curve so far,
/// a dashed line along the current pace, and — when the pace runs the quota
/// dry before the reset — a quiet red stretch for the time left with nothing.
struct RunwayTrack: View {
    let runway: UsageRunway
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reveal: CGFloat = 0

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .mask(alignment: .leading) {
            GeometryReader { proxy in
                Rectangle().frame(width: proxy.size.width * reveal)
            }
        }
        .onAppear {
            guard !reduceMotion else {
                reveal = 1
                return
            }
            withAnimation(.easeOut(duration: 0.7)) { reveal = 1 }
        }
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        let track = Path(roundedRect: rect, cornerRadius: DS.Gauge.runwayRadius, style: .continuous)
        context.fill(track, with: .color(.primary.opacity(0.055)))
        context.clip(to: track)

        // Keep the line's stroke inside the track at 0% and 100%.
        let inset: CGFloat = 1.5
        let plot = rect.insetBy(dx: 0, dy: inset)
        func point(_ p: UsageRunway.Point) -> CGPoint {
            CGPoint(x: plot.minX + plot.width * p.x, y: plot.maxY - plot.height * p.y)
        }

        if let dryStart = runway.dryStart {
            let x = plot.width * dryStart
            let band = CGRect(x: x, y: 0, width: size.width - x, height: size.height)
            context.fill(Path(band), with: .color(DS.danger.opacity(0.13)))
            var edge = Path()
            edge.move(to: CGPoint(x: x, y: 0))
            edge.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(edge, with: .color(DS.danger.opacity(0.55)), lineWidth: 1)
        }

        let points = runway.history.map(point)
        guard let first = points.first, let last = points.last else {
            return
        }

        let line = Self.monotonePath(through: points)
        var area = line
        area.addLine(to: CGPoint(x: last.x, y: size.height))
        area.addLine(to: CGPoint(x: first.x, y: size.height))
        area.closeSubpath()
        context.fill(
            area,
            with: .linearGradient(
                Gradient(colors: [tint.opacity(0.30), tint.opacity(0.04)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )

        if let end = runway.projectionEnd {
            var projection = Path()
            projection.move(to: last)
            projection.addLine(to: point(end))
            context.stroke(
                projection,
                with: .color((runway.dryStart == nil ? tint : DS.danger).opacity(0.6)),
                style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 2.5])
            )
        }

        context.stroke(
            line,
            with: .color(tint),
            style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round)
        )

        let dot = CGRect(x: last.x - 2.25, y: last.y - 2.25, width: 4.5, height: 4.5)
        context.fill(Path(ellipseIn: dot), with: .color(tint))
    }

    /// Fritsch–Carlson monotone cubic: smooth, but never overshoots, so a flat
    /// stretch stays flat and the curve never dips below a reading it passed.
    static func monotonePath(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else {
            return path
        }
        path.move(to: first)
        guard points.count > 2 else {
            points.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }

        let n = points.count
        var slopes = [CGFloat](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let dx = points[i + 1].x - points[i].x
            slopes[i] = dx == 0 ? 0 : (points[i + 1].y - points[i].y) / dx
        }
        var tangents = [CGFloat](repeating: 0, count: n)
        tangents[0] = slopes[0]
        tangents[n - 1] = slopes[n - 2]
        for i in 1..<(n - 1) {
            tangents[i] = slopes[i - 1] * slopes[i] <= 0 ? 0 : (slopes[i - 1] + slopes[i]) / 2
        }
        for i in 0..<(n - 1) where slopes[i] == 0 {
            tangents[i] = 0
            tangents[i + 1] = 0
        }
        for i in 0..<(n - 1) where slopes[i] != 0 {
            let a = tangents[i] / slopes[i]
            let b = tangents[i + 1] / slopes[i]
            let h = a * a + b * b
            if h > 9 {
                let t = 3 / h.squareRoot()
                tangents[i] = t * a * slopes[i]
                tangents[i + 1] = t * b * slopes[i]
            }
        }
        for i in 0..<(n - 1) {
            let p0 = points[i]
            let p1 = points[i + 1]
            let dx = (p1.x - p0.x) / 3
            path.addCurve(
                to: p1,
                control1: CGPoint(x: p0.x + dx, y: p0.y + tangents[i] * dx),
                control2: CGPoint(x: p1.x - dx, y: p1.y - tangents[i + 1] * dx)
            )
        }
        return path
    }
}
