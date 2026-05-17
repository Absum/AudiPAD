import Foundation
import CoreLocation
import Combine

/// Phase 1 of the road-speed-limit pipeline: queries OpenStreetMap via
/// Overpass for `highway` ways with a `maxspeed` tag near the user's
/// current position, picks the nearest one, applies a Finnish
/// summer-vs-winter heuristic (Nov 1 – Mar 31 → knock down typical
/// trunk/motorway values), and publishes the result.
///
/// Layered later by:
/// - Phase 2: Digitraffic Variable Sign override on highway segments
///   that have a live VMS within ~500 m showing a speed-limit value.
/// - Phase 3: Digitraffic Tierekisteri / Digiroad — authoritative
///   national road database with explicit summer/winter limits per
///   road link, replacing the OSM + heuristic combo for FI roads.
/// - Eventually overridden by the TSR pipeline when a sign is detected.
@MainActor
final class RoadSpeedLimitService: ObservableObject {

    struct Reading: Equatable, Codable {
        enum Source: String, Codable { case osm, vms, tierekisteri, tsr }

        let limit: Int
        let source: Source
        /// True if the Finland winter-limit heuristic adjusted the value.
        let appliedSeasonalAdjustment: Bool
        let timestamp: Date
    }

    @Published private(set) var current: Reading?
    @Published private(set) var lastError: String?

    private static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
    private static let cacheKey = "audipad.roads.lastReading.v1"
    private static let refetchDistanceM: CLLocationDistance = 50
    private static let cacheMaxAgeSec: TimeInterval = 24 * 3600

    private var ticker: Task<Void, Never>?
    private var lastQueriedCoord: CLLocationCoordinate2D?
    private var coordProvider: () -> CLLocationCoordinate2D? = { nil }

    init() {
        loadCache()
    }

    func start(coordProvider: @escaping () -> CLLocationCoordinate2D?) {
        self.coordProvider = coordProvider
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            guard let self else { return }
            // First immediate attempt
            if let coord = self.coordProvider() {
                await self.fetch(around: coord)
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { break }
                if let coord = self.coordProvider(),
                   self.shouldFetch(for: coord) {
                    await self.fetch(around: coord)
                }
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
    }

    // MARK: - Fetch

    private func shouldFetch(for coord: CLLocationCoordinate2D) -> Bool {
        guard let last = lastQueriedCoord else { return true }
        let here = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        let there = CLLocation(latitude: last.latitude, longitude: last.longitude)
        return here.distance(from: there) > Self.refetchDistanceM
    }

    private func fetch(around coord: CLLocationCoordinate2D) async {
        let query = """
        [out:json][timeout:15];
        way["highway"]["maxspeed"](around:200,\(coord.latitude),\(coord.longitude));
        out tags geom;
        """
        guard var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false) else { return }
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

            let payload = try JSONDecoder().decode(OverpassWaysResponse.self, from: data)
            let userLoc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)

            // Pick the way whose nearest vertex is closest to the user
            let nearest = payload.elements
                .compactMap { way -> (limit: Int, dist: CLLocationDistance)? in
                    guard let raw = way.tags?["maxspeed"],
                          let limit = Self.parseMaxspeed(raw)
                    else { return nil }
                    let d = Self.nearestVertexDistance(way, to: userLoc)
                    return (limit, d)
                }
                .min(by: { $0.dist < $1.dist })

            // Track the queried point regardless of result so we don't
            // hammer Overpass when the user is in a no-data area
            lastQueriedCoord = coord

            guard let n = nearest else {
                // No nearby roads with a maxspeed tag; surface that as nil
                // instead of holding onto a stale reading from a previous spot.
                current = nil
                lastError = nil
                return
            }

            let now = Date()
            let (limit, adjusted) = Self.applyFinlandWinterRule(n.limit, on: now)
            let reading = Reading(
                limit: limit,
                source: .osm,
                appliedSeasonalAdjustment: adjusted,
                timestamp: now
            )

            current = reading
            lastError = nil
            saveCache(reading)
        } catch let decoding as DecodingError {
            lastError = "Decode: \(decoding.localizedDescription)"
        } catch {
            lastError = "Network: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private static func nearestVertexDistance(_ way: OverpassWay, to user: CLLocation) -> CLLocationDistance {
        (way.geometry ?? []).map { v in
            user.distance(from: CLLocation(latitude: v.lat, longitude: v.lon))
        }.min() ?? .infinity
    }

    /// Parse common OSM `maxspeed` tag values:
    /// - `"50"` → 50
    /// - `"50 mph"` → 80 (converted)
    /// - `"FI:urban"` → 50, `"FI:rural"` → 80, `"FI:motorway"` → 120, `"FI:living_street"` → 20
    /// - `"none"` / `"walk"` / `"signals"` / unknown → nil (no speed-limit value)
    static func parseMaxspeed(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed == "none" || trimmed == "signals" || trimmed.hasPrefix("walk") {
            return nil
        }
        if trimmed.hasSuffix("mph") {
            let numPart = trimmed.dropLast(3).trimmingCharacters(in: .whitespaces)
            guard let mph = Int(numPart) else { return nil }
            return Int((Double(mph) * 1.609).rounded())
        }
        switch trimmed {
        case "fi:urban":         return 50
        case "fi:rural":         return 80
        case "fi:motorway":      return 120
        case "fi:living_street": return 20
        default: break
        }
        return Int(trimmed)
    }

    /// Finland winter speed-limit heuristic: Nov 1 – Mar 31 inclusive
    /// the typical motorway / trunk / main-road summer limits are
    /// reduced by 20 km/h. City limits stay the same.
    static func applyFinlandWinterRule(_ limit: Int, on date: Date) -> (Int, Bool) {
        let cal = Calendar(identifier: .gregorian)
        let month = cal.component(.month, from: date)
        let isWinter = (month >= 11 || month <= 3)
        guard isWinter else { return (limit, false) }
        switch limit {
        case 130, 120: return (100, true)
        case 100:      return (80, true)
        case 90:       return (80, true)
        default:       return (limit, false)
        }
    }

    // MARK: - Cache

    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let r = try? JSONDecoder().decode(Reading.self, from: data),
              Date().timeIntervalSince(r.timestamp) < Self.cacheMaxAgeSec
        else { return }
        current = r
    }

    private func saveCache(_ r: Reading) {
        guard let data = try? JSONEncoder().encode(r) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }
}

// MARK: - Overpass response shapes (ways with geometry)

private struct OverpassWaysResponse: Decodable {
    let elements: [OverpassWay]
}

private struct OverpassWay: Decodable {
    let type: String
    let id: Int
    let tags: [String: String]?
    let geometry: [OverpassVertex]?
}

private struct OverpassVertex: Decodable {
    let lat: Double
    let lon: Double
}
