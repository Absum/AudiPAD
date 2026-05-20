import Foundation
import Combine
import CoreLocation

/// Fetches live traffic-incident GeoJSON from Digitraffic, parses to
/// `TrafficIncident`s (filtered to accidents + closures only for v1),
/// caches the latest snapshot to UserDefaults, and republishes when
/// the cadence ticks.
///
/// Cadence:
/// - **Moving** (caller's `movingProvider` returns true): every 5 min
/// - **Stopped**: every 15 min
///
/// First emission after `start()` happens immediately so the UI fills
/// in without waiting for a tick.
@MainActor
final class TrafficIncidentService: ObservableObject {
    @Published private(set) var incidents: [TrafficIncident] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var lastError: String?

    /// Digitraffic public traffic-message endpoint. Free, no API key.
    private static let endpoint = URL(
        string: "https://tie.digitraffic.fi/api/traffic-message/v1/messages?inactiveHours=0&includeAreaGeometry=false"
    )!

    private static let cacheKey = "audipad.traffic.incidents.v1"
    private var ticker: Task<Void, Never>?
    private var movingProvider: () -> Bool = { false }

    init() {
        loadCache()
    }

    func start(movingProvider: @escaping () -> Bool) {
        self.movingProvider = movingProvider
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh()
                let interval: Duration = self.movingProvider()
                    ? .seconds(300)   // 5 min while moving
                    : .seconds(900)   // 15 min while stopped
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
    }

    /// Returns the most-restrictive temporary speed limit from any
    /// incident whose Point is within `radiusMeters` of `coord`, or
    /// nil when none apply. Digitraffic gives us only the incident's
    /// centre point — no zone polygon — so we use a fixed radius as
    /// the "you're inside the roadwork" approximation. 250 m comfort-
    /// ably covers the typical Finnish roadwork extent on a motorway
    /// without triggering for events that are just adjacent to the
    /// driver's road.
    func tempSpeedLimit(near coord: CLLocationCoordinate2D,
                        radiusMeters: CLLocationDistance = 250) -> Int? {
        let here = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        var best: Int?
        for inc in incidents {
            guard let limit = inc.tempSpeedLimit else { continue }
            let there = CLLocation(latitude: inc.coordinate.latitude,
                                   longitude: inc.coordinate.longitude)
            guard here.distance(from: there) <= radiusMeters else { continue }
            if best == nil || limit < best! { best = limit }
        }
        return best
    }

    /// True when there's any roadwork-category incident within
    /// `radiusMeters` of `coord`. Used by the road-info panel to
    /// surface a roadworks sign next to the street name.
    func isInRoadworkZone(near coord: CLLocationCoordinate2D,
                         radiusMeters: CLLocationDistance = 250) -> Bool {
        let here = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        return incidents.contains { inc in
            guard inc.category == .roadworks else { return false }
            let there = CLLocation(latitude: inc.coordinate.latitude,
                                   longitude: inc.coordinate.longitude)
            return here.distance(from: there) <= radiusMeters
        }
    }

    func refresh() async {
        do {
            var request = URLRequest(url: Self.endpoint)
            request.setValue("AudiPad/0.1 (github.com/Absum/AudiPAD)", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                self.lastError = "HTTP \(http.statusCode) (\(data.count) bytes)"
                return
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { dec in
                let s = try dec.singleValueContainer().decode(String.self)
                return Self.parseDate(s) ?? Date()
            }
            let payload = try decoder.decode(DigitrafficResponse.self, from: data)

            let now = Date()
            let parsed = payload.features
                .compactMap { TrafficIncident.from($0, now: now) }
                // Stable order by validity start (newest first) for predictable UI
                .sorted { $0.validFrom > $1.validFrom }

            self.incidents = parsed
            self.lastUpdated = now
            self.lastError = nil
            saveCache(parsed)
        } catch let decodingError as DecodingError {
            self.lastError = "Decode: \(Self.describe(decodingError))"
        } catch {
            self.lastError = "Network: \(error.localizedDescription)"
        }
    }

    private static func describe(_ err: DecodingError) -> String {
        switch err {
        case .dataCorrupted(let ctx):       return "dataCorrupted at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")) — \(ctx.debugDescription)"
        case .keyNotFound(let key, let ctx): return "keyNotFound '\(key.stringValue)' at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
        case .typeMismatch(let type, let ctx): return "typeMismatch \(type) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
        case .valueNotFound(let type, let ctx): return "valueNotFound \(type) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
        @unknown default: return "unknown decode error"
        }
    }

    /// Digitraffic uses ISO8601 with optional fractional seconds and
    /// optional `Z`/offset. `.iso8601` strategy doesn't handle the
    /// fractional variant — try both.
    private static func parseDate(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    // MARK: - Cache (UserDefaults)

    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let decoded = try? JSONDecoder().decode([TrafficIncident].self, from: data)
        else { return }
        // Drop any expired-since-last-save before emitting
        let now = Date()
        incidents = decoded.filter { $0.validTo >= now }
    }

    private func saveCache(_ list: [TrafficIncident]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }
}

