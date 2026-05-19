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

    /// Name + reference of the road segment the user is closest to, sourced
    /// from OSM `way[highway]` tags in the same fetch as the speed limit.
    /// Surfaced on the Map tab; nil until first OSM response lands.
    @Published private(set) var currentRoad: RoadInfo?

    struct RoadInfo: Equatable {
        let name: String?
        let ref: String?
    }

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

    /// Independent road-info pieces from each source. Combined by
    /// `rebuildRoadInfo()` into the published `currentRoad`. Apple is
    /// preferred for `name` because it's the same data backing the
    /// MapKit view (so the panel never disagrees with the map); OSM
    /// fills the `ref` field (road number) because Apple doesn't
    /// expose that, and provides a name fallback for areas Apple
    /// doesn't cover well.
    private var appleRoadName: String?
    private var osmRoadName: String?
    private var osmRoadRef: String?

    private let geocoder = CLGeocoder()
    private var lastGeocodedCoord: CLLocationCoordinate2D?

    /// Raw Digiroad segments kept around so we can answer "what road
    /// link is this coordinate on?" — used by the speed-camera same-
    /// road gate. Replaced on every Digiroad fetch.
    private var digiroadSegments: [DigiroadCachedSegment] = []

    /// Cached list of all VMS speed-limit signs nationwide. Refreshed on
    /// the VMS cadence; nearest-sign lookup runs on every coord change.
    private var vmsSigns: [VMSSign] = []
    private var vmsLastFetch: Date?

    private var ticker: Task<Void, Never>?
    private var lastOSMQueriedCoord: CLLocationCoordinate2D?
    private var lastDigiroadQueriedCoord: CLLocationCoordinate2D?
    private var locationProvider: () -> CLLocation? = { nil }

    init() {
        loadCache()
    }

    func start(locationProvider: @escaping () -> CLLocation?) {
        self.locationProvider = locationProvider
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            guard let self else { return }
            // Initial pulls
            if let loc = self.locationProvider() {
                let coord = loc.coordinate
                async let osm: () = self.fetchOSM(around: loc)
                async let dig: () = self.fetchDigiroad(around: loc)
                async let vms: () = self.refreshVMSList()
                async let apple: () = self.fetchAppleRoadName(at: coord)
                _ = await (osm, dig, vms, apple)
                self.recomputeVMSReading(for: loc)
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { break }
                guard let loc = self.locationProvider() else { continue }
                let coord = loc.coordinate

                if self.shouldRefetchOSM(for: coord) {
                    await self.fetchOSM(around: loc)
                }
                if self.shouldRefetchDigiroad(for: coord) {
                    await self.fetchDigiroad(around: loc)
                }
                if self.shouldRefreshVMS() {
                    await self.refreshVMSList()
                }
                if self.shouldRefetchGeocode(for: coord) {
                    await self.fetchAppleRoadName(at: coord)
                }
                self.recomputeVMSReading(for: loc)
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

    private func fetchOSM(around loc: CLLocation) async {
        let coord = loc.coordinate
        let course: Double? = loc.course >= 0 ? loc.course : nil
        // Drop the `maxspeed` filter: we want road name + ref even on
        // streets without a tagged limit (e.g. residential lanes where
        // Digiroad supplies the limit but OSM has none). Speed-limit
        // selection still filters in-code for ways that *do* have it.
        let query = """
        [out:json][timeout:15];
        way["highway"](around:200,\(coord.latitude),\(coord.longitude));
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
            lastOSMQueriedCoord = coord

            // Road identity: pick the way whose nearest edge is closest to
            // us — course-aligned when we have a valid course — so the
            // bottom-of-map road panel reflects the road we're actually
            // driving, not a parallel one whose vertices happen to sit
            // nearer to our GPS. Without the course filter it falls back
            // to plain edge proximity (slow / stationary cases).
            let nearestRoad = Self.bestEdgeMatch(payload.elements,
                                                 vertices: { Self.coords(for: $0) },
                                                 at: coord, course: course,
                                                 maxDistance: 35,
                                                 courseTolerance: 35)
            let tags = nearestRoad?.tags ?? [:]
            osmRoadName = tags["name"]
            osmRoadRef = tags["ref"] ?? tags["int_ref"]
            rebuildRoadInfo()

            // Speed limit: from the matched way's own tag if present;
            // otherwise pick the closest way *with* maxspeed using the
            // same edge-based projection.
            let limitFromMatched: Int? = {
                guard let raw = nearestRoad?.tags?["maxspeed"] else { return nil }
                return Self.parseMaxspeed(raw)
            }()
            let chosenLimit: Int? = limitFromMatched ?? {
                let withLimit = payload.elements.filter {
                    guard let raw = $0.tags?["maxspeed"] else { return false }
                    return Self.parseMaxspeed(raw) != nil
                }
                let nearest = Self.bestEdgeMatch(withLimit,
                                                 vertices: { Self.coords(for: $0) },
                                                 at: coord, course: course,
                                                 maxDistance: 35,
                                                 courseTolerance: 35)
                guard let raw = nearest?.tags?["maxspeed"] else { return nil }
                return Self.parseMaxspeed(raw)
            }()

            guard let raw = chosenLimit else {
                osmReading = nil
                lastError = nil
                updateCurrent()
                return
            }

            let now = Date()
            let (limit, adjusted) = Self.applyFinlandWinterRule(raw, on: now)
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

    private static func coords(for way: OverpassWay) -> [CLLocationCoordinate2D] {
        (way.geometry ?? []).map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
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

    private func fetchDigiroad(around loc: CLLocation) async {
        let coord = loc.coordinate
        let course: Double? = loc.course >= 0 ? loc.course : nil
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

            // Cache every usable segment (geometry + link_id) so the
            // same-road snapper can resolve arbitrary coords later
            // without a re-fetch.
            digiroadSegments = payload.features.compactMap { feature -> DigiroadCachedSegment? in
                guard let linkId = feature.properties.linkId,
                      let coords = feature.geometry?.coordinates,
                      !coords.isEmpty
                else { return nil }
                let vertices: [CLLocationCoordinate2D] = coords.compactMap {
                    guard $0.count >= 2 else { return nil }
                    return CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0])
                }
                guard !vertices.isEmpty else { return nil }
                return DigiroadCachedSegment(linkId: linkId,
                                             limit: feature.properties.arvo,
                                             vertices: vertices)
            }

            // Pick the segment whose nearest *edge* sits closest to the
            // user, course-aligned when course is valid. Segments with no
            // or out-of-range limit don't qualify (we want a usable limit).
            let candidates = digiroadSegments.filter { seg in
                guard let limit = seg.limit else { return false }
                return (10...130).contains(limit)
            }
            let matched = Self.bestEdgeMatch(candidates,
                                             vertices: { $0.vertices },
                                             at: coord, course: course,
                                             maxDistance: 35,
                                             courseTolerance: 35)

            guard let n = matched, let limit = n.limit else {
                digiroadReading = nil
                lastError = nil
                updateCurrent()
                return
            }

            digiroadReading = Reading(limit: limit,
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

    // MARK: - Apple Maps reverse geocoding (road name)

    /// 50 m movement threshold matches OSM. CLGeocoder is rate-limited
    /// (~1/s safe) so we don't want to call it more often than the
    /// underlying road would change anyway.
    private func shouldRefetchGeocode(for coord: CLLocationCoordinate2D) -> Bool {
        guard let last = lastGeocodedCoord else { return true }
        let here = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        let there = CLLocation(latitude: last.latitude, longitude: last.longitude)
        return here.distance(from: there) > Self.refetchDistanceM
    }

    private func fetchAppleRoadName(at coord: CLLocationCoordinate2D) async {
        let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(loc)
            // `thoroughfare` is the street name (e.g. "Mannerheimintie").
            // Apple doesn't expose road numbers (E18, Vt 7) so we leave
            // ref to OSM.
            appleRoadName = placemarks.first?.thoroughfare
            lastGeocodedCoord = coord
            rebuildRoadInfo()
        } catch {
            // Geocoder failures are common: rate-limit, no network,
            // off-grid coord. Don't clobber the previous name — the
            // panel keeps showing what it last knew.
        }
    }

    /// Recompute the published `currentRoad` from whichever per-source
    /// pieces are currently populated. Apple > OSM for name; OSM owns
    /// ref because Apple doesn't expose it.
    private func rebuildRoadInfo() {
        let name = appleRoadName ?? osmRoadName
        let newRoad = RoadInfo(name: name, ref: osmRoadRef)
        if newRoad != currentRoad { currentRoad = newRoad }
    }

    // MARK: - Road link snap (for speed-camera same-road gate)

    /// Returns the `link_id` of the Digiroad road link nearest to `coord`,
    /// or nil if no segment vertex is within `maxDistance` metres. Useful
    /// for "is the user and the camera on the same road?" checks.
    ///
    /// O(N×V) over cached segments × vertices; N is bounded by the bbox
    /// the service queries (~100–500 segments in dense urban Helsinki),
    /// so this is cheap to call from per-frame paths.
    func linkID(near coord: CLLocationCoordinate2D,
                maxDistance: CLLocationDistance = 30) -> String? {
        let target = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        var bestLink: String?
        var bestDist: CLLocationDistance = .infinity
        for seg in digiroadSegments {
            for v in seg.vertices {
                let d = target.distance(from: CLLocation(latitude: v.latitude, longitude: v.longitude))
                if d < bestDist {
                    bestDist = d
                    bestLink = seg.linkId
                }
            }
        }
        return bestDist <= maxDistance ? bestLink : nil
    }

    /// Edge-based link resolver. Returns the link_id of the Digiroad
    /// segment whose nearest *edge* (line between two consecutive
    /// vertices) sits closest to `coord` — and, when a `course` is
    /// provided, whose edge bearing aligns with that course.
    ///
    /// This is what `SpeedCameraMonitor`'s same-road gate uses, in
    /// preference to the vertex-only `linkID(near:)`. Vertex-only snap
    /// fails at intersections and on parallel roads because the
    /// physically nearest vertex may belong to a different road than
    /// the one we're actually driving on; course alignment + edge
    /// projection picks the correct road of travel.
    func linkID(snappedNear coord: CLLocationCoordinate2D,
                course: Double? = nil,
                maxDistance: CLLocationDistance = 35,
                courseTolerance: Double = 35) -> String? {
        let p = coord
        let mPerLat = 111_320.0
        let mPerLon = 111_320.0 * cos(p.latitude * .pi / 180)

        var bestLink: String?
        var bestDist: Double = .infinity

        for seg in digiroadSegments {
            let verts = seg.vertices
            guard verts.count >= 2 else { continue }
            for i in 0..<(verts.count - 1) {
                let ax = (verts[i].longitude     - p.longitude) * mPerLon
                let ay = (verts[i].latitude      - p.latitude)  * mPerLat
                let bx = (verts[i + 1].longitude - p.longitude) * mPerLon
                let by = (verts[i + 1].latitude  - p.latitude)  * mPerLat

                let abx = bx - ax
                let aby = by - ay
                let len2 = abx * abx + aby * aby
                if len2 < 1e-6 { continue }

                // t = clamp(((P − A)·(B − A)) / |B − A|², 0, 1), P at origin.
                let t = max(0, min(1, (-ax * abx + -ay * aby) / len2))
                let footX = ax + t * abx
                let footY = ay + t * aby
                let dist = sqrt(footX * footX + footY * footY)
                if dist >= bestDist || dist > maxDistance { continue }

                // Course filter — only applied when course is valid.
                if let course {
                    let edgeBearing = ((atan2(abx, aby) * 180 / .pi) + 360)
                        .truncatingRemainder(dividingBy: 360)
                    let reverseBearing = (edgeBearing + 180)
                        .truncatingRemainder(dividingBy: 360)
                    let delta = min(
                        Self.angularDelta(edgeBearing,    course),
                        Self.angularDelta(reverseBearing, course)
                    )
                    if delta > courseTolerance { continue }
                }

                bestDist = dist
                bestLink = seg.linkId
            }
        }
        return bestLink
    }

    // MARK: - Road snap (map-matching)

    /// Project `location` onto the nearest Digiroad road segment whose
    /// edge bearing aligns with the user's course, returning the
    /// perpendicular foot on that edge. Used by the map camera so the
    /// displayed position rides the road centerline even with the small
    /// lateral drift you get from consumer GPS.
    ///
    /// We compare edge bearing to course in both directions (forward + the
    /// reverse) because a road segment can be traversed either way and the
    /// vertex order is arbitrary. A 30° tolerance keeps us from snapping
    /// to a perpendicular road that happens to pass within `maxDistance`.
    ///
    /// Returns nil when the user is genuinely off-road (parking lot, field
    /// outside the cached bbox, gravel turn-off, etc.) — the caller falls
    /// back to the raw GPS coord.
    func snapped(_ location: CLLocation,
                 maxDistance: CLLocationDistance = 35,
                 courseTolerance: Double = 35) -> CLLocationCoordinate2D? {
        // Course can be -1 at low speed / stationary. Don't bail in that
        // case — still pick the nearest road within distance, just skip
        // the bearing-alignment filter. Better to snap to a plausible
        // road than to drift visibly off it while idling at a junction.
        let course: Double? = location.course >= 0 ? location.course : nil
        let p = location.coordinate

        // Local equirectangular frame anchored at `p`. Good enough for
        // segment-scale (a few hundred meters) projection math at Finnish
        // latitudes — the lat/lon scaling stays constant within the
        // search radius.
        let mPerLat = 111_320.0
        let mPerLon = 111_320.0 * cos(p.latitude * .pi / 180)

        var bestFoot: CLLocationCoordinate2D?
        var bestDist: Double = .infinity

        for seg in digiroadSegments {
            let verts = seg.vertices
            guard verts.count >= 2 else { continue }
            for i in 0..<(verts.count - 1) {
                let ax = (verts[i].longitude     - p.longitude) * mPerLon
                let ay = (verts[i].latitude      - p.latitude)  * mPerLat
                let bx = (verts[i + 1].longitude - p.longitude) * mPerLon
                let by = (verts[i + 1].latitude  - p.latitude)  * mPerLat

                let abx = bx - ax
                let aby = by - ay
                let len2 = abx * abx + aby * aby
                if len2 < 1e-6 { continue }

                // t = clamp(((P − A)·(B − A)) / |B − A|², 0, 1), with P at origin.
                let t = max(0, min(1, (-ax * abx + -ay * aby) / len2))
                let footX = ax + t * abx
                let footY = ay + t * aby
                let dist = sqrt(footX * footX + footY * footY)
                if dist >= bestDist || dist > maxDistance { continue }

                // Edge bearing filter — only applied when course is valid.
                if let course {
                    let edgeBearing = ((atan2(abx, aby) * 180 / .pi) + 360)
                        .truncatingRemainder(dividingBy: 360)
                    let reverseBearing = (edgeBearing + 180)
                        .truncatingRemainder(dividingBy: 360)
                    let delta = min(
                        Self.angularDelta(edgeBearing,    course),
                        Self.angularDelta(reverseBearing, course)
                    )
                    if delta > courseTolerance { continue }
                }

                bestDist = dist
                bestFoot = CLLocationCoordinate2D(
                    latitude:  p.latitude  + footY / mPerLat,
                    longitude: p.longitude + footX / mPerLon
                )
            }
        }
        return bestFoot
    }

    private static func angularDelta(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    /// Pick the item in `items` whose nearest *edge* (line between two
    /// consecutive vertices) sits closest to `coord`, with optional
    /// course-bearing alignment. Returns nil when no candidate's edge
    /// projects within `maxDistance`, or when course-filtered out.
    ///
    /// Same algorithm used by `snapped(_:)` and the link-ID resolver —
    /// generalised so OSM ways, Digiroad segments, and any other
    /// vertex-list-bearing data can use it. Avoids the "nearest vertex
    /// belongs to a different road" failure mode that vertex-only snap
    /// produces at intersections and on parallel roads.
    private static func bestEdgeMatch<T>(
        _ items: [T],
        vertices: (T) -> [CLLocationCoordinate2D],
        at coord: CLLocationCoordinate2D,
        course: Double?,
        maxDistance: CLLocationDistance,
        courseTolerance: Double
    ) -> T? {
        let p = coord
        let mPerLat = 111_320.0
        let mPerLon = 111_320.0 * cos(p.latitude * .pi / 180)

        var best: T?
        var bestDist: Double = .infinity

        for item in items {
            let verts = vertices(item)
            guard verts.count >= 2 else { continue }
            for i in 0..<(verts.count - 1) {
                let ax = (verts[i].longitude     - p.longitude) * mPerLon
                let ay = (verts[i].latitude      - p.latitude)  * mPerLat
                let bx = (verts[i + 1].longitude - p.longitude) * mPerLon
                let by = (verts[i + 1].latitude  - p.latitude)  * mPerLat

                let abx = bx - ax
                let aby = by - ay
                let len2 = abx * abx + aby * aby
                if len2 < 1e-6 { continue }

                let t = max(0, min(1, (-ax * abx + -ay * aby) / len2))
                let footX = ax + t * abx
                let footY = ay + t * aby
                let dist = sqrt(footX * footX + footY * footY)
                if dist >= bestDist || dist > maxDistance { continue }

                if let course {
                    let edgeBearing = ((atan2(abx, aby) * 180 / .pi) + 360)
                        .truncatingRemainder(dividingBy: 360)
                    let reverseBearing = (edgeBearing + 180)
                        .truncatingRemainder(dividingBy: 360)
                    let delta = min(
                        angularDelta(edgeBearing,    course),
                        angularDelta(reverseBearing, course)
                    )
                    if delta > courseTolerance { continue }
                }

                bestDist = dist
                best = item
            }
        }
        return best
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

    private func recomputeVMSReading(for loc: CLLocation) {
        let coord = loc.coordinate
        let userLoc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        let course: Double? = loc.course >= 0 ? loc.course : nil

        // Score each in-radius sign two ways:
        //   1. Does it sit on the same Digiroad link as the user?
        //   2. How far is it from the user (raw)?
        // Same-link signs always beat off-link signs. Within each group,
        // we pick by raw proximity. Avoids the "VMS sign on parallel
        // motorway overrides the local 60 limit" failure mode.
        let userLink = linkID(snappedNear: coord, course: course)

        let scored = vmsSigns
            .map { sign -> (sign: VMSSign, sameLink: Bool, dist: CLLocationDistance) in
                let dist = userLoc.distance(from: CLLocation(latitude: sign.coord.latitude,
                                                             longitude: sign.coord.longitude))
                let signLink = self.linkID(snappedNear: sign.coord, course: nil)
                let sameLink = (userLink != nil && signLink == userLink)
                return (sign, sameLink, dist)
            }
            .filter { $0.dist <= Self.vmsRadiusM }

        // Same-link first; within each tier, closest wins.
        let best = scored
            .sorted { (a, b) in
                if a.sameLink != b.sameLink { return a.sameLink }
                return a.dist < b.dist
            }
            .first

        // If we have any same-link sign, use it; otherwise fall back to
        // the absolute closest (covers areas where the user's coord
        // doesn't snap to Digiroad at all, e.g. driveways).
        let chosen: VMSSign? = best.map { $0.sign }

        if let sign = chosen, (best?.sameLink == true || userLink == nil) {
            vmsReading = Reading(limit: sign.limit,
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
    let linkId: String?

    enum CodingKeys: String, CodingKey {
        case arvo
        case linkId = "link_id"
    }
}

/// Lightweight cache of a single Digiroad segment, kept around in
/// `RoadSpeedLimitService` for the same-road snapper to read.
private struct DigiroadCachedSegment {
    let linkId: String
    let limit: Int?
    let vertices: [CLLocationCoordinate2D]
}
