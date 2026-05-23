import SwiftUI
import CoreLocation

/// SwiftUI sibling of `DashcamOverlayRenderer` — renders the same
/// top + bottom strips (logo · clock; speed · road · G-force · GPS)
/// in SwiftUI so the Settings preview shows EXACTLY what's burned
/// into the recorded mp4. Pulls live data from the same services
/// the burned-in overlay reads.
///
/// Sizes are expressed as fractions of the available space so the
/// strips scale to whatever frame the preview occupies — keeps the
/// preview visually faithful to the recorded file at any zoom.
struct DashcamOverlayPreview: View {
    @EnvironmentObject private var location: LocationService
    @EnvironmentObject private var roadLimits: RoadSpeedLimitService
    @EnvironmentObject private var motion: MotionService

    var body: some View {
        GeometryReader { geo in
            // 1 Hz tick so the clock advances + speed/road/G are
            // re-read from the services (which are @Published; any
            // change re-renders this view independently anyway —
            // the TimelineView just covers the clock).
            TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
                let state = currentState(now: ctx.date)
                ZStack(alignment: .top) {
                    topStrip(state: state, in: geo.size)
                    VStack {
                        Spacer()
                        bottomStrip(state: state, in: geo.size)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Strips

    private func topStrip(state: DashcamOverlayRenderer.State,
                          in size: CGSize) -> some View {
        let titleSize = size.height * 0.05
        return HStack {
            Text("AUDI SQ5")
                .font(.system(size: titleSize, weight: .heavy))
                .tracking(1.2)
                .foregroundStyle(.white)
            Spacer()
            Text(clockFormatter.string(from: state.date))
                .font(.system(size: titleSize, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, titleSize)
        .padding(.vertical, titleSize * 0.35)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.55))
    }

    private func bottomStrip(state: DashcamOverlayRenderer.State,
                             in size: CGSize) -> some View {
        // Body row ≈ 2/3 of the top-title size, one-liner format
        // ("SPEED 87 km/h  ·  ROAD …  ·  G-FORCE …  ·  GPS …").
        let bodySize = size.height * 0.033
        let labelColor = Color.white.opacity(0.6)
        let sepColor = Color.white.opacity(0.35)
        return HStack(spacing: 0) {
            inlinePair(label: "SPEED",
                       value: state.speedKph.map { String(format: "%.0f km/h", $0) } ?? "—",
                       size: bodySize, labelColor: labelColor)
            inlineSeparator(size: bodySize, color: sepColor)
            inlinePair(label: "ROAD",
                       value: roadDisplay(state),
                       size: bodySize, labelColor: labelColor)
            inlineSeparator(size: bodySize, color: sepColor)
            inlinePair(label: "G-FORCE",
                       value: gForceDisplay(state),
                       size: bodySize, labelColor: labelColor)
            inlineSeparator(size: bodySize, color: sepColor)
            inlinePair(label: "GPS",
                       value: gpsDisplay(state),
                       size: bodySize, labelColor: labelColor)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, bodySize * 1.5)
        .padding(.vertical, bodySize * 0.5)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.55))
        .lineLimit(1)
    }

    private func inlinePair(label: String, value: String, size: CGFloat,
                            labelColor: Color) -> some View {
        HStack(spacing: size * 0.35) {
            Text(label)
                .font(.system(size: size, weight: .heavy))
                .tracking(1.2)
                .foregroundStyle(labelColor)
            Text(value)
                .font(.system(size: size, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .lineLimit(1)
    }

    private func inlineSeparator(size: CGFloat, color: Color) -> some View {
        Text("·")
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(color)
            .padding(.horizontal, size * 0.6)
    }

    // MARK: - Helpers (mirror DashcamOverlayRenderer's formatting)

    private func currentState(now: Date) -> DashcamOverlayRenderer.State {
        let loc = location.location
        let road = roadLimits.currentRoad
        return DashcamOverlayRenderer.State(
            date: now,
            speedKph: loc.flatMap { $0.speed >= 0 ? $0.speed * 3.6 : nil },
            roadName: road?.name,
            roadRef: road?.ref,
            lateralG: motion.currentLateralG,
            longitudinalG: motion.currentLongitudinalG,
            coordinate: loc?.coordinate
        )
    }

    private func roadDisplay(_ state: DashcamOverlayRenderer.State) -> String {
        if let name = state.roadName, !name.isEmpty {
            if let ref = state.roadRef, !ref.isEmpty {
                return "\(name) (\(ref))"
            }
            return name
        }
        if let ref = state.roadRef, !ref.isEmpty { return ref }
        return "—"
    }

    private func gForceDisplay(_ state: DashcamOverlayRenderer.State) -> String {
        guard let lat = state.lateralG, let lon = state.longitudinalG else { return "—" }
        let mag = sqrt(lat * lat + lon * lon)
        return String(format: "%.2f g", mag)
    }

    private func gpsDisplay(_ state: DashcamOverlayRenderer.State) -> String {
        guard let c = state.coordinate else { return "—" }
        return String(format: "%.4f, %.4f", c.latitude, c.longitude)
    }

    private let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd  HH:mm:ss"
        return f
    }()
}
