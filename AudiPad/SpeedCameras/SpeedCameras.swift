import Foundation
import CoreLocation
import SwiftUI
import UIKit

// MARK: - Model

/// A single fixed/mobile/average-speed enforcement camera.
struct SpeedCamera: Identifiable, Hashable {
    enum Kind: String, Codable { case fixed, mobile, averageSpeed }

    let id: UUID
    let coordinate: CLLocationCoordinate2D
    let speedLimit: Int     // km/h
    let kind: Kind
    /// Direction the camera *faces*, in compass degrees (0° = N,
    /// clockwise). Source: OSM `direction` tag on the speed_camera
    /// node, when present. A camera that "faces south" (180°) watches
    /// traffic approaching from the south — i.e. catches drivers
    /// heading north. nil when OSM has no tag — coverage in Finland
    /// is maybe ~40% of cameras.
    let direction: Double?

    init(id: UUID = UUID(),
         latitude: Double,
         longitude: Double,
         speedLimit: Int,
         kind: Kind = .fixed,
         direction: Double? = nil) {
        self.id = id
        self.coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        self.speedLimit = speedLimit
        self.kind = kind
        self.direction = direction
    }

    // Equatable / Hashable manually since CLLocationCoordinate2D isn't Hashable.
    static func == (lhs: SpeedCamera, rhs: SpeedCamera) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Mock store

enum SpeedCameraStore {
    /// Mock Helsinki camera locations. Replaceable with a real data source
    /// (Väylävirasto open data, OSM Overpass `highway=speed_camera`, etc.).
    /// The first camera is placed close to the simulator's starting position
    /// so the alert visibly triggers on app launch for demo purposes.
    static let helsinki: [SpeedCamera] = [
        SpeedCamera(latitude: 60.1705, longitude: 24.9395, speedLimit: 50, kind: .fixed),       // ~70 m N of sim start
        SpeedCamera(latitude: 60.1830, longitude: 24.9540, speedLimit: 40, kind: .fixed),       // Hämeentie
        SpeedCamera(latitude: 60.1900, longitude: 24.9700, speedLimit: 60, kind: .averageSpeed),
        SpeedCamera(latitude: 60.1650, longitude: 24.9200, speedLimit: 50, kind: .fixed),
        SpeedCamera(latitude: 60.2050, longitude: 24.9100, speedLimit: 80, kind: .fixed),       // Ring road
        SpeedCamera(latitude: 60.1550, longitude: 24.9300, speedLimit: 50, kind: .mobile)
    ]
}

// MARK: - Monitor

@MainActor
final class SpeedCameraMonitor: ObservableObject {
    struct Approaching: Equatable {
        let camera: SpeedCamera
        let distanceMeters: CLLocationDistance
        /// The user's current speed in km/h at the moment this snapshot
        /// was produced. Used by the banner to render the over-limit
        /// state (red accent + "SLOW DOWN" headline + haptic).
        let userSpeedKph: Double
        /// The monitor's alert radius, carried along so the banner can
        /// render the distance progress bar (1.0 at the radius, 0 at
        /// the camera) without needing a reference to the monitor.
        let alertRadiusMeters: CLLocationDistance

        var isOverLimit: Bool {
            userSpeedKph > Double(camera.speedLimit)
        }

        /// Fraction of the alert radius still ahead of the user, in
        /// `[0, 1]`. Drives the depleting bar at the bottom of the banner.
        var distanceProgress: Double {
            guard alertRadiusMeters > 0 else { return 0 }
            return max(0, min(1, distanceMeters / alertRadiusMeters))
        }
    }

