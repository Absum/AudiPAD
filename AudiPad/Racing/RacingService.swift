import Foundation
import CoreLocation
import Combine
import SwiftUI

/// Performance trackers for the Racing tab. Three independent
/// state machines fed by GPS speed + distance:
///   • Top Speed — single all-time max.
///   • 0-100 km/h — time from rest to 100 km/h.
///   • ¼ mile (402.336 m) — time + trap speed at the 1/4-mile mark.
///
/// All three run continuously while their respective toggles are on,
/// regardless of which tab is on screen — the user can enable Top
/// Speed once and have it record on any drive. The service is owned
/// at App level (ContentView) and subscribes to LocationService.$location
/// so it picks up every fix the rest of the app sees.
@MainActor
final class RacingService: ObservableObject {

    // MARK: - Records (persisted to UserDefaults)

    struct TopSpeedRecord: Codable, Equatable {
        let kph: Double
        let recordedAt: Date
    }

    struct ZeroToHundredRecord: Codable, Equatable {
        let seconds: Double
        let recordedAt: Date
    }

    struct QuarterMileRecord: Codable, Equatable {
        let seconds: Double
        /// Speed (km/h) at the moment we crossed 402.336 m — trap speed.
        let trapKph: Double
        let recordedAt: Date
    }

    // MARK: - Live state

    enum RunState: Equatable {
        /// Tracker is enabled but waiting for the user to come to a
        /// near-standstill before it'll start the next run.
        case armingForStop
        /// Standing still — the next acceleration starts the timer.
        case armed
        /// Run in progress; published `elapsedSeconds` ticks.
        case running(startedAt: Date)
        /// Most-recent run completed. Stays in this state until the
        /// next standstill, then transitions to `armed`.
        case completed
    }

    @Published private(set) var topSpeedRecord: TopSpeedRecord?
    @Published private(set) var zeroToHundredLast: ZeroToHundredRecord?
    @Published private(set) var zeroToHundredBest: ZeroToHundredRecord?
    @Published private(set) var quarterMileLast: QuarterMileRecord?
    @Published private(set) var quarterMileBest: QuarterMileRecord?

    /// Current speed in km/h, the value driving every tracker. Mirrored
    /// onto @Published so the UI can show a live readout in the cards.
    @Published private(set) var currentKph: Double = 0

    /// State of each tracker (RUN cards use it to render "Armed",
    /// "RUNNING 4.32s", "DONE", etc.).
    @Published private(set) var zeroToHundredState: RunState = .armingForStop
    @Published private(set) var quarterMileState: RunState = .armingForStop

    /// Live in-run distance (meters) for the quarter mile, used by the
    /// card to render a fraction-of-completion bar.
    @Published private(set) var quarterMileDistance: Double = 0

    /// Live in-run timer (seconds) — published so the card shows a
    /// counting-up readout while RUNNING. Driven by a 60 Hz display
    /// link rather than per-GPS-fix so it ticks smoothly.
    @Published private(set) var zeroToHundredElapsed: Double = 0
    @Published private(set) var quarterMileElapsed: Double = 0

    // MARK: - Enable toggles (read via @AppStorage in the UI)

    static let topSpeedEnabledKey      = "audipad.racing.topSpeed.enabled"
    static let zeroToHundredEnabledKey = "audipad.racing.0to100.enabled"
    static let quarterMileEnabledKey   = "audipad.racing.quarter.enabled"

    /// Defaults all-off — silent recording would surprise the user.
    static let defaultTopSpeedEnabled      = false
    static let defaultZeroToHundredEnabled = false
    static let defaultQuarterMileEnabled   = false

