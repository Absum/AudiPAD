import Foundation
import CoreLocation
import Combine

/// Fetches real speed-camera locations from OpenStreetMap via the
/// Overpass API. Builds a `SpeedCamera` list around the user's current
/// position, refreshes when they move far enough to need new data,
/// caches to UserDefaults so launches are immediate, and falls back to
/// the bundled `SpeedCameraStore.helsinki` mock if nothing's cached yet.
///
/// Data source: nodes tagged `highway=speed_camera` in OSM. Coverage
/// in Finland is excellent thanks to the active OSM-FI community.
@MainActor
final class SpeedCameraService: ObservableObject {
    /// Camera list ready for consumption. Starts as the bundled mock,
    /// is replaced by real data on first successful Overpass fetch, and
    /// is replaced again whenever the user moves outside the current
    /// fetched area.
    @Published private(set) var cameras: [SpeedCamera] = SpeedCameraStore.helsinki
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var lastError: String?

    private static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
    private static let cacheKey = "audipad.cameras.osm.v1"

    /// Refetch when the user has moved this far from the last fetch center.
    private let refetchTriggerMeters: CLLocationDistance = 30_000
    /// Half-width of the fetch bounding box (degrees latitude); 0.45° ≈ 50 km.
    private let latHalfDegrees: Double = 0.45

    private var ticker: Task<Void, Never>?
    private var lastFetchedCenter: CLLocationCoordinate2D?
    private var userCenterProvider: () -> CLLocationCoordinate2D? = { nil }

    init() {
        loadCache()
    }

    func start(userCenterProvider: @escaping () -> CLLocationCoordinate2D?) {
        self.userCenterProvider = userCenterProvider
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            guard let self else { return }
            // First tick: immediately try to fetch if we have a location.
            if let center = self.userCenterProvider() {
                await self.refresh(around: center)
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                if let center = self.userCenterProvider(),
                   self.needsRefetch(for: center) {
                    await self.refresh(around: center)
                }
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
    }

    func refresh(around center: CLLocationCoordinate2D) async {
        // Bounding box scaled by latitude so the east/west extent is similar
        // in real meters regardless of where in Finland the user is.
        let lonHalfDegrees = latHalfDegrees / max(cos(center.latitude * .pi / 180), 0.1)
        let south = center.latitude - latHalfDegrees
        let north = center.latitude + latHalfDegrees
        let west = center.longitude - lonHalfDegrees
        let east = center.longitude + lonHalfDegrees

        let query = """
        [out:json][timeout:25];
        node["highway"="speed_camera"](\(south),\(west),\(north),\(east));
        out body;
        """

        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "data", value: query)]
        guard let url = components.url else { return }

        do {
            var request = URLRequest(url: url)
            request.setValue("AudiPad/0.1 (github.com/Absum/AudiPAD)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                lastError = "HTTP \(http.statusCode)"
                return
            }

            let payload = try JSONDecoder().decode(OverpassResponse.self, from: data)
            let parsed = payload.elements.compactMap(SpeedCamera.fromOverpass)

            // Replace the camera list only if we got at least one — empty
            // payloads happen when the bounding box is over water etc.;
            // we don't want to nuke a useful cached list in that case.
            if !parsed.isEmpty {
                cameras = parsed
                lastUpdated = Date()
                lastFetchedCenter = center
                lastError = nil
                saveCache(parsed)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func needsRefetch(for center: CLLocationCoordinate2D) -> Bool {
        guard let last = lastFetchedCenter else { return true }
        let here = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let there = CLLocation(latitude: last.latitude, longitude: last.longitude)
        return here.distance(from: there) > refetchTriggerMeters
    }

    // MARK: - Cache

    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let decoded = try? JSONDecoder().decode([CameraStorage].self, from: data),
              !decoded.isEmpty
        else { return }
        cameras = decoded.map(\.asCamera)
    }

    private func saveCache(_ list: [SpeedCamera]) {
        let storage = list.map(CameraStorage.init(from:))
        guard let data = try? JSONEncoder().encode(storage) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }
}

// MARK: - Overpass response + camera persistence shapes

private struct OverpassResponse: Decodable {
    let elements: [OverpassNode]
}

private struct OverpassNode: Decodable {
    let type: String
    let id: Int
    let lat: Double
    let lon: Double
    let tags: [String: String]?
}

private struct CameraStorage: Codable {
    let lat: Double
    let lon: Double
    let limit: Int
    let kind: String   // raw string of SpeedCamera.Kind

    init(from cam: SpeedCamera) {
        self.lat = cam.coordinate.latitude
        self.lon = cam.coordinate.longitude
        self.limit = cam.speedLimit
        self.kind = cam.kind.rawValue
    }

    var asCamera: SpeedCamera {
        SpeedCamera(
            latitude: lat,
            longitude: lon,
            speedLimit: limit,
            kind: SpeedCamera.Kind(rawValue: kind) ?? .fixed
        )
    }
}

extension SpeedCamera {
    /// Build a `SpeedCamera` from an OSM `speed_camera` node.
    /// Heuristics for `maxspeed` and camera kind from the node's tags.
    fileprivate static func fromOverpass(_ node: OverpassNode) -> SpeedCamera? {
        let tags = node.tags ?? [:]
        let maxspeed = tags["maxspeed"].flatMap { Int($0.trimmingCharacters(in: .whitespaces).filter(\.isNumber)) }
            ?? 50
        let kindTag = (tags["speed_camera"] ?? tags["camera:type"] ?? "fixed").lowercased()
        let kind: SpeedCamera.Kind = {
            if kindTag.contains("zone") || kindTag.contains("section") || kindTag.contains("average") {
                return .averageSpeed
            }
            if kindTag.contains("mobile") {
                return .mobile
            }
            return .fixed
        }()
        return SpeedCamera(latitude: node.lat, longitude: node.lon,
                           speedLimit: maxspeed, kind: kind)
    }
}
