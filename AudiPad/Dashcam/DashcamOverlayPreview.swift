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
        let height = size.height * 0.13
        return HStack {
            Text("AUDI · SQ5")
                .font(.system(size: height * 0.4, weight: .heavy))
                .tracking(2)
                .foregroundStyle(.white)
            Spacer()
            Text(clockFormatter.string(from: state.date))
                .font(.system(size: height * 0.4, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, height * 0.5)
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.55))
    }

    private func bottomStrip(state: DashcamOverlayRenderer.State,
                             in size: CGSize) -> some View {
        let height = size.height * 0.22
        return HStack(alignment: .top, spacing: 0) {
            overlayCell(label: "SPEED",
                        value: state.speedKph.map { String(format: "%.0f km/h", $0) } ?? "—",
                        height: height)
            overlayCell(label: "ROAD",
                        value: roadDisplay(state),
                        height: height)
            overlayCell(label: "G-FORCE",
                        value: gForceDisplay(state),
                        height: height)
            overlayCell(label: "GPS",
                        value: gpsDisplay(state),
                        height: height)
        }
        .padding(.horizontal, height * 0.3)
        .padding(.vertical, height * 0.18)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.55))
    }

    private func overlayCell(label: String, value: String, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: height * 0.16, weight: .heavy))
                .tracking(1.4)
                .foregroundStyle(.white.opacity(0.7))
            Text(value)
                .font(.system(size: height * 0.42, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
