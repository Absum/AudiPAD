import SwiftUI

// MARK: - Traffic sign types

/// Modeled types of traffic signs we currently render.
/// Add new cases here as we extend the mock set.
enum TrafficSign: Hashable {
    /// Round red-ring speed limit sign (e.g. 50 km/h).
    case speedLimit(Int)
    /// Round gray-ringed "end of speed limit" with diagonal strikethrough.
    case endOfSpeedLimit(Int)
    /// Inverted-triangle yield / give-way sign.
    case yield
    /// Red octagon STOP sign with inner white ring + "STOP" text.
    case stop
    /// Red circle with a horizontal white bar — no entry / no thoroughfare.
    case noEntry
    /// Upward red-ringed triangle warning of a speed bump / hump in the road.
    case speedBump
}

/// Dispatching renderer — give it a `TrafficSign` and it renders the matching shape.
/// All signs are designed to fit a square frame; pass `.frame(width:height:)` from the caller.
struct TrafficSignView: View {
    let sign: TrafficSign

    var body: some View {
        switch sign {
        case let .speedLimit(speed):
            SpeedLimitSign(speed: speed)
        case let .endOfSpeedLimit(speed):
            EndOfSpeedLimitSign(speed: speed)
        case .yield:
            YieldSign()
        case .stop:
            StopSign()
        case .noEntry:
            NoEntrySign()
        case .speedBump:
            SpeedBumpSign()
        }
    }
}

// MARK: - Speed limit (round, red ring, black number)

struct SpeedLimitSign: View {
    let speed: Int

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let ringWidth = side * 0.11
            // 3-digit speeds (100+) need a much smaller font so they fit
            // inside the red ring's inner diameter (~78% of side). 1-2 digit
            // signs sit comfortably at the same scale we use for the
            // 3-digit case + some breathing room.
            let fontScale: CGFloat = speed >= 100 ? 0.32 : 0.40

