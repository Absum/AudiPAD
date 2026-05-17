import Foundation

/// Immutable snapshot of vehicle state at a single instant.
/// Populated either by the mock simulator (today) or by a real
/// ELM327/OBD-II reader (post-jailbreak).
struct OBDSnapshot: Equatable, Sendable {
    /// When this snapshot was captured.
    var timestamp: Date

    // Motion
    var speedKph: Double
    var rpm: Double
    var gear: String

    // Engine load / boost
    var throttle: Double          // 0.0–1.0
    var boostBar: Double          // absolute manifold pressure (bar)

    // Temperatures (°C)
    var coolantC: Double
    var oilC: Double
    var intakeC: Double

    // Fuel + consumption
    var fuelPercent: Double       // 0–100
    var rangeKm: Double           // estimated distance to empty
    var avgConsumption: Double    // trip avg, L/100 km
    var nowConsumption: Double    // instantaneous, L/100 km

    /// Sensible placeholder used before the first real snapshot arrives.
    static let placeholder = OBDSnapshot(
        timestamp: Date(),
        speedKph: 0,
        rpm: 0,
        gear: "P",
        throttle: 0,
        boostBar: 1.0,
        coolantC: 90,
        oilC: 100,
        intakeC: 30,
        fuelPercent: 65,
        rangeKm: 600,
        avgConsumption: 8.2,
        nowConsumption: 0
    )
}
