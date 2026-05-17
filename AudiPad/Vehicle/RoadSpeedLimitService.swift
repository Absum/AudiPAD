import Foundation
import CoreLocation
import Combine

/// Coordinates per-source road-speed-limit readings and publishes the
/// best one as `current`. Priority:
///
///   1. Digitraffic Variable Sign (VMS) — Phase 2, live highway signs
///   2. Väylä Digiroad (Tierekisteri) — Phase 3, authoritative segments
///   3. OSM `maxspeed` + Finland winter heuristic — Phase 1, fallback
///   4. nil (no data)
///
/// Future:
///   - TSR (computer vision) — highest priority when the camera is
///     confident in what it just saw
@MainActor
final class RoadSpeedLimitService: ObservableObject {

    struct Reading: Equatable, Codable {
        enum Source: String, Codable { case osm, vms, tierekisteri, tsr }

        let limit: Int
        let source: Source
        /// True if the Finland winter-limit heuristic adjusted the value
        /// (only meaningful for OSM source).
        let appliedSeasonalAdjustment: Bool
        let timestamp: Date
    }

    @Published private(set) var current: Reading?
    @Published private(set) var lastError: String?

    private static let osmEndpoint = URL(string: "https://overpass-api.de/api/interpreter")!
    private static let vmsEndpoint = URL(string: "https://tie.digitraffic.fi/api/variable-sign/v1/signs")!
    private static let digiroadEndpoint = URL(string: "https://avoinapi.vaylapilvi.fi/vaylatiedot/digiroad/wfs")!
    private static let cacheKey = "audipad.roads.lastReading.v1"
    private static let refetchDistanceM: CLLocationDistance = 50
    private static let vmsRadiusM: CLLocationDistance = 500
    private static let cacheMaxAgeSec: TimeInterval = 24 * 3600
    private static let vmsRefreshIntervalSec: TimeInterval = 60
    /// Half-side of the Digiroad bbox in degrees. ~500 m at 60° N
    /// (1° lat ≈ 111 km; 1° lon ≈ 55 km at this latitude).
    private static let digiroadBBoxHalfLatDeg = 0.0045
    private static let digiroadBBoxHalfLonDeg = 0.0090

    // MARK: Internal state

    private var osmReading: Reading?
    private var vmsReading: Reading?
    private var digiroadReading: Reading?

    /// Cached list of all VMS speed-limit signs nationwide. Refreshed on
    /// the VMS cadence; nearest-sign lookup runs on every coord change.
    private var vmsSigns: [VMSSign] = []
    private var vmsLastFetch: Date?

    private var ticker: Task<Void, Never>?
    private var lastOSMQueriedCoord: CLLocationCoordinate2D?
    private var lastDigiroadQueriedCoord: CLLocationCoordinate2D?
    private var coordProvider: () -> CLLocationCoordinate2D? = { nil }

    init() {
        loadCache()
    }

    func start(coordProvider: @escaping () -> CLLocationCoordinate2D?) {
        self.coordProvider = coordProvider
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            guard let self else { return }
            // Initial pulls
            if let coord = self.coordProvider() {
                async let osm: () = self.fetchOSM(around: coord)
                async let dig: () = self.fetchDigiroad(around: coord)
                async let vms: () = self.refreshVMSList()
                _ = await (osm, dig, vms)
                self.recomputeVMSReading(for: coord)
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { break }
                guard let coord = self.coordProvider() else { continue }

                if self.shouldRefetchOSM(for: coord) {
                    await self.fetchOSM(around: coord)
                }
                if self.shouldRefetchDigiroad(for: coord) {
                    await self.fetchDigiroad(around: coord)
                }
                if self.shouldRefreshVMS() {
                    await self.refreshVMSList()
                }
                self.recomputeVMSReading(for: coord)
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
    }

    // MARK: - OSM fetch (Phase 1)

    private func shouldRefetchOSM(for coord: CLLocationCoordinate2D) -> Bool {
        guard let last = lastOSMQueriedCoord else { return true }
        let here = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        let there = CLLocation(latitude: last.latitude, longitude: last.longitude)
        return here.distance(from: there) > Self.refetchDistanceM
    }

    private func fetchOSM(around coord: CLLocationCoordinate2D) async {
        let query = """
        [out:json][timeout:15];
        way["highway"]["maxspeed"](around:200,\(coord.latitude),\(coord.longitude));
        out tags geom;
        """
        guard var components = URLComponents(url: Self.osmEndpoint, resolvingAgainstBaseURL: false) else { return }
        components.queryItems = [URLQueryItem(name: "data", value: query)]
        guard let url = components.url else { return }

        do {
            var request = URLRequest(url: url)
            request.setValue("AudiPad/0.1 (github.com/Absum/AudiPAD)", forHTTPHeaderField: "User-Agent")
            request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                lastError = "OSM HTTP \(http.statusCode)"
                return
            }

            let payload = try JSONDecoder().decode(OverpassWaysResponse.self, from: data)
            let userLoc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            lastOSMQueriedCoord = coord

            let nearest = payload.elements
                .compactMap { way -> (limit: Int, dist: CLLocationDistance)? in
                    guard let raw = way.tags?["maxspeed"],
                          let limit = Self.parseMaxspeed(raw)
                    else { return nil }
                    let d = Self.nearestVertexDistance(way, to: userLoc)
                    return (limit, d)
                }
                .min(by: { $0.dist < $1.dist })

            guard let n = nearest else {
                osmReading = nil
                lastError = nil
                updateCurrent()
                return
            }

            let now = Date()
            let (limit, adjusted) = Self.applyFinlandWinterRule(n.limit, on: now)
            osmReading = Reading(limit: limit,
                                 source: .osm,
                                 appliedSeasonalAdjustment: adjusted,
                                 timestamp: now)
            lastError = nil
            updateCurrent()
        } catch let decoding as DecodingError {
            lastError = "OSM decode: \(decoding.localizedDescription)"
        } catch {
            lastError = "OSM network: \(error.localizedDescription)"
        }
    }

