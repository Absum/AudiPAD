import Foundation
import CoreLocation
import SwiftUI

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

    init(alertRadiusMeters: CLLocationDistance = 1000,
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
    /// camera-facing, and optionally same-road — for an alert to
    /// surface.
    ///
    /// `linkID` is an optional snapper closure (typically backed by
    /// `RoadSpeedLimitService.linkID(near:)`). When both user and
    /// camera resolve to non-nil link IDs and they differ, the camera
    /// is suppressed. If either snap is nil (no Digiroad data near
    /// that point) we don't penalize — heading + facing carry the load.
    func update(cameras: [SpeedCamera],
                userLocation loc: CLLocation,
                linkID: ((CLLocationCoordinate2D) -> String?)? = nil) {
        // Speed gate. CLLocation.speed is m/s; -1 when invalid.
        let speedKph = max(0, loc.speed) * 3.6
        guard speedKph >= minSpeedKph else {
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

        // Resolve the user's road link once (instead of per-camera). nil
        // means "no Digiroad data within snap radius" — same-road gate
        // is skipped entirely in that case.
        let userLinkId = linkID?(loc.coordinate)

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

                // Same-road via Digiroad link snap. Only enforced when
                // both ends resolve — missing data must not silence
                // legitimate alerts on roads outside the cached bbox.
                if let snap = linkID,
                   let userLink = userLinkId,
                   let camLink = snap(cam.coordinate),
                   userLink != camLink {
                    return nil
                }

                return (cam, dist)
            }
            .min(by: { $0.1 < $1.1 })

        let next = nearest.map { Approaching(camera: $0.0, distanceMeters: $0.1) }
        if next != nearestApproaching {
            nearestApproaching = next
        }
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

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(SQ5Colors.accent)
                Image(systemName: kindSymbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(SQ5Colors.textPrimary)
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
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(SQ5Colors.surface.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(SQ5Colors.accent, lineWidth: 1.5)
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 3)
    }

    private var headline: String {
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