    /// Alert when within this many meters of any camera.
    let alertRadiusMeters: CLLocationDistance
    /// Below this user speed, no alerts (parked / very slow traffic).
    let minSpeedKph: Double
    /// User course must point within ±this many degrees of the
    /// bearing from user → camera. Keeps perpendicular roads quiet.
    let approachHalfConeDeg: Double
    /// When a camera has a `direction` tag, user's course must be
    /// within ±this many degrees of the opposite of the camera's
    /// facing (i.e. camera is set up to actually catch us). More
    /// generous than the approach cone because OSM angles are
    /// approximate and roads curve.
    let cameraFacingHalfConeDeg: Double

    @Published private(set) var nearestApproaching: Approaching?

    /// Once a camera passes the entry gates and becomes `nearestApproaching`,
    /// we keep showing it until distance > alertRadius — even after the user
    /// drives past (bearing flips → entry heading gate would suppress).
    /// Avoids both the "banner disappears the moment you pass" complaint and
    /// the "distance number flips between candidates" complaint.
    private var stickyCameraID: UUID?

    init(alertRadiusMeters: CLLocationDistance = 800,
         minSpeedKph: Double = 5,
         approachHalfConeDeg: Double = 45,
         cameraFacingHalfConeDeg: Double = 60) {
        self.alertRadiusMeters = alertRadiusMeters
        self.minSpeedKph = minSpeedKph
        self.approachHalfConeDeg = approachHalfConeDeg
        self.cameraFacingHalfConeDeg = cameraFacingHalfConeDeg
    }