    // MARK: - Digiroad fetch (Phase 3)

    /// Same 50 m movement threshold as OSM — Digiroad geometry is static,
    /// so we only need to re-query when we've actually moved enough that
    /// the nearest segment might have changed.
    private func shouldRefetchDigiroad(for coord: CLLocationCoordinate2D) -> Bool {
        guard let last = lastDigiroadQueriedCoord else { return true }
        let here = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        let there = CLLocation(latitude: last.latitude, longitude: last.longitude)
        return here.distance(from: there) > Self.refetchDistanceM
    }

    private func fetchDigiroad(around coord: CLLocationCoordinate2D) async {
        let minLon = coord.longitude - Self.digiroadBBoxHalfLonDeg
        let minLat = coord.latitude  - Self.digiroadBBoxHalfLatDeg
        let maxLon = coord.longitude + Self.digiroadBBoxHalfLonDeg
        let maxLat = coord.latitude  + Self.digiroadBBoxHalfLatDeg

        guard var components = URLComponents(url: Self.digiroadEndpoint, resolvingAgainstBaseURL: false) else { return }
        components.queryItems = [
            URLQueryItem(name: "service", value: "WFS"),
            URLQueryItem(name: "version", value: "2.0.0"),
            URLQueryItem(name: "request", value: "GetFeature"),
            URLQueryItem(name: "typeNames", value: "digiroad:dr_nopeusrajoitus"),
            URLQueryItem(name: "srsName", value: "EPSG:4326"),
            // Vayla expects lon,lat order when the CRS is EPSG:4326 in the bbox suffix;
            // the JSON output confirms it (coords are lon,lat,elev).
            URLQueryItem(name: "bbox", value: "\(minLon),\(minLat),\(maxLon),\(maxLat),EPSG:4326"),
            URLQueryItem(name: "count", value: "200"),
            URLQueryItem(name: "outputFormat", value: "application/json"),
        ]
        guard let url = components.url else { return }

        do {
            var request = URLRequest(url: url)
            request.setValue("AudiPad/0.1 (github.com/Absum/AudiPAD)", forHTTPHeaderField: "User-Agent")
            request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                lastError = "Digiroad HTTP \(http.statusCode)"
                return
            }

            let payload = try JSONDecoder().decode(DigiroadResponse.self, from: data)
            lastDigiroadQueriedCoord = coord

            let userLoc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            let nearest = payload.features
                .compactMap { feature -> (limit: Int, dist: CLLocationDistance)? in
                    guard let limit = feature.properties.arvo,
                          (10...130).contains(limit),
                          let coords = feature.geometry?.coordinates,
                          !coords.isEmpty
                    else { return nil }
                    let dist = coords
                        .compactMap { vertex -> CLLocationDistance? in
                            guard vertex.count >= 2 else { return nil }
                            return userLoc.distance(from: CLLocation(latitude: vertex[1], longitude: vertex[0]))
                        }
                        .min() ?? .infinity
                    return (limit, dist)
                }
                .min(by: { $0.dist < $1.dist })

            guard let n = nearest else {
                digiroadReading = nil
                lastError = nil
                updateCurrent()
                return
            }

            digiroadReading = Reading(limit: n.limit,
                                      source: .tierekisteri,
                                      appliedSeasonalAdjustment: false,
                                      timestamp: Date())
            lastError = nil
            updateCurrent()
        } catch let decoding as DecodingError {
            lastError = "Digiroad decode: \(decoding.localizedDescription)"
        } catch {
            lastError = "Digiroad network: \(error.localizedDescription)"
        }
    }

    // MARK: - VMS fetch (Phase 2)

    private func shouldRefreshVMS() -> Bool {
        guard let last = vmsLastFetch else { return true }
        return Date().timeIntervalSince(last) > Self.vmsRefreshIntervalSec
    }

    private func refreshVMSList() async {
        do {
            var request = URLRequest(url: Self.vmsEndpoint)
            request.setValue("AudiPad/0.1 (github.com/Absum/AudiPAD)", forHTTPHeaderField: "User-Agent")
            request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                lastError = "VMS HTTP \(http.statusCode)"
                return
            }

            let payload = try JSONDecoder().decode(VMSResponse.self, from: data)
            vmsSigns = payload.features.compactMap { feature -> VMSSign? in
                let props = feature.properties
                guard props.type == "SPEEDLIMIT",
                      let valueStr = props.displayValue,
                      let value = Int(valueStr.trimmingCharacters(in: .whitespaces).filter(\.isNumber))
                else { return nil }
                guard let geom = feature.geometry, geom.type == "Point",
                      let coords = geom.coordinates, coords.count >= 2
                else { return nil }
                return VMSSign(
                    id: props.id ?? UUID().uuidString,
                    coord: CLLocationCoordinate2D(latitude: coords[1], longitude: coords[0]),
                    limit: value,
                    direction: props.direction,
                    carriageway: props.carriageway
                )
            }
            vmsLastFetch = Date()
            lastError = nil
        } catch let decoding as DecodingError {
            lastError = "VMS decode: \(decoding.localizedDescription)"
        } catch {
            lastError = "VMS network: \(error.localizedDescription)"
        }
    }

    private func recomputeVMSReading(for coord: CLLocationCoordinate2D) {
        let userLoc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        let nearest = vmsSigns
            .map { sign -> (VMSSign, CLLocationDistance) in
                let dist = userLoc.distance(from: CLLocation(latitude: sign.coord.latitude,
                                                             longitude: sign.coord.longitude))
                return (sign, dist)
            }
            .filter { $0.1 <= Self.vmsRadiusM }
            .min(by: { $0.1 < $1.1 })

        if let n = nearest {
            vmsReading = Reading(limit: n.0.limit,
                                 source: .vms,
                                 appliedSeasonalAdjustment: false,
                                 timestamp: Date())
        } else {
            vmsReading = nil
        }
        updateCurrent()
    }

    // MARK: - Source coordination

    private func updateCurrent() {
        // Priority: VMS > Digiroad > OSM. TSR will slot in above VMS later
        // (or rather above the lot when the camera is confident).
        let best = vmsReading ?? digiroadReading ?? osmReading
        if best != current {
            current = best
            if let r = best { saveCache(r) }
        }
    }

    // MARK: - Helpers (same as Phase 1)

    private static func nearestVertexDistance(_ way: OverpassWay, to user: CLLocation) -> CLLocationDistance {
        (way.geometry ?? []).map { v in
            user.distance(from: CLLocation(latitude: v.lat, longitude: v.lon))
        }.min() ?? .infinity
    }

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
        // Treat the cache as that source's baseline so higher-priority
        // sources can override it after their first fetch.
        switch r.source {
        case .osm:          osmReading = r
        case .tierekisteri: digiroadReading = r
        case .vms:          vmsReading = r
        case .tsr:          break // not yet implemented
        }
    }

    private func saveCache(_ r: Reading) {
        guard let data = try? JSONEncoder().encode(r) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }
}

