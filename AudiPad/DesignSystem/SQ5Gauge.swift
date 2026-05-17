import SwiftUI

/// Circular arc gauge with tick marks, active-fill, optional redline, and centered digital readout.
/// 270° sweep, gap at the bottom (between ~5 and ~7 o'clock).
struct SQ5Gauge: View {
    let value: Double
    let minValue: Double
    let maxValue: Double
    let label: String
    let unit: String?
    var redlineStart: Double? = nil
    var majorStep: Double? = nil
    var minorBetween: Int = 4
    var formatter: (Double) -> String = { v in
        if v >= 1000 {
            return v.formatted(.number.precision(.fractionLength(0)).grouping(.automatic))
        }
        return String(Int(v.rounded()))
    }

    private var progress: Double {
        let clamped = max(minValue, min(maxValue, value))
        let range = maxValue - minValue
        return range > 0 ? (clamped - minValue) / range : 0
    }

    private var redlineProgress: Double? {
        redlineStart.map { (max(minValue, min(maxValue, $0)) - minValue) / (maxValue - minValue) }
    }

    private var activeArcColor: Color {
        if let rs = redlineStart, value >= rs {
            return SQ5Colors.accent
        }
        return SQ5Colors.textPrimary
    }

    private var resolvedMajorStep: Double {
        if let s = majorStep { return s }
        let range = maxValue - minValue
        if range >= 6000 { return 1000 }
        if range >= 1000 { return 500 }
        if range >= 200 { return 20 }
        if range >= 100 { return 10 }
        return 10
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let strokeWidth = side * 0.035
            let arcDiameter = side * 0.86

            ZStack {
                // Background arc
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(SQ5Colors.border,
                            style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .frame(width: arcDiameter, height: arcDiameter)

                // Redline section (faint, on the background)
                if let rp = redlineProgress {
                    Circle()
                        .trim(from: 0.75 * rp, to: 0.75)
                        .stroke(SQ5Colors.accent.opacity(0.35),
                                style: StrokeStyle(lineWidth: strokeWidth, lineCap: .butt))
                        .rotationEffect(.degrees(135))
                        .frame(width: arcDiameter, height: arcDiameter)
                }

                // Active progress arc — animates fill and color crossfade to accent
                // when crossing the redline. Sharp (butt) tip for a precise
                // "needle" feel; round caps read as soft / imprecise.
                Circle()
                    .trim(from: 0, to: 0.75 * progress)
                    .stroke(activeArcColor,
                            style: StrokeStyle(lineWidth: strokeWidth, lineCap: .butt))
                    .rotationEffect(.degrees(135))
                    .frame(width: arcDiameter, height: arcDiameter)
                    .animation(.easeOut(duration: 0.4), value: progress)
                    .animation(.easeInOut(duration: 0.25), value: activeArcColor)

                // Tick marks
                TickMarks(majorCount: Int(((maxValue - minValue) / resolvedMajorStep).rounded()),
                          minorBetween: minorBetween,
                          diameter: arcDiameter + strokeWidth * 2)

                // Center readout — value morphs between numerics instead of snapping.
                VStack(spacing: side * 0.012) {
                    Text(formatter(value))
                        .font(.system(size: side * 0.24, weight: .light, design: .default))
                        .foregroundStyle(SQ5Colors.textPrimary)
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.35), value: value)
                    if let unit {
                        Text(unit)
                            .font(.system(size: side * 0.07, weight: .medium))
                            .foregroundStyle(SQ5Colors.textSecondary)
                    }
                    Text(label.uppercased())
                        .font(.system(size: side * 0.055, weight: .medium))
                        .tracking(2.5)
                        .foregroundStyle(SQ5Colors.textTertiary)
                        .padding(.top, side * 0.015)
                }
                .frame(width: arcDiameter * 0.72)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private struct TickMarks: View {
    let majorCount: Int
    let minorBetween: Int
    let diameter: CGFloat

    var body: some View {
        Canvas { ctx, canvasSize in
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let outerR = diameter / 2
            let totalTicks = max(1, majorCount * (minorBetween + 1))

            // Match the arc's geometry: 270° sweep starting at 135° going clockwise visually.
            // SwiftUI screen coords have +X right and +Y down, with addArc/sin/cos using
            // angles where positive = clockwise visually. We feed the same angle convention.
            let sweepDeg: Double = 270
            let startDeg: Double = 135

            for i in 0...totalTicks {
                let progress = Double(i) / Double(totalTicks)
                let angleDeg = startDeg + sweepDeg * progress
                let angleRad = angleDeg * .pi / 180

                let isMajor = i % (minorBetween + 1) == 0
                let innerR = outerR * (isMajor ? 0.85 : 0.92)
                let lineWidth: CGFloat = isMajor ? 2 : 1
                let tickColor: Color = isMajor ? SQ5Colors.textSecondary : SQ5Colors.textTertiary

                let x1 = center.x + outerR * cos(angleRad)
                let y1 = center.y + outerR * sin(angleRad)
                let x2 = center.x + innerR * cos(angleRad)
                let y2 = center.y + innerR * sin(angleRad)

                var path = Path()
                path.move(to: CGPoint(x: x1, y: y1))
                path.addLine(to: CGPoint(x: x2, y: y2))
                ctx.stroke(path, with: .color(tickColor), lineWidth: lineWidth)
            }
        }
        .frame(width: diameter + 24, height: diameter + 24)
        .allowsHitTesting(false)
    }
}

struct SQ5Gauge_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            SQ5Colors.background.ignoresSafeArea()
            HStack(spacing: 24) {
                SQ5Gauge(value: 87, minValue: 0, maxValue: 240,
                         label: "Speed", unit: "km/h", majorStep: 20)
                SQ5Gauge(value: 2400, minValue: 0, maxValue: 7000,
                         label: "RPM", unit: nil, redlineStart: 4500, majorStep: 1000)
            }
            .padding(40)
        }
        .frame(width: 900, height: 480)
        .previewLayout(.sizeThatFits)
    }
}