            ZStack {
                Circle()
                    .fill(.white)
                Circle()
                    .strokeBorder(
                        Color(red: 0.80, green: 0.10, blue: 0.18),
                        lineWidth: ringWidth
                    )
                Text("\(speed)")
                    .font(.system(size: side * fontScale, weight: .heavy, design: .default))
                    .foregroundStyle(.black)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .frame(width: side, height: side)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - End of speed limit (round, gray ring, diagonal strikethrough)

struct EndOfSpeedLimitSign: View {
    let speed: Int

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let ringWidth = side * 0.08
            let strikeWidth = side * 0.07
            // Same digit-aware sizing as the active speed-limit sign.
            let fontScale: CGFloat = speed >= 100 ? 0.30 : 0.38

            ZStack {
                Circle()
                    .fill(.white)
                Circle()
                    .strokeBorder(Color(white: 0.45), lineWidth: ringWidth)

                // Number, slightly dimmed
                Text("\(speed)")
                    .font(.system(size: side * fontScale, weight: .heavy))
                    .foregroundStyle(Color(white: 0.30))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)

                // Diagonal strikethrough (top-right to bottom-left)
                Path { p in
                    let inset: CGFloat = side * 0.12
                    p.move(to: CGPoint(x: side - inset, y: inset))
                    p.addLine(to: CGPoint(x: inset, y: side - inset))
                }
                .stroke(Color(white: 0.20), style: StrokeStyle(lineWidth: strikeWidth, lineCap: .round))
            }
            .frame(width: side, height: side)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Yield (inverted triangle, red ring, white interior)

struct YieldSign: View {
    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let ringWidth = side * 0.10

            ZStack {
                // Outer red triangle (provides the ring effect)
                InvertedTriangle()
                    .fill(Color(red: 0.80, green: 0.10, blue: 0.18))
                // Inner white triangle, inset for ring thickness
                InvertedTriangle()
                    .fill(.white)
                    .padding(ringWidth)
            }
            .frame(width: side, height: side)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private struct InvertedTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Stop (red octagon + white inner ring + STOP text)

struct StopSign: View {
    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let ringWidth = side * 0.045

            ZStack {
                Octagon()
                    .fill(Color(red: 0.80, green: 0.10, blue: 0.18))
                Octagon()
                    .stroke(.white, lineWidth: ringWidth)
                    .padding(ringWidth * 1.6)
                Text("STOP")
                    .font(.system(size: side * 0.30, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: side, height: side)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private struct Octagon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cx = rect.midX
        let cy = rect.midY
        let r = min(rect.width, rect.height) / 2
        // 8 vertices with a 22.5° rotation so flat sides are on top/bottom/sides.
        let offset: Double = .pi / 8
        for i in 0..<8 {
            let angle = (Double(i) * .pi * 2 / 8) - .pi / 2 + offset
            let x = cx + r * cos(angle)
            let y = cy + r * sin(angle)
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - No Entry (red circle + horizontal white bar)

struct NoEntrySign: View {
    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)

            ZStack {
                Circle()
                    .fill(Color(red: 0.80, green: 0.10, blue: 0.18))
                Capsule()
                    .fill(.white)
                    .frame(width: side * 0.66, height: side * 0.18)
            }
            .frame(width: side, height: side)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Speed Bump warning (upward red-ringed triangle + hump symbol)

struct SpeedBumpSign: View {
    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let ringWidth = side * 0.09

            ZStack {
                UpwardTriangle()
                    .fill(Color(red: 0.80, green: 0.10, blue: 0.18))
                UpwardTriangle()
                    .fill(.white)
                    .padding(ringWidth)
                BumpSymbol()
                    .stroke(.black, style: StrokeStyle(lineWidth: side * 0.045, lineCap: .round, lineJoin: .round))
                    .frame(width: side * 0.50, height: side * 0.18)
                    .offset(y: side * 0.10)
            }
            .frame(width: side, height: side)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private struct UpwardTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Slight inset for rounded corners
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

private struct BumpSymbol: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Two short ground lines flanking a hump in the middle.
        let baseY = rect.maxY
        let humpTopY = rect.minY
        let leftEnd = rect.minX + rect.width * 0.22
        let rightStart = rect.maxX - rect.width * 0.22

        p.move(to: CGPoint(x: rect.minX, y: baseY))
        p.addLine(to: CGPoint(x: leftEnd, y: baseY))
        p.addQuadCurve(
            to: CGPoint(x: rightStart, y: baseY),
            control: CGPoint(x: rect.midX, y: humpTopY - rect.height * 0.4)
        )
        p.addLine(to: CGPoint(x: rect.maxX, y: baseY))
        return p
    }
}

// MARK: - Helpers / convenience views

/// Small horizontal strip of recently detected signs.
/// Most-recent on the leading edge, dimmed history trailing.
struct RecentSignsStrip: View {
    /// Ordered most-recent first.
    let signs: [TrafficSign]
    var size: CGFloat = 48

    var body: some View {
        HStack(spacing: 10) {
            Text("RECENT")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(SQ5Colors.textTertiary)
                .padding(.trailing, 4)

            ForEach(Array(signs.prefix(4).enumerated()), id: \.offset) { idx, sign in
                TrafficSignView(sign: sign)
                    .frame(width: size, height: size)
                    .opacity(idx == 0 ? 1.0 : 0.55 - Double(idx) * 0.12)
            }
            Spacer()
        }
    }
}

// MARK: - Previews

struct TrafficSigns_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            SQ5Colors.background.ignoresSafeArea()
            VStack(spacing: 30) {
                HStack(spacing: 30) {
                    SpeedLimitSign(speed: 30).frame(width: 100, height: 100)
                    SpeedLimitSign(speed: 50).frame(width: 100, height: 100)
                    SpeedLimitSign(speed: 80).frame(width: 100, height: 100)
                    SpeedLimitSign(speed: 120).frame(width: 100, height: 100)
                }
                HStack(spacing: 30) {
                    EndOfSpeedLimitSign(speed: 50).frame(width: 100, height: 100)
                    YieldSign().frame(width: 100, height: 100)
                    StopSign().frame(width: 100, height: 100)
                    NoEntrySign().frame(width: 100, height: 100)
                    SpeedBumpSign().frame(width: 100, height: 100)
                }
                RecentSignsStrip(signs: [.speedLimit(80), .stop, .speedBump, .noEntry])
                    .padding(.horizontal)
            }
        }
        .frame(width: 800, height: 480)
        .previewLayout(.sizeThatFits)
    }
}