    /// Update with the current camera list + the user's full CLLocation
    /// (we need speed + course, not just the coordinate). All gates
    /// must pass — distance, motion, heading-toward, optionally
    /// camera-facing, and same-road — for an alert to surface.
    ///
    /// `linkID` is an optional snapper closure (typically backed by
    /// `RoadSpeedLimitService.linkID(near:)`). When the user resolves
    /// to a link, we require the camera to also resolve and match. A
    /// camera that doesn't resolve is treated as "different road" —
    /// otherwise we'd silently bypass the gate every time a camera sits
    /// >30 m from any cached road vertex (parallel road, side street
    /// outside the bbox, OSM coord with pole offset, …) which produces
    /// the "alerting for the next road over" false-positive.
    ///
    /// When the *user* doesn't snap (no Digiroad coverage where they
    /// are), we skip the gate entirely and lean on heading + facing.
    func update(cameras: [SpeedCamera],
                userLocation loc: CLLocation,
                linkID: ((CLLocationCoordinate2D, Double?) -> String?)? = nil) {

        // Resolve the user's road link once. We pass the user's course so
        // the snap prefers segments aligned with the direction of travel —
        // critical at intersections where the nearest vertex might belong
        // to a perpendicular road.
        let userCourse: Double? = loc.course >= 0 ? loc.course : nil
        let userLinkId = linkID?(loc.coordinate, userCourse)
        // Live user speed in km/h, clamped (CLLocation.speed is m/s,
        // -1 when invalid). Carried into Approaching so the banner can
        // render the over-limit state without a separate plumbing path.
        let userSpeedKph = max(0, loc.speed) * 3.6

        // Sticky continuation: if we're already alerting a camera, keep
        // showing it (with the live distance) until one of:
        //   - we leave the alert radius,
        //   - the user moves to a different road,
        //   - the user drives past the camera (bearing flips behind us).
        // The first two avoid blinking out the moment you pass and avoid
        // a camera "following" you onto the parallel road. The third
        // prevents the "distance ticks up while I drive away from it"
        // bug — once the camera is behind us it's no longer a warning.
        if let stickyID = stickyCameraID,
           let stuck = cameras.first(where: { $0.id == stickyID }) {
            let camLoc = CLLocation(latitude: stuck.coordinate.latitude,
                                    longitude: stuck.coordinate.longitude)
            let dist = loc.distance(from: camLoc)
            let stillSameRoad = sameRoadAs(stuck, userLink: userLinkId, snap: linkID)
            // "Passed" = bearing from user→camera is now > 90° off the
            // user's course. The approach cone was ±45° on entry, so a
            // delta past 90° means the camera is to our side/rear, not
            // ahead. Skip the test when course is invalid (stopped /
            // momentarily lost lock) so a stale course doesn't dismiss.
            let passed: Bool = {
                guard loc.course >= 0 else { return false }
                let bearing = Self.bearing(from: loc.coordinate, to: stuck.coordinate)
                return Self.angularDelta(loc.course, bearing) > 90
            }()
            if dist <= alertRadiusMeters && stillSameRoad && !passed {
                let next = Approaching(camera: stuck,
                                       distanceMeters: dist,
                                       userSpeedKph: userSpeedKph,
                                       alertRadiusMeters: alertRadiusMeters)
                if next != nearestApproaching { nearestApproaching = next }
                return
            }
            // Out of radius, turned off the road, or driven past → drop
            // sticky and fall through to entry-gate evaluation for the
            // next camera.
            stickyCameraID = nil
        }

        // Entry gates — all must pass for a *new* camera to start alerting.

        // Speed gate. Reuses userSpeedKph computed above (CLLocation.speed
        // in m/s, -1 → 0 here).
        guard userSpeedKph >= minSpeedKph else {
            if nearestApproaching != nil { nearestApproaching = nil }
            return
        }
        // Course gate: invalid course means we don't know direction →
        // can't run the heading test, so don't alert (the user can't
        // be moving meaningfully with course = -1 anyway).
        guard loc.course >= 0 else {
            if nearestApproaching != nil { nearestApproaching = nil }
            return
        }
        let course = loc.course

        let nearest = cameras
            .compactMap { cam -> (SpeedCamera, CLLocationDistance)? in
                let camLoc = CLLocation(latitude: cam.coordinate.latitude,
                                        longitude: cam.coordinate.longitude)
                let dist = loc.distance(from: camLoc)
                guard dist <= alertRadiusMeters else { return nil }

                // Heading-toward: am I driving in the direction of
                // the camera? Bearing from me to it should match my
                // course to within the approach cone.
                let bearing = Self.bearing(from: loc.coordinate, to: cam.coordinate)
                guard Self.angularDelta(course, bearing) <= approachHalfConeDeg else {
                    return nil
                }

                // Camera-facing (only when we have direction data):
                // if the camera faces 180° (south), it monitors traffic
                // coming from the south driving north. So user's course
                // should match (camera.direction + 180) mod 360.
                if let camDir = cam.direction {
                    let camWatchesCourse = (camDir + 180).truncatingRemainder(dividingBy: 360)
                    guard Self.angularDelta(course, camWatchesCourse) <= cameraFacingHalfConeDeg else {
                        return nil
                    }
                }

                // Same-road gate — strict when the user has a known link.
                guard sameRoadAs(cam, userLink: userLinkId, snap: linkID) else {
                    return nil
                }

                return (cam, dist)
            }
            .min(by: { $0.1 < $1.1 })

        let next = nearest.map {
            Approaching(camera: $0.0,
                        distanceMeters: $0.1,
                        userSpeedKph: userSpeedKph,
                        alertRadiusMeters: alertRadiusMeters)
        }
        if next != nearestApproaching {
            nearestApproaching = next
        }
        // Engage stickiness as soon as a camera enters the alert state, so
        // the next .update keeps showing it past the heading flip.
        stickyCameraID = nearest?.0.id
    }

    /// Same-road gate. Strict when the user resolves to a Digiroad link:
    /// the camera must resolve to the same link. Permissive when the
    /// user doesn't resolve — areas outside Digiroad coverage fall back
    /// to heading + facing.
    private func sameRoadAs(_ cam: SpeedCamera,
                            userLink: String?,
                            snap: ((CLLocationCoordinate2D, Double?) -> String?)?) -> Bool {
        guard let snap, let userLink else { return true }
        // No course for the camera — it's a static point. We just want the
        // closest road by edge geometry.
        return snap(cam.coordinate, nil) == userLink
    }

