import Foundation
import Combine

/// Publishes `OBDSnapshot`s to the UI at ~2 Hz.
///
/// Today the data comes from a built-in `DrivingSimulator`. When the real
/// ELM327/OBD-II reader lands (post-jailbreak), the source can be swapped
/// behind an `OBDClient` protocol — the UI binding stays identical.
@MainActor
final class VehicleViewModel: ObservableObject {
    @Published private(set) var snapshot: OBDSnapshot = .placeholder

    private let simulator = DrivingSimulator()
    private var ticker: Task<Void, Never>?
    private let tickInterval: Duration = .milliseconds(500)
    private let tickDt: Double = 0.5

    func start() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let next = await self.simulator.tick(dt: self.tickDt)
                self.snapshot = next
                try? await Task.sleep(for: self.tickInterval)
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
    }
}

// MARK: - Mock simulator

/// Generates realistic-looking SQ5 driving data. Pure model layer — no UI,
/// no SwiftUI. Marked as an actor so its state stays consistent under
/// concurrent ticks.
actor DrivingSimulator {
    private var t: Double = 0                  // elapsed seconds
    private var fuelLiters: Double = 49        // ~65% of a full tank
    private let tankLiters: Double = 75        // SQ5 tank capacity
    private var avgConsumption: Double = 8.2   // L/100 km, slow-drifting

    // Location state — start a bit south-east of the first mock speed
    // camera so the alert visibly triggers shortly after launch.
    private var lat: Double = 60.1690
    private var lon: Double = 24.9380

    /// Produce the next snapshot, advancing internal state by `dt` seconds.
    func tick(dt: Double) -> OBDSnapshot {
        t += dt

        // ── Driver inputs ──────────────────────────────────────────────────
        // Cruise around a baseline with occasional accelerations.
        let cruiseThrottle = 0.18
        let accel = max(0, sin(t / 9.0)) * 0.35
        let jitter = Double.random(in: -0.015...0.015)
        let throttle = max(0, min(1.0, cruiseThrottle + accel + jitter))

        // ── Speed (km/h) — eases toward a throttle-driven target ───────────
        // Idle-ish at 60 km/h, ~150 km/h at WOT cruise.
        let targetSpeed = 60.0 + throttle * 90.0 + sin(t / 6.0) * 4.0
        let speedKph = targetSpeed

        // ── RPM — speed × ratio + throttle bonus when boosting ─────────────
        // Approximation: ~30 rpm per km/h covers high-gear cruise; throttle
        // bumps account for downshifts under load.
        let rpm = max(800, speedKph * 30.0 + throttle * 900.0 + sin(t / 4.0) * 80.0)

        // ── Boost (bar absolute) — atmospheric idle, climbs with throttle ──
        // Caps just under the 2.0 redline at full throttle.
        let boost = 1.0 + throttle * 0.95

        // ── Gear (mock 8-speed auto in D, mostly D6/D7 at these speeds) ────
        let gear: String
        switch speedKph {
        case ..<30:   gear = "D2"
        case 30..<55: gear = "D4"
        case 55..<90: gear = throttle > 0.5 ? "D5" : "D6"
        case 90..<130: gear = throttle > 0.5 ? "D6" : "D7"
        default:      gear = "D8"
        }

        // ── Temperatures — settled engine, slow drift ──────────────────────
        let coolant = 92.0 + sin(t / 28.0) * 1.8
        let oil = 104.0 + sin(t / 44.0) * 2.3
        let intake = 38.0 + sin(t / 17.0) * 4.5

        // ── Fuel consumption ───────────────────────────────────────────────
        // Idle ~1 L/h, WOT ~26 L/h.
        let lpHour = 1.0 + throttle * 25.0
        let dlph = lpHour * dt / 3600.0
        fuelLiters = max(0, fuelLiters - dlph)

        // L/100 km — guard against div-by-zero at standstill.
        let nowLp100 = speedKph > 5 ? (lpHour / speedKph) * 100.0 : 99.9

        // Running average drifts slowly toward the instantaneous reading.
        avgConsumption += (nowLp100 - avgConsumption) * 0.0005
        avgConsumption = max(5.5, min(14.0, avgConsumption))

        let fuelPct = (fuelLiters / tankLiters) * 100.0
        let rangeKm = fuelLiters * (100.0 / max(1.0, avgConsumption))

        // ── Location — advance lat/lon based on speed + heading ─────────────
        // Heading sweeps slowly so the simulated route wanders the area.
        let heading = sin(t / 35.0) * .pi              // -π … π
        let speedMs = speedKph / 3.6
        let distanceM = speedMs * dt
        let metersPerLatDeg = 111_000.0
        let metersPerLonDeg = 111_000.0 * cos(lat * .pi / 180)
        lat += (distanceM * cos(heading)) / metersPerLatDeg
        lon += (distanceM * sin(heading)) / metersPerLonDeg

        return OBDSnapshot(
            timestamp: Date(),
            speedKph: speedKph,
            rpm: rpm,
            gear: gear,
            throttle: throttle,
            boostBar: boost,
            coolantC: coolant,
            oilC: oil,
            intakeC: intake,
            fuelPercent: fuelPct,
            rangeKm: rangeKm,
            avgConsumption: avgConsumption,
            nowConsumption: nowLp100,
            latitude: lat,
            longitude: lon
        )
    }
}
