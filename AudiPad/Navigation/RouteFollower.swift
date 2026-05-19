import Foundation
import CoreLocation
import MapKit
import Combine

/// Tracks the user's progress along an active `MKRoute` and publishes
/// step-by-step state for the maneuver banner, voice prompts, and
/// re-route detection. Foundation for live turn-by-turn navigation —
/// every higher-level nav feature reads this struct.
@MainActor
final class RouteFollower: ObservableObject {

    struct Progress {
        /// Index into `route.steps`. Advances as the user passes each
        /// step's end point.
        let currentStepIndex: Int
        /// Maneuver text for the END of the current step
        /// ("Turn right onto Mannerheimintie"). `MKRoute` puts the
        /// maneuver text on the step the user is currently *on*, not
        /// on the next one.
        let currentInstruction: String
        /// Maneuver text for the step *after* the current one — used
        /// by the banner to preview "after this turn, …".
        let nextInstruction: String?
        /// Distance from the user's snapped position to the end of
        /// the current step, in meters. The number in
        /// "In 200 m, turn right".
        let distanceToManeuverMeters: CLLocationDistance
        /// Distance from the user's snapped position to the route's
        /// destination, in meters.
        let distanceRemainingMeters: CLLocationDistance
        /// ETA, in seconds. Pro-rated from `route.expectedTravelTime`
        /// by `distanceRemaining / totalDistance` so it shrinks as
        /// the user drives.
        let etaSeconds: TimeInterval
        /// Position on the polyline closest to the raw GPS fix. Future
        /// use: keep the camera glued to the route rather than the
        /// raw user position.
        let snappedCoordinate: CLLocationCoordinate2D
        /// Perpendicular distance from the raw GPS fix to the route
        /// polyline. Future re-route detector consumes this.
        let lateralDeviationMeters: CLLocationDistance

        /// Convenience: `true` when the next maneuver waypoint has
        /// effectively been reached (within 15 m) — useful for the
        /// banner to flash "Turn right NOW" without waiting for the
        /// step index to advance.
        var isAtManeuver: Bool { distanceToManeuverMeters < 15 }
    }

    @Published private(set) var progress: Progress?

    /// Active route. Held so the follower can read step instructions
    /// + per-step distances on each location update without the view
    /// having to re-supply them.
    private var route: MKRoute?
    private var currentStepIndex: Int = 0

    /// Cumulative distance from route start to the end of each step,
    /// pre-computed when the route is set so we don't repeat the
    /// addition on every location update.
    private var stepEndDistances: [CLLocationDistance] = []
    private var totalRouteDistance: CLLocationDistance = 0
    private var expectedTravelTime: TimeInterval = 0

    /// Replace the active route. Resets internal step state. Pass nil
    /// to stop following.
    func setRoute(_ route: MKRoute?) {
        self.route = route
        self.currentStepIndex = 0
        guard let route else {
            stepEndDistances = []
            totalRouteDistance = 0
            expectedTravelTime = 0
            if progress != nil { progress = nil }
            return
        }
        var cumulative: CLLocationDistance = 0
        var ends: [CLLocationDistance] = []
        ends.reserveCapacity(route.steps.count)
        for step in route.steps {
            cumulative += step.distance
            ends.append(cumulative)
        }
        stepEndDistances = ends
        totalRouteDistance = cumulative
        expectedTravelTime = route.expectedTravelTime
    }