// MARK: - Digitraffic GeoJSON parsing

/// Minimal `Codable` shape covering the bits of the Digitraffic feed
/// we actually use. The real schema is huge — we ignore most of it.
/// Per-feature decoding is wrapped in `FailableDecodable` so malformed
/// or unexpected features (e.g. Polygon geometries, missing required
/// fields) are silently skipped instead of failing the whole response.
private struct DigitrafficResponse: Decodable {
    let features: [DigitrafficFeature]

    enum CodingKeys: String, CodingKey { case features }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode([FailableDecodable<DigitrafficFeature>].self, forKey: .features)
        self.features = raw.compactMap(\.value)
    }
}

/// Wrapper that yields `nil` instead of throwing when its inner type
/// fails to decode. Lets us tolerate junk entries in an array.
private struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        self.value = try? T(from: decoder)
    }
}

private struct DigitrafficFeature: Decodable {
    let geometry: DigitrafficGeometry?
    let properties: DigitrafficProperties
}

private struct DigitrafficGeometry: Decodable {
    let type: String
    /// For `Point`: `[lon, lat]`. For other geometry types we leave this
    /// nil and the feature is skipped at the mapping step. Decoder is
    /// tolerant: tries `[Double]` first, otherwise stores nil.
    let coordinates: [Double]?

    enum CodingKeys: String, CodingKey { case type, coordinates }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try c.decode(String.self, forKey: .type)
        self.coordinates = try? c.decode([Double].self, forKey: .coordinates)
    }
}

private struct DigitrafficProperties: Decodable {
    let situationId: String
    let situationType: String?
    let trafficAnnouncementType: String?
    let releaseTime: Date?
    let announcements: [DigitrafficAnnouncement]?
}

private struct DigitrafficAnnouncement: Decodable {
    let language: String?
    let title: String?
    let comment: String?
    let timeAndDuration: DigitrafficTimeAndDuration?
    let features: [DigitrafficAnnouncementFeature]?
}

private struct DigitrafficTimeAndDuration: Decodable {
    let startTime: Date?
    let endTime: Date?
}

private struct DigitrafficAnnouncementFeature: Decodable {
    let name: String?
    /// Numeric value when the feature carries one — e.g. for
    /// `Nopeusrajoitus` (speed limit) this is the km/h figure.
    let quantity: Double?
    /// Unit string ("km/h", "t", "m", …) accompanying `quantity`.
    let unit: String?
}

