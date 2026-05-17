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

    init(id: UUID = UUID(),
         latitude: Double,
         longitude: Double,
         speedLimit: Int,
         kind: Kind = .fixed) {
        self.id = id
        self.coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        self.speedLimit = speedLimit
        self.kind = kind
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

    @Published private(set) var nearestApproaching: Approaching?

    init(alertRadiusMeters: CLLocationDistance = 1000) {
        self.alertRadiusMeters = alertRadiusMeters
    }

    /// Update with the current camera list + vehicle location. Cameras
    /// are supplied per-call so we can swap data sources (mock list vs
    /// live OSM/Overpass) without re-wiring the monitor.
    func update(cameras: [SpeedCamera], vehicle coord: CLLocationCoordinate2D) {
        let here = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        let nearest = cameras
            .map { cam -> (SpeedCamera, CLLocationDistance) in
                let camLoc = CLLocation(latitude: cam.coordinate.latitude,
                                        longitude: cam.coordinate.longitude)
                return (cam, here.distance(from: camLoc))
            }
            .filter { $0.1 <= alertRadiusMeters }
            .min(by: { $0.1 < $1.1 })

        let next = nearest.map { Approaching(camera: $0.0, distanceMeters: $0.1) }
        if next != nearestApproaching {
            nearestApproaching = next
        }
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