// MARK: - VMS internal model

private struct VMSSign {
    let id: String
    let coord: CLLocationCoordinate2D
    let limit: Int
    let direction: String?     // "INCREASING" / "DECREASING" — relative to road kilometre
    let carriageway: String?   // "RIGHT" / "LEFT" / "NORMAL"
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

// MARK: - Digitraffic VMS response shapes

private struct VMSResponse: Decodable {
    let features: [VMSFeature]
}

private struct VMSFeature: Decodable {
    let geometry: VMSGeometry?
    let properties: VMSProperties
}

private struct VMSGeometry: Decodable {
    let type: String
    let coordinates: [Double]?

    enum CodingKeys: String, CodingKey { case type, coordinates }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try c.decode(String.self, forKey: .type)
        self.coordinates = try? c.decode([Double].self, forKey: .coordinates)
    }
}

private struct VMSProperties: Decodable {
    let id: String?
    let type: String?
    let displayValue: String?
    let direction: String?
    let carriageway: String?
}

// MARK: - Digiroad WFS response shapes
//
// The endpoint returns standard GeoJSON. We only need the speed-limit
// value (`arvo`, km/h Int) and the LineString geometry. Other fields
// (`vaik_suunt` direction-of-effect, `link_id`, `kuntakoodi`, etc.)
// are present but unused for now — we just want the nearest segment.

private struct DigiroadResponse: Decodable {
    let features: [DigiroadFeature]
}

private struct DigiroadFeature: Decodable {
    let geometry: DigiroadGeometry?
    let properties: DigiroadProperties
}

private struct DigiroadGeometry: Decodable {
    let type: String
    /// LineString → `[[lon, lat, elev?], …]`. Decoded leniently because
    /// Digiroad sometimes returns vertices with elevation and sometimes
    /// without (and we just drop elevation either way).
    let coordinates: [[Double]]?

    enum CodingKeys: String, CodingKey { case type, coordinates }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try c.decode(String.self, forKey: .type)
        self.coordinates = try? c.decode([[Double]].self, forKey: .coordinates)
    }
}

private struct DigiroadProperties: Decodable {
    let arvo: Int?
}