    // MARK: - Geometry helpers

    /// Initial bearing from `from` to `to`, in compass degrees
    /// (0° = N, 90° = E). Standard great-circle formula.
    static func bearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Smallest positive angle between two compass bearings, in degrees.
    /// Always in `[0, 180]`.
    static func angularDelta(_ a: Double, _ b: Double) -> Double {
        let diff = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(diff, 360 - diff)
    }
}

// MARK: - Alert banner UI

/// Cross-cutting alert shown at the top of any tab when a speed camera is in range.
/// Mounted at the ContentView level (ZStack overlay above the tab content).
struct SpeedCameraAlertBanner: View {
    let approach: SpeedCameraMonitor.Approaching

    /// Color used for the icon background, border, and progress bar fill.
    /// Switches to red when the user is over the camera's limit so the
    /// banner reads as "do something now" rather than "FYI".
    private var accentColor: Color {
        approach.isOverLimit ? .red : SQ5Colors.accent
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(accentColor)
                    Image(systemName: kindSymbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.system(size: 10, weight: .heavy))
                        .tracking(2)
                        .foregroundStyle(approach.isOverLimit ? .red : SQ5Colors.textPrimary)
                    HStack(spacing: 6) {
                        Text("\(Int(approach.distanceMeters)) m")
                            .font(SQ5Typography.subtitle)
                            .foregroundStyle(SQ5Colors.textPrimary)
                            .monospacedDigit()
                        Text("·")
                            .foregroundStyle(SQ5Colors.textTertiary)
                        Text("\(approach.camera.speedLimit) km/h limit")
                            .font(SQ5Typography.subtitle)
                            .foregroundStyle(SQ5Colors.textSecondary)
                            .monospacedDigit()
                    }
                }

                Spacer(minLength: 12)

                // Small speed-limit sign at the trailing edge for instant glance
                TrafficSignView(sign: .speedLimit(approach.camera.speedLimit))
                    .frame(width: 38, height: 38)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Depleting distance bar — full at the alert radius, shrinks to
            // zero at the camera. Animates with the published distance
            // updates, giving the driver a glance-readable "how close am I"
            // signal that complements the numeric "X m".
            distanceBar
        }
        .background(SQ5Colors.surface.opacity(0.96))
        // Clipping the whole VStack to a rounded rect lets the bar at
        // the bottom inherit the corner curve — simpler than per-corner
        // rounding (which only exists from iOS 17 onward) and means the
        // border below traces both the text row and the bar.
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(accentColor, lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 3)
        .animation(.easeOut(duration: 0.3), value: approach.distanceProgress)
        .animation(.easeOut(duration: 0.2), value: approach.isOverLimit)
        // Single haptic at the moment the driver crosses from under to
        // over the limit. We deliberately don't fire on the reverse
        // transition (slowing back down is the correct response — no
        // need to nag) and don't loop while over (one tap, not a buzz).
        // iOS 16-compatible single-arg `onChange`.
        .onChange(of: approach.isOverLimit) { nowOver in
            guard nowOver else { return }
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        }
    }

    @ViewBuilder
    private var distanceBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(accentColor.opacity(0.18))
                Rectangle()
                    .fill(accentColor)
                    .frame(width: geo.size.width * approach.distanceProgress)
            }
        }
        .frame(height: 3)
    }

    private var headline: String {
        if approach.isOverLimit {
            return "SLOW DOWN — CAMERA AHEAD"
        }
        switch approach.camera.kind {
        case .fixed:         return "SPEED CAMERA AHEAD"
        case .mobile:        return "MOBILE CAMERA AHEAD"
        case .averageSpeed:  return "AVERAGE-SPEED ZONE AHEAD"
        }
    }

    private var kindSymbol: String {
        switch approach.camera.kind {
        case .fixed:         return "camera.fill"
        case .mobile:        return "car.2.fill"
        case .averageSpeed:  return "timer"
        }
    }
}
