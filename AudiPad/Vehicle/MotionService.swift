import Foundation
import CoreMotion
import SwiftUI

/// CoreMotion wrapper that publishes the iPad's in-plane lateral +
/// longitudinal acceleration as G-forces, plus session peaks that
/// persist across launches (matching the "thrills memory" pattern
/// from `RacingService.topSpeedRecord`).
///
/// Mounting assumption: iPad is mounted in landscape on the
/// dashboard, screen facing the driver. The two horizontal device-
/// frame axes (X = device's portrait-right, Y = device's portrait-
/// up) become the in-plane lateral/longitudinal axes in the
/// dashboard. A `calibrate()` action captures the current rest
/// reading as zero so a slightly tilted mount doesn't permanently
/// pin the dot off-centre.
@MainActor
final class MotionService: ObservableObject {

    @Published private(set) var currentLateralG: Double = 0
    @Published private(set) var currentLongitudinalG: Double = 0
    @Published private(set) var peakLateralG: Double = 0
    @Published private(set) var peakLongitudinalG: Double = 0
    @Published private(set) var peakCombinedG: Double = 0

    /// Most-recent ~12 raw (lateral, longitudinal) samples for the
    /// fading trail in the G-meter widget.
    @Published private(set) var trail: [SIMD2<Double>] = []

    private let manager = CMMotionManager()
    private static let updateHz: Double = 30
    private static let trailMaxSamples = 12

    private static let peakLateralKey      = "audipad.motion.peakLateral"
    private static let peakLongitudinalKey = "audipad.motion.peakLongitudinal"
    private static let peakCombinedKey     = "audipad.motion.peakCombined"
    private static let calibrationXKey     = "audipad.motion.calibrationX"
    private static let calibrationYKey     = "audipad.motion.calibrationY"

    /// Per-axis offsets subtracted from raw device acceleration to
    /// produce calibrated lateral/longitudinal G. Persisted so the
    /// user only calibrates once per mount.
    private var calibrationX: Double = 0
    private var calibrationY: Double = 0

    init() {
        let d = UserDefaults.standard
        peakLateralG      = d.double(forKey: Self.peakLateralKey)
        peakLongitudinalG = d.double(forKey: Self.peakLongitudinalKey)
        peakCombinedG     = d.double(forKey: Self.peakCombinedKey)
        calibrationX      = d.double(forKey: Self.calibrationXKey)
        calibrationY      = d.double(forKey: Self.calibrationYKey)
    }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else {
            return
        }
        manager.deviceMotionUpdateInterval = 1.0 / Self.updateHz
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.handle(motion)
        }
    }

    func stop() {
        if manager.isDeviceMotionActive {
            manager.stopDeviceMotionUpdates()
        }
    }

    /// Capture current raw reading as the new zero. Call while the
    /// car is parked and level. Subsequent readings have this
    /// subtracted, so a slightly-tilted mount doesn't permanently
    /// pin the dot away from centre.
    func calibrate() {
        guard let m = manager.deviceMotion else { return }
        calibrationX = m.userAcceleration.x
        calibrationY = m.userAcceleration.y
        let d = UserDefaults.standard
        d.set(calibrationX, forKey: Self.calibrationXKey)
        d.set(calibrationY, forKey: Self.calibrationYKey)
    }

    /// Wipe session peaks back to zero. The dashboard records
    /// 'highest G this car has ever pulled' until the user resets.
    func resetPeaks() {
        peakLateralG = 0
        peakLongitudinalG = 0
        peakCombinedG = 0
        let d = UserDefaults.standard
        d.removeObject(forKey: Self.peakLateralKey)
        d.removeObject(forKey: Self.peakLongitudinalKey)
        d.removeObject(forKey: Self.peakCombinedKey)
    }

    // MARK: - Per-sample handler

    private func handle(_ motion: CMDeviceMotion) {
        // userAcceleration is gravity-removed already. Units: G.
        let lat = motion.userAcceleration.x - calibrationX
        let lon = motion.userAcceleration.y - calibrationY

        currentLateralG = lat
        currentLongitudinalG = lon

        let absLat = abs(lat)
        let absLon = abs(lon)
        let combined = sqrt(lat * lat + lon * lon)

        if absLat > peakLateralG {
            peakLateralG = absLat
            UserDefaults.standard.set(absLat, forKey: Self.peakLateralKey)
        }
        if absLon > peakLongitudinalG {
            peakLongitudinalG = absLon
            UserDefaults.standard.set(absLon, forKey: Self.peakLongitudinalKey)
        }
        if combined > peakCombinedG {
            peakCombinedG = combined
            UserDefaults.standard.set(combined, forKey: Self.peakCombinedKey)
        }

        // Push the new sample into the trail buffer. Ring buffer
        // semantics via a simple drop-first when over capacity.
        trail.append(SIMD2(lat, lon))
        if trail.count > Self.trailMaxSamples {
            trail.removeFirst(trail.count - Self.trailMaxSamples)
        }
    }
}
