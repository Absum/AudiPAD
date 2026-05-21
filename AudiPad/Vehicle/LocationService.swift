import Foundation
import CoreLocation

/// Thin wrapper around `CLLocationManager` that publishes the latest
/// `CLLocation` and authorization status. Lives at the app level so any
/// view that needs the user's position can subscribe.
@MainActor
final class LocationService: NSObject, ObservableObject {
    @Published private(set) var location: CLLocation?
    @Published private(set) var heading: CLHeading?
    @Published private(set) var status: CLAuthorizationStatus

    private let manager = CLLocationManager()

    override init() {
        self.status = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        // Stream every fix CoreLocation produces — the map camera
        // interpolates between them, so denser input → smoother visual.
        manager.distanceFilter = kCLDistanceFilterNone
        manager.headingFilter = 1
        manager.activityType = .automotiveNavigation
        // The car automation that auto-launches us may sit at a red
        // light or stationary for a while; CoreLocation's default
        // behaviour is to *pause* updates when it thinks we're not
        // moving, which kills the speedometer feed. Keep the stream
        // alive — we want the next fix the second we roll.
        manager.pausesLocationUpdatesAutomatically = false
        // Pre-warm: if the user already granted permission on a prior
        // launch, kick the GPS receiver the moment this object is
        // instantiated — well before any view's onAppear runs. The
        // first cold fix takes 5–15 s on iPad GPS hardware; starting
        // it in init() instead of in a view's onAppear shaves whatever
        // delay there is between app launch and first view mount,
        // which on the car-mounted iPad is the difference between
        // "speedometer is live when you look down" and "it's catching
        // up while you drive off".
        if isAuthorized {
            manager.startUpdatingLocation()
            if CLLocationManager.headingAvailable() {
                manager.startUpdatingHeading()
            }
        }
    }

    /// Ask for "When In Use" permission. Safe to call repeatedly — the system
    /// only shows the prompt once, then no-ops.
    func requestPermission() {
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if isAuthorized {
            start()
        }
    }

    func start() {
        guard isAuthorized else { return }
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    var isAuthorized: Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let new = manager.authorizationStatus
        Task { @MainActor in
            self.status = new
            if self.isAuthorized {
                self.start()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in
            self.location = Self.augment(last, previous: self.location)
        }
    }

    /// Some location sources (notably `xcrun simctl location set`)
    /// only supply latitude + longitude; speed and course come back
    /// as -1. Synthesize them from the delta to the previous fix so
    /// downstream consumers (speedometer, heading-up rotation,
    /// camera-facing gate on speed cameras) keep working when the
    /// upstream values are missing.
    private static func augment(_ new: CLLocation, previous: CLLocation?) -> CLLocation {
        let hasSpeed = new.speed >= 0
        let hasCourse = new.course >= 0
        guard !hasSpeed || !hasCourse, let prev = previous else { return new }

        let dt = new.timestamp.timeIntervalSince(prev.timestamp)
        guard dt > 0.05, dt < 5 else { return new }

        let distance = new.distance(from: prev)
        // Ignore microscopic jitter so we don't compute a spurious
        // course when the user is parked.
        guard distance > 0.5 else { return new }

        let speed = hasSpeed ? new.speed : distance / dt
        let course = hasCourse ? new.course : Self.bearing(from: prev.coordinate, to: new.coordinate)

        return CLLocation(
            coordinate: new.coordinate,
            altitude: new.altitude,
            horizontalAccuracy: new.horizontalAccuracy,
            verticalAccuracy: new.verticalAccuracy,
            course: course,
            speed: speed,
            timestamp: new.timestamp
        )
    }

    /// Great-circle initial bearing from `a` to `b`, degrees clockwise
    /// from north — same convention CoreLocation uses for `course`.
    private static func bearing(from a: CLLocationCoordinate2D,
                                to b: CLLocationCoordinate2D) -> CLLocationDirection {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateHeading newHeading: CLHeading) {
        Task { @MainActor in
            self.heading = newHeading
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        // Common during simulator launch ("No location set") — ignore.
    }
}