    /// Feed a fresh user location. Snaps it onto the route polyline,
    /// advances the current step index if we've passed one or more
    /// maneuver waypoints, and publishes a new `Progress`.
    func applyLocation(_ loc: CLLocation) {
        guard let route, !route.steps.isEmpty, !stepEndDistances.isEmpty else { return }

        let (snapped, traveled, lateralM) = Self.snap(loc.coordinate, to: route.polyline)

        // Advance currentStepIndex while we've passed the end of the
        // current step. Bounded by the last step so we don't run off
        // the array.
        while currentStepIndex < route.steps.count - 1
                && traveled >= stepEndDistances[currentStepIndex] {
            currentStepIndex += 1
        }

        let step = route.steps[currentStepIndex]
        let nextStep: MKRoute.Step? = currentStepIndex + 1 < route.steps.count
            ? route.steps[currentStepIndex + 1]
            : nil

        let distanceToManeuver = max(0, stepEndDistances[currentStepIndex] - traveled)
        let distanceRemaining = max(0, totalRouteDistance - traveled)
        let etaSeconds: TimeInterval = totalRouteDistance > 0
            ? expectedTravelTime * (distanceRemaining / totalRouteDistance)
            : 0

        let next = Progress(
            currentStepIndex: currentStepIndex,
            currentInstruction: step.instructions,
            nextInstruction: nextStep?.instructions,
            distanceToManeuverMeters: distanceToManeuver,
            distanceRemainingMeters: distanceRemaining,
            etaSeconds: etaSeconds,
            snappedCoordinate: snapped,
            lateralDeviationMeters: lateralM
        )
        if next != progress { progress = next }
    }

    // MARK: - Geometry helpers

    /// Snap `coord` onto `polyline`. Returns the closest point on the
    /// polyline (snapped), the cumulative distance from the polyline
    /// start to that point (traveled), and the perpendicular distance
    /// in meters from `coord` to the snapped point (lateral).
    private static func snap(_ coord: CLLocationCoordinate2D,
                             to polyline: MKPolyline) -> (
        snapped: CLLocationCoordinate2D,
        traveled: CLLocationDistance,
        lateral: CLLocationDistance
    ) {
        let n = polyline.pointCount
        guard n >= 2 else { return (coord, 0, 0) }
        let userPt = MKMapPoint(coord)
        let pts = polyline.points()

        var bestLateral = Double.infinity
        var bestTraveled: Double = 0
        var bestFoot = pts[0]
        var cumulative: Double = 0

        for i in 0..<(n - 1) {
            let a = pts[i]
            let b = pts[i + 1]
            let segLen = a.distance(to: b)
            let (foot, t) = projection(of: userPt, onto: a, b: b)
            let lateralM = userPt.distance(to: foot)
            if lateralM < bestLateral {
                bestLateral = lateralM
                bestTraveled = cumulative + segLen * t
                bestFoot = foot
            }
            cumulative += segLen
        }
        return (bestFoot.coordinate, bestTraveled, bestLateral)
    }

    /// Project `p` onto the line segment from `a` to `b`. Returns the
    /// foot of perpendicular (clamped to the segment endpoints) and
    /// the parameter `t` in `[0, 1]` where `t=0` is at `a` and `t=1`
    /// is at `b`.
    private static func projection(of p: MKMapPoint,
                                   onto a: MKMapPoint,
                                   b: MKMapPoint) -> (MKMapPoint, Double) {
        let abx = b.x - a.x
        let aby = b.y - a.y
        let len2 = abx * abx + aby * aby
        guard len2 > 0 else { return (a, 0) }
        let t = max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2))
        let foot = MKMapPoint(x: a.x + t * abx, y: a.y + t * aby)
        return (foot, t)
    }
}

// MARK: - Manual Equatable on Progress
//
// We can't auto-synthesize because `CLLocationCoordinate2D` doesn't
// conform to `Equatable` system-wide (and shouldn't, to avoid
// clashing with a future SDK conformance).

extension RouteFollower.Progress: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.currentStepIndex == rhs.currentStepIndex
            && lhs.currentInstruction == rhs.currentInstruction
            && lhs.nextInstruction == rhs.nextInstruction
            && lhs.distanceToManeuverMeters == rhs.distanceToManeuverMeters
            && lhs.distanceRemainingMeters == rhs.distanceRemainingMeters
            && lhs.etaSeconds == rhs.etaSeconds
            && lhs.snappedCoordinate.latitude == rhs.snappedCoordinate.latitude
            && lhs.snappedCoordinate.longitude == rhs.snappedCoordinate.longitude
            && lhs.lateralDeviationMeters == rhs.lateralDeviationMeters
    }
}
