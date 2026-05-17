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

        // Category filter: accident OR feature contains a "RoadClosed".
        let isAccident = (feature.properties.trafficAnnouncementType ?? "")
            .uppercased() == "ACCIDENT_REPORT"
        let isClosure = (ann.features ?? []).contains { f in
            (f.name ?? "").localizedCaseInsensitiveContains("closed")
                || (f.name ?? "").localizedCaseInsensitiveContains("closure")
        }
        guard isAccident || isClosure else { return nil }

        let category: TrafficIncident.Category = isClosure ? .closure : .accident
        let severity: TrafficIncident.Severity = isClosure ? .critical : .major

        // Validity.
        let validFrom = ann.timeAndDuration?.startTime
            ?? feature.properties.releaseTime
            ?? now
        let validTo = ann.timeAndDuration?.endTime
            ?? validFrom.addingTimeInterval(60 * 60 * 24)   // default: 24 h

        // Drop expired.
        guard validTo >= now else { return nil }

        return TrafficIncident(
            id: UUID(),
            situationId: feature.properties.situationId,
            coordinate: coordinate,
            severity: severity,
            category: category,
            headline: title,
            detail: ann.comment,
            validFrom: validFrom,
            validTo: validTo
        )
    }
}
