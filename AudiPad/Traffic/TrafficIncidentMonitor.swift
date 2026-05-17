import Foundation
import CoreLocation

/// Filters a stream of traffic incidents to "things the driver should
/// see right now" — within `nearbyRadiusM` of their current location.
/// Surfaces:
/// - `nearby` — full list within radius (for map pins)
/// - `severeNearby` — single closest `.major`/`.critical` incident
///   (for the cross-cutting alert banner)
@MainActor
final class TrafficIncidentMonitor: ObservableObject {
    @Published private(set) var nearby: [TrafficIncident] = []
    @Published private(set) var severeNearby: TrafficIncident?
    @Published private(set) var severeDistanceMeters: CLLocationDistance = 0

    /// 20 km — anything further isn't relevant on a typical drive.
    let nearbyRadiusM: CLLocationDistance = 20_000

    func update(incidents: [TrafficIncident],
                userLocation: CLLocationCoordinate2D?) {
        guard let user = userLocation else {
            nearby = []
            severeNearby = nil
            severeDistanceMeters = 0
            return
        }

        let here = CLLocation(latitude: user.latitude, longitude: user.longitude)

        // Distance-tag everything once, filter to radius, sort by closest.
        let withDistance = incidents.map { inc -> (TrafficIncident, CLLocationDistance) in
            let loc = CLLocation(latitude: inc.coordinate.latitude,
                                 longitude: inc.coordinate.longitude)
            return (inc, here.distance(from: loc))
        }
        let near = withDistance.filter { $0.1 <= nearbyRadiusM }
                               .sorted { $0.1 < $1.1 }

        let severe = near.first(where: { $0.0.severity == .major || $0.0.severity == .critical })

        nearby = near.map(\.0)
        severeNearby = severe?.0
        severeDistanceMeters = severe?.1 ?? 0
    }
}
