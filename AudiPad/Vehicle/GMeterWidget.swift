import SwiftUI

/// Classic ball-in-circle G-meter visualisation. Concentric grid
/// circles at 0.5 / 1.0 G, crosshair, fading trail of recent
/// samples, live dot. Renders at any size — the same view is used
/// for the compact Drive-tab cell and the full Racing-tab section.
struct GMeterWidget: View {
    let lateralG: Double
    let longitudinalG: Double
    let trail: [SIMD2<Double>]
    /// Scale of the outer ring in G. 1.5 G is a comfortable max — a
    /// road-legal car maxes around 1.0–1.2 G lateral; the headroom
    /// lets the dot move freely without slamming the rim.
    var maxG: Double = 1.5

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let radius = side / 2
            let center = CGPoint(x: radius, y: radius)

            ZStack {
                // Concentric grid — 0.5 G inner, 1.0 G mid, maxG outer.
                Circle()
                    .stroke(SQ5Colors.border, lineWidth: 1)
                    .frame(width: side, height: side)
                Circle()
                    .stroke(SQ5Colors.border.opacity(0.6), lineWidth: 1)
                    .frame(width: side * (1.0 / maxG), height: side * (1.0 / maxG))
                Circle()
                    .stroke(SQ5Colors.border.opacity(0.35), lineWidth: 1)
                    .frame(width: side * (0.5 / maxG), height: side * (0.5 / maxG))

                // Crosshair
                Path { p in
                    p.move(to: CGPoint(x: 0, y: radius))
                    p.addLine(to: CGPoint(x: side, y: radius))
                    p.move(to: CGPoint(x: radius, y: 0))
                    p.addLine(to: CGPoint(x: radius, y: side))
                }
                .stroke(SQ5Colors.border.opacity(0.4), lineWidth: 0.5)

                // Trail — older samples more transparent.
                ForEach(Array(trail.enumerated()), id: \.offset) { idx, sample in
                    let pos = position(for: sample, radius: radius, center: center)
                    let age = Double(idx) / Double(max(trail.count - 1, 1))
                    Circle()
                        .fill(SQ5Colors.accent.opacity(0.15 + age * 0.35))
                        .frame(width: 4 + age * 2, height: 4 + age * 2)
                        .position(pos)
                }

                // Live dot
                Circle()
                    .fill(dotColor)
                    .frame(width: 10, height: 10)
                    .shadow(color: dotColor.opacity(0.7), radius: 6)
                    .position(position(for: SIMD2(lateralG, longitudinalG),
                                       radius: radius, center: center))
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// Map a (lateralG, longitudinalG) pair to a CGPoint inside the
    /// circle. Lateral G drives X (right = positive), longitudinal G
    /// drives Y (forward acceleration = up on screen → -Y in CGPoint
    /// space). Clamps to the outer ring.
    private func position(for g: SIMD2<Double>,
                          radius: CGFloat,
                          center: CGPoint) -> CGPoint {
        let scaleX = CGFloat(g.x / maxG)
        let scaleY = CGFloat(g.y / maxG)
        let magnitude = sqrt(scaleX * scaleX + scaleY * scaleY)
        let factor = magnitude > 1 ? 1 / magnitude : 1
        return CGPoint(
            x: center.x + scaleX * radius * factor,
            y: center.y - scaleY * radius * factor
        )
    }

    /// Accent until ~0.8 G, warning amber 0.8–1.2 G, danger above
    /// (hard braking / aggressive cornering territory).
    private var dotColor: Color {
        let m = sqrt(lateralG * lateralG + longitudinalG * longitudinalG)
        if m >= 1.2 { return SQ5Colors.danger }
        if m >= 0.8 { return SQ5Colors.warning }
        return SQ5Colors.accent
    }
}