extension TrafficIncident {
    /// Convert a parsed Digitraffic feature into a `TrafficIncident`,
    /// or return nil if it doesn't pass our v1 filters
    /// (not a Point, not an accident/closure, expired, etc.).
    fileprivate static func from(_ feature: DigitrafficFeature, now: Date) -> TrafficIncident? {
        // Geometry — Point only in v1.
        guard let geom = feature.geometry,
              geom.type == "Point",
              let coords = geom.coordinates, coords.count >= 2
        else { return nil }

        let coordinate = CLLocationCoordinate2D(latitude: coords[1], longitude: coords[0])

        // Pick the Finnish announcement (fallback to first available).
        let announcements = feature.properties.announcements ?? []
        let announcement = announcements.first(where: { ($0.language ?? "").uppercased() == "FI" })
            ?? announcements.first
        guard let ann = announcement,
              let title = ann.title, !title.isEmpty
        else { return nil }

        // Category detection. Digitraffic's `trafficAnnouncementType`
        // is null/`GENERAL` for ~99 % of FI features, so the real
        // signal is in `announcements[].features[].name` — which is
        // localised Finnish text, NOT English. The previous English-
        // only `.contains("closed")` filter never matched a single
        // real entry; this rewrite uses the actual wire phrasing.
        let annType = (feature.properties.trafficAnnouncementType ?? "").uppercased()
        let featureNames = (ann.features ?? [])
            .compactMap { $0.name?.lowercased() }

        func matches(_ needles: [String]) -> Bool {
            featureNames.contains { name in
                needles.contains { name.contains($0) }
            }
        }

        let isAccident = annType == "ACCIDENT_REPORT"
            || annType == "PRELIMINARY_ACCIDENT_REPORT"
            || matches(["onnettomuus", "accident"])
        // Full-road closure ONLY — both directions impassable. "Tie
        // on suljettu liikenteeltä" = road is closed. A carriageway
        // closure ("Ajorata on suljettu") still leaves the other
        // carriageway open and reads as roadworks below, not a
        // closure — driver isn't stopped, just slowed and rerouted
        // onto fewer lanes. Same with "Toinen ajorata on suljettu"
        // ("the other carriageway is closed") on divided highways.
        let isClosure = matches([
            "tie on suljettu",
            "road closed",
        ])
        // Lane closures, alternating traffic, temp signals, detours,
        // narrowed lanes, carriageway closures — anything that slows
        // the driver down without actually stopping them. Most
        // Digitraffic FI events fall here.
        let isRoadworks = matches([
            "ajokaista suljettu",          // lane closed
            "ajorata on suljettu",         // carriageway (one of two) closed
            "ohjataan vuorotellen",         // alternating one-lane
            "tilapäinen liikennevalo",      // temp traffic signals
            "pysäytetään ajoittain",        // traffic occasionally stopped
            "kaistoja on kavennettu",       // lanes narrowed
            "kaksisuuntaisena toiselle ajoradalle", // bidirectional on opposite carriageway
            "käytössä kiertotie",           // detour in use
            "kiertotieopastus",             // detour signage
            "roadwork", "construction", "maintenance", "repair",
        ])
        guard isAccident || isClosure || isRoadworks else { return nil }

        // Closure trumps roadworks trumps accident for the surfaced
        // category — a roadwork that closes the road reads as a
        // closure, an accident only fires when nothing more severe
        // applies.
        let category: TrafficIncident.Category
        let severity: TrafficIncident.Severity
        if isClosure {
            category = .closure
            severity = .critical
        } else if isAccident {
            category = .accident
            severity = .major
        } else {
            category = .roadworks
            // Roadworks default to `.minor` so they show as map pins
            // but don't trip the severeNearby banner (which fires on
            // `.major`+).
            severity = .minor
        }

        // Validity.
        let validFrom = ann.timeAndDuration?.startTime
            ?? feature.properties.releaseTime
            ?? now
        let validTo = ann.timeAndDuration?.endTime
            ?? validFrom.addingTimeInterval(60 * 60 * 24)   // default: 24 h

        // Drop expired.
        guard validTo >= now else { return nil }

        // Temp speed limit — Digitraffic encodes this as a feature
        // named "Nopeusrajoitus" with `quantity` (km/h) + `unit`
        // ("km/h"). We expose it on the incident so the Map tab's
        // speedometer can override the static Digiroad/OSM limit
        // while the user is inside a roadwork zone.
        let tempSpeedLimit: Int? = (ann.features ?? [])
            .first { f in
                (f.name ?? "").lowercased().contains("nopeusrajoitus")
            }
            .flatMap { f -> Int? in
                guard let q = f.quantity,
                      (f.unit ?? "km/h").lowercased().contains("km") else { return nil }
                return Int(q.rounded())
            }

        return TrafficIncident(
            id: UUID(),
            situationId: feature.properties.situationId,
            coordinate: coordinate,
            severity: severity,
            category: category,
            headline: title,
            detail: ann.comment,
            validFrom: validFrom,
            validTo: validTo,
            tempSpeedLimit: tempSpeedLimit
        )
    }
}