    private var topSpeedEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.topSpeedEnabledKey) as? Bool
            ?? Self.defaultTopSpeedEnabled
    }
    private var zeroToHundredEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.zeroToHundredEnabledKey) as? Bool
            ?? Self.defaultZeroToHundredEnabled
    }
    private var quarterMileEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.quarterMileEnabledKey) as? Bool
            ?? Self.defaultQuarterMileEnabled
    }

    // MARK: - Tunables

    /// Quarter-mile distance in meters. 1/4 of an international mile
    /// (1609.344 m / 4).
    private static let quarterMileMeters: Double = 402.336

    /// Below this speed (km/h) we consider the car at rest — armed
    /// for the next run. 2 km/h is generous enough to absorb GPS
    /// noise (which can read 0.5-1.5 km/h while truly stationary) yet
    /// strict enough that "creeping in traffic" doesn't count.
    private static let stoppedThresholdKph: Double = 2

    /// Speed crossing that fires the timer + locks the start position.
    /// Slightly above the stopped threshold so the two don't fight on
    /// noisy fixes — once you've crossed this, the timer is RUNNING.
    private static let movingThresholdKph: Double = 3

    /// Target for 0-100. The classic stat.
    private static let zeroToHundredTargetKph: Double = 100

    /// Minimum elapsed time for a 0-100 to count — protects against a
    /// GPS jump producing a sub-second "run". 1 second is well below
    /// any real car (Veyron does ~2.5s).
    private static let zeroToHundredMinSeconds: Double = 1.0

    /// Minimum time for a quarter mile (~5 s would mean ~290 km/h
    /// average — even hypercars don't hit that average). Below this
    /// we assume a GPS glitch and discard.
    private static let quarterMileMinSeconds: Double = 5.0

    // MARK: - Internal tracker state

    private var lastFix: CLLocation?

    /// Origin coord of the in-progress quarter-mile run; nil when not
    /// RUNNING. Distance is accumulated as Σ d(fix_i, fix_{i+1}) so
    /// turns/winding roads count correctly (vs straight-line from
    /// origin, which would under-report on a non-straight quarter).
    private var quarterMileRunStartedAt: Date?

    // Live-timer tick loop — a single CADisplayLink-equivalent that
    // bumps `*Elapsed` and lets the UI render a smooth counter. We use
    // a Task with a short sleep rather than CADisplayLink because the
    // sub-frame precision isn't useful here and Task is simpler.
    private var tickTask: Task<Void, Never>?

    // MARK: - Persistence keys

    private static let topSpeedRecordKey      = "audipad.racing.topSpeed.record"
    private static let zeroToHundredLastKey   = "audipad.racing.0to100.last"
    private static let zeroToHundredBestKey   = "audipad.racing.0to100.best"
    private static let quarterMileLastKey     = "audipad.racing.quarter.last"
    private static let quarterMileBestKey     = "audipad.racing.quarter.best"

    init() {
        loadRecords()
        startTickLoop()
    }

    deinit {
        tickTask?.cancel()
    }

    // MARK: - Reset

    func resetTopSpeed() {
        topSpeedRecord = nil
        UserDefaults.standard.removeObject(forKey: Self.topSpeedRecordKey)
    }

    func resetZeroToHundred() {
        zeroToHundredLast = nil
        zeroToHundredBest = nil
        UserDefaults.standard.removeObject(forKey: Self.zeroToHundredLastKey)
        UserDefaults.standard.removeObject(forKey: Self.zeroToHundredBestKey)
        zeroToHundredState = .armingForStop
        zeroToHundredElapsed = 0
    }

    func resetQuarterMile() {
        quarterMileLast = nil
        quarterMileBest = nil
        UserDefaults.standard.removeObject(forKey: Self.quarterMileLastKey)
        UserDefaults.standard.removeObject(forKey: Self.quarterMileBestKey)
        quarterMileState = .armingForStop
        quarterMileElapsed = 0
        quarterMileDistance = 0
        quarterMileRunStartedAt = nil
    }

    // MARK: - Per-fix update

    /// Feed a fresh GPS fix. Called from ContentView's
    /// `.onReceive(location.$location)` regardless of which tab is
    /// on screen — the trackers run while their toggle is on.
    func applyLocation(_ fix: CLLocation) {
        defer { lastFix = fix }

        let speedMS = max(0, fix.speed)
        let kph = speedMS * 3.6
        if currentKph != kph { currentKph = kph }

        if topSpeedEnabled {
            updateTopSpeed(kph: kph)
        }
        if zeroToHundredEnabled {
            updateZeroToHundred(kph: kph, fix: fix)
        } else if zeroToHundredState != .armingForStop {
            // Toggle just flipped off — wind down so the next enable
            // starts from a clean slate.
            zeroToHundredState = .armingForStop
            zeroToHundredElapsed = 0
        }
        if quarterMileEnabled {
            updateQuarterMile(kph: kph, fix: fix)
        } else if quarterMileState != .armingForStop {
            quarterMileState = .armingForStop
            quarterMileElapsed = 0
            quarterMileDistance = 0
            quarterMileRunStartedAt = nil
        }
    }

    // MARK: - Top Speed

    private func updateTopSpeed(kph: Double) {
        let existing = topSpeedRecord?.kph ?? 0
        if kph > existing {
            let r = TopSpeedRecord(kph: kph, recordedAt: Date())
            topSpeedRecord = r
            persist(r, key: Self.topSpeedRecordKey)
        }
    }

    // MARK: - 0-100

    private func updateZeroToHundred(kph: Double, fix: CLLocation) {
        switch zeroToHundredState {
        case .armingForStop, .completed:
            // Wait for a near-standstill before allowing the next run.
            if kph < Self.stoppedThresholdKph {
                zeroToHundredState = .armed
                zeroToHundredElapsed = 0
            }
        case .armed:
            if kph > Self.movingThresholdKph {
                zeroToHundredState = .running(startedAt: fix.timestamp)
                zeroToHundredElapsed = 0
            }
        case .running(let startedAt):
            // Mid-run drop to standstill → invalidate, re-arm.
            if kph < Self.stoppedThresholdKph {
                zeroToHundredState = .armed
                zeroToHundredElapsed = 0
                return
            }
            // Target reached → record + best.
            if kph >= Self.zeroToHundredTargetKph {
                let seconds = fix.timestamp.timeIntervalSince(startedAt)
                if seconds >= Self.zeroToHundredMinSeconds {
                    let r = ZeroToHundredRecord(seconds: seconds, recordedAt: Date())
                    zeroToHundredLast = r
                    persist(r, key: Self.zeroToHundredLastKey)
                    if let best = zeroToHundredBest {
                        if seconds < best.seconds {
                            zeroToHundredBest = r
                            persist(r, key: Self.zeroToHundredBestKey)
                        }
                    } else {
                        zeroToHundredBest = r
                        persist(r, key: Self.zeroToHundredBestKey)
                    }
                }
                zeroToHundredState = .completed
                zeroToHundredElapsed = 0
            }
        }
    }

    // MARK: - ¼ mile

    private func updateQuarterMile(kph: Double, fix: CLLocation) {
        switch quarterMileState {
        case .armingForStop, .completed:
            if kph < Self.stoppedThresholdKph {
                quarterMileState = .armed
                quarterMileDistance = 0
                quarterMileElapsed = 0
                quarterMileRunStartedAt = nil
            }
        case .armed:
            if kph > Self.movingThresholdKph {
                quarterMileState = .running(startedAt: fix.timestamp)
                quarterMileDistance = 0
                quarterMileElapsed = 0
                quarterMileRunStartedAt = fix.timestamp
            }
        case .running(let startedAt):
            if kph < Self.stoppedThresholdKph {
                quarterMileState = .armed
                quarterMileDistance = 0
                quarterMileElapsed = 0
                quarterMileRunStartedAt = nil
                return
            }
            // Accumulate distance step from previous fix. Σ d(i, i+1)
            // handles turns naturally — for a drag strip it's
            // straight-line equivalent.
            if let prev = lastFix {
                quarterMileDistance += fix.distance(from: prev)
            }
            if quarterMileDistance >= Self.quarterMileMeters {
                let seconds = fix.timestamp.timeIntervalSince(startedAt)
                if seconds >= Self.quarterMileMinSeconds {
                    let r = QuarterMileRecord(seconds: seconds,
                                              trapKph: kph,
                                              recordedAt: Date())
                    quarterMileLast = r
                    persist(r, key: Self.quarterMileLastKey)
                    if let best = quarterMileBest {
                        // Best is by time — trap speed comes along
                        // for the ride. Drag racing convention is
                        // best E.T. (elapsed time).
                        if seconds < best.seconds {
                            quarterMileBest = r
                            persist(r, key: Self.quarterMileBestKey)
                        }
                    } else {
                        quarterMileBest = r
                        persist(r, key: Self.quarterMileBestKey)
                    }
                }
                quarterMileState = .completed
                quarterMileDistance = 0
                quarterMileElapsed = 0
                quarterMileRunStartedAt = nil
            }
        }
    }

    // MARK: - Tick loop (smooth live counters)

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
        if case let .running(startedAt) = zeroToHundredState {
            zeroToHundredElapsed = Date().timeIntervalSince(startedAt)
        }
        if case let .running(startedAt) = quarterMileState {
            quarterMileElapsed = Date().timeIntervalSince(startedAt)
        }
    }

    // MARK: - Persistence

    private func loadRecords() {
        if let r: TopSpeedRecord = load(key: Self.topSpeedRecordKey) {
            topSpeedRecord = r
        }
        if let r: ZeroToHundredRecord = load(key: Self.zeroToHundredLastKey) {
            zeroToHundredLast = r
        }
        if let r: ZeroToHundredRecord = load(key: Self.zeroToHundredBestKey) {
            zeroToHundredBest = r
        }
        if let r: QuarterMileRecord = load(key: Self.quarterMileLastKey) {
            quarterMileLast = r
        }
        if let r: QuarterMileRecord = load(key: Self.quarterMileBestKey) {
            quarterMileBest = r
        }
    }

    private func persist<T: Codable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func load<T: Codable>(key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let v = try? JSONDecoder().decode(T.self, from: data)
        else { return nil }
        return v
    }
}
