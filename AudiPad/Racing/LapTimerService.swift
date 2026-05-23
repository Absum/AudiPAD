import Foundation
import CoreLocation

/// GPS start-finish-line based lap timer. The user taps "Drop Line"
/// at the start of the lap; the service captures the current coord
/// and course and treats the line as the segment perpendicular to
/// that course centred on the coord. Each subsequent location fix
/// is tested for a forward crossing — when the signed distance
/// along the line's course axis flips from negative to positive AND
/// the user's current course is roughly aligned with the line's
/// forward direction, that's a lap.
///
/// Session-only state — no on-disk persistence for now; the line
/// clears on app launch. (Named tracks can be added later if the
/// user wants to time the same circuit across sessions.)
@MainActor
final class LapTimerService: ObservableObject {

    enum State: Equatable {
        case idle                              // no line set
        case waitingForFirstCross              // line set, no first crossing yet
        case running                           // first cross done, timer ticking
    }

    @Published private(set) var state: State = .idle

    /// Captured start-finish-line position + the heading that defines
    /// the "forward" direction across it. Nil until the user drops a
    /// line, cleared via clearLine().
    @Published private(set) var lineCoord: CLLocationCoordinate2D?
    @Published private(set) var lineCourseDeg: Double?

    /// Records.
    @Published private(set) var lapCount: Int = 0
    @Published private(set) var lastLapSeconds: Double?
    @Published private(set) var bestLapSeconds: Double?
    @Published private(set) var totalElapsedSeconds: Double = 0

    /// Live elapsed for the lap currently being timed, ticked by the
    /// 50 ms loop so the UI shows a smoothly counting-up readout.
    @Published private(set) var currentLapElapsed: Double = 0

    // MARK: - Tunables

    /// User's course must be within ±this many degrees of the line's
    /// forward heading for a crossing to count. Keeps a backwards
    /// drive-through from registering as a lap.
    private static let crossingCourseToleranceDeg: Double = 60

    /// User has to leave the immediate neighbourhood of the line at
    /// some point between crossings — otherwise GPS jitter while
    /// idling near the start could register multiple "laps" in a
    /// few seconds. 100 m is well above typical urban GPS noise.
    private static let minDistanceAwayMeters: Double = 100

    /// Sanity floor on lap time. A < 5 s lap would mean we registered
    /// two consecutive ticks across the line as separate crossings —
    /// safer to drop than to record a 2-second nonsense lap.
    private static let minLapSeconds: Double = 5

    // MARK: - Per-fix state

    private var previousSignedDistance: Double?
    private var maxDistanceSinceCross: Double = 0
    private var currentLapStartedAt: Date?
    private var tickTask: Task<Void, Never>?

    init() {
        startTickLoop()
    }

    deinit {
        tickTask?.cancel()
    }

    // MARK: - User actions

    /// Drop the start-finish line at the user's current location.
    /// Requires a valid course (must be moving) — without it we
    /// couldn't tell which direction across the line counts as
    /// "forward".
    func dropLine(at location: CLLocation) {
        guard location.course >= 0 else { return }
        lineCoord = location.coordinate
        lineCourseDeg = location.course
        state = .waitingForFirstCross
        lapCount = 0
        lastLapSeconds = nil
        bestLapSeconds = nil
        totalElapsedSeconds = 0
        currentLapElapsed = 0
        currentLapStartedAt = nil
        previousSignedDistance = nil
        maxDistanceSinceCross = 0
    }

    /// Clear the line + all records. Returns the timer to idle.
    func clearLine() {
        lineCoord = nil
        lineCourseDeg = nil
        state = .idle
        lapCount = 0
        lastLapSeconds = nil
        bestLapSeconds = nil
        totalElapsedSeconds = 0
        currentLapElapsed = 0
        currentLapStartedAt = nil
        previousSignedDistance = nil
        maxDistanceSinceCross = 0
    }

    // MARK: - Per-fix update

    /// Called from ContentView's `.onReceive(location.$location)` with
    /// every fix. Runs the crossing detector when a line is set.
    func applyLocation(_ fix: CLLocation) {
        guard let lineCoord, let lineCourseDeg, state != .idle else { return }

        let signed = Self.signedDistance(from: lineCoord,
                                         courseDeg: lineCourseDeg,
                                         to: fix.coordinate)
        let distanceFromLine = abs(signed)
        if distanceFromLine > maxDistanceSinceCross {
            maxDistanceSinceCross = distanceFromLine
        }

        defer { previousSignedDistance = signed }

        guard let previous = previousSignedDistance else {
            // First sample post-drop — nothing to compare against yet.
            return
        }

        // Forward crossing = negative → positive (user moved past
        // the line in the captured-course direction).
        let crossed = previous < 0 && signed >= 0
        guard crossed else { return }

        // Direction check — user's current course must be within
        // tolerance of the line's forward heading.
        guard fix.course >= 0,
              Self.angularDelta(fix.course, lineCourseDeg)
                <= Self.crossingCourseToleranceDeg
        else { return }

        // Anti-jitter — require the user to have actually driven away
        // from the line since the last crossing.
        guard maxDistanceSinceCross >= Self.minDistanceAwayMeters else { return }

        registerCrossing(at: fix.timestamp)
    }

    // MARK: - Crossing handler

    private func registerCrossing(at now: Date) {
        switch state {
        case .idle:
            return
        case .waitingForFirstCross:
            // First lap starts now — no lap recorded yet.
            currentLapStartedAt = now
            state = .running
        case .running:
            if let start = currentLapStartedAt {
                let lap = now.timeIntervalSince(start)
                if lap >= Self.minLapSeconds {
                    lastLapSeconds = lap
                    lapCount += 1
                    totalElapsedSeconds += lap
                    if let best = bestLapSeconds {
                        if lap < best { bestLapSeconds = lap }
                    } else {
                        bestLapSeconds = lap
                    }
                }
            }
            currentLapStartedAt = now
        }
        maxDistanceSinceCross = 0
        currentLapElapsed = 0
    }

    // MARK: - Tick (live elapsed display)

    private func startTickLoop() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                self?.tick()
            }
        }
    }

    private func tick() {
        guard state == .running, let start = currentLapStartedAt else { return }
        currentLapElapsed = Date().timeIntervalSince(start)
    }

    // MARK: - Geometry helpers

    /// Signed distance from `origin` along bearing `courseDeg` to
    /// the point `target`. Positive = target is ahead of origin in
    /// the direction of `courseDeg`. Negative = behind.
    ///
    /// Computed by projecting the (origin → target) vector onto the
    /// unit vector pointing along `courseDeg`. Flat-earth local
    /// frame — accurate to fractions of a meter over the few-hundred-
    /// meter scale of a lap-line crossing.
    private static func signedDistance(from origin: CLLocationCoordinate2D,
                                       courseDeg: Double,
                                       to target: CLLocationCoordinate2D) -> Double {
        let mPerLat = 111_320.0
        let mPerLon = 111_320.0 * cos(origin.latitude * .pi / 180)
        let dx = (target.longitude - origin.longitude) * mPerLon
        let dy = (target.latitude  - origin.latitude)  * mPerLat
        let courseRad = courseDeg * .pi / 180
        // Compass course: 0° = north (+dy), 90° = east (+dx).
        // Forward unit vector = (sin courseRad, cos courseRad).
        return dx * sin(courseRad) + dy * cos(courseRad)
    }

    /// Unsigned shortest-arc angular delta in degrees, `[0, 180]`.
    private static func angularDelta(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }
}
