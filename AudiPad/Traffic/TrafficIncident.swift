import Foundation
import CoreLocation

/// A single live road incident (accident or closure) sourced from
/// Fintraffic / Digitraffic. v1 surfaces these as map pins + a banner
/// for the nearest severe one within ~20 km.
struct TrafficIncident: Identifiable, Hashable {
    enum Severity { case minor, major, critical }
    enum Category { case accident, closure, roadworks }

    let id: UUID
    /// Stable identifier from the Digitraffic feed — used for dedup
    /// across refreshes (so reopening an existing incident doesn't
    /// flicker the UI).
    let situationId: String
    let coordinate: CLLocationCoordinate2D
    let severity: Severity
    let category: Category
    /// Short, displayable headline. Localized Finnish from the source.
    let headline: String
    /// Optional longer body text from the source's `comment` field.
    let detail: String?
    let validFrom: Date
    let validTo: Date
    /// Temporary speed limit (km/h) attached to this incident, when
    /// Digitraffic includes a `Nopeusrajoitus` feature. Used by the
    /// Map tab to override the static Digiroad/OSM limit inside an
    /// active roadwork zone — the speedometer ring shrinks to the
    /// roadwork's posted limit.
    let tempSpeedLimit: Int?

    static func == (lhs: TrafficIncident, rhs: TrafficIncident) -> Bool {
        lhs.situationId == rhs.situationId
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(situationId)
    }
}

// MARK: - Codable persistence (for the UserDefaults cache)

extension TrafficIncident: Codable {
    enum CodingKeys: String, CodingKey {
        case id, situationId, latitude, longitude
        case severity, category, headline, detail, validFrom, validTo
        case tempSpeedLimit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.situationId = try c.decode(String.self, forKey: .situationId)
        let lat = try c.decode(Double.self, forKey: .latitude)
        let lon = try c.decode(Double.self, forKey: .longitude)
        self.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        self.severity = try c.decode(Severity.self, forKey: .severity)
        self.category = try c.decode(Category.self, forKey: .category)
        self.headline = try c.decode(String.self, forKey: .headline)
        self.detail = try c.decodeIfPresent(String.self, forKey: .detail)
        self.validFrom = try c.decode(Date.self, forKey: .validFrom)
        self.validTo = try c.decode(Date.self, forKey: .validTo)
        self.tempSpeedLimit = try c.decodeIfPresent(Int.self, forKey: .tempSpeedLimit)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(situationId, forKey: .situationId)
        try c.encode(coordinate.latitude, forKey: .latitude)
        try c.encode(coordinate.longitude, forKey: .longitude)
        try c.encode(severity, forKey: .severity)
        try c.encode(category, forKey: .category)
        try c.encode(headline, forKey: .headline)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encode(validFrom, forKey: .validFrom)
        try c.encode(validTo, forKey: .validTo)
        try c.encodeIfPresent(tempSpeedLimit, forKey: .tempSpeedLimit)
    }
}

extension TrafficIncident.Severity: Codable {}
extension TrafficIncident.Category: Codable {}
