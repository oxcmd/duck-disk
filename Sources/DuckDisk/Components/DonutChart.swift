import SwiftUI

struct DonutSegment: Identifiable {
    let id: String
    let value: Double
    let color: Color
}

/// Ring chart with small gaps between segments; tiny segments get a minimum visible arc.
struct DonutChart: View {
    let segments: [DonutSegment]
    var lineWidth: CGFloat = 30
    var gapDegrees: Double = 1.4
    var minDegrees: Double = 2.2

    var body: some View {
        Canvas { ctx, size in
            let radius = min(size.width, size.height) / 2 - lineWidth / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let visible = segments.filter { $0.value > 0 }
            let total = visible.reduce(0) { $0 + $1.value }
            guard total > 0 else {
                var ring = Path()
                ring.addArc(center: center, radius: radius, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                ctx.stroke(ring, with: .color(Theme.track), lineWidth: lineWidth)
                return
            }
            let gaps = visible.count > 1 ? gapDegrees * Double(visible.count) : 0
            // Give tiny segments a minimum sweep, taking the room from the large ones.
            var sweeps = visible.map { 360 * $0.value / total }
            let boosted = sweeps.indices.filter { sweeps[$0] < minDegrees }
            let extra = boosted.reduce(0) { $0 + (minDegrees - sweeps[$1]) }
            let largeTotal = sweeps.indices.filter { !boosted.contains($0) }.reduce(0) { $0 + sweeps[$1] }
            for i in sweeps.indices {
                if boosted.contains(i) { sweeps[i] = minDegrees }
                else if largeTotal > 0 { sweeps[i] -= extra * sweeps[i] / largeTotal }
            }
            let scale = (360 - gaps) / sweeps.reduce(0, +)
            var angle = -90.0
            for (i, seg) in visible.enumerated() {
                let sweep = sweeps[i] * scale
                var arc = Path()
                arc.addArc(center: center, radius: radius, startAngle: .degrees(angle),
                           endAngle: .degrees(angle + sweep), clockwise: false)
                ctx.stroke(arc, with: .color(seg.color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                angle += sweep + (visible.count > 1 ? gapDegrees : 0)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Disk usage chart")
    }
}

/// Rotating partial ring shown while scanning.
struct ScanningRing: View {
    var lineWidth: CGFloat = 30
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: 0.22)
                .stroke(AngularGradient(colors: [Theme.color(.downloads).opacity(0), Theme.color(.developer),
                                                 Theme.color(.leftovers)], center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 1.4).repeatForever(autoreverses: false), value: spin)
        }
        .padding(lineWidth / 2)
        .onAppear { spin = true }
    }
}
