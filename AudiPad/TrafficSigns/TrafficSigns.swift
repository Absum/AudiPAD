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

            ZStack {
                Circle()
                    .fill(.white)
                Circle()
                    .strokeBorder(
                        Color(red: 0.80, green: 0.10, blue: 0.18),
                        lineWidth: ringWidth
                    )
                Text("\(speed)")
                    .font(.system(size: side * 0.50, weight: .heavy, design: .default))
                    .foregroundStyle(.black)
                    .minimumScaleFactor(0.5)
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

            ZStack {
                Circle()
                    .fill(.white)
                Circle()
                    .strokeBorder(Color(white: 0.45), lineWidth: ringWidth)

                // Number, slightly dimmed
                Text("\(speed)")
                    .font(.system(size: side * 0.48, weight: .heavy))
                    .foregroundStyle(Color(white: 0.30))
                    .minimumScaleFactor(0.5)
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
                    EndOfSpeedLimitSign(speed: 80).frame(width: 100, height: 100)
                    YieldSign().frame(width: 100, height: 100)
                }
                RecentSignsStrip(signs: [.speedLimit(80), .speedLimit(50), .endOfSpeedLimit(50), .yield])
                    .padding(.horizontal)
            }
        }
        .frame(width: 700, height: 480)
        .previewLayout(.sizeThatFits)
    }
}
