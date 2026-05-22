import Foundation
import CoreLocation

/// Disk cache for OpenStreetMap Overpass speed-camera responses.
/// Keyed by a bbox-edges-snapped-to-grid string so neighbouring
/// queries (the user drifts a few km within the existing bbox) hit
/// the same entry, and historically-fetched regions are remembered
/// even when the user drives to a new city and back.
///
/// Camera coverage is fairly static (OSM updates trickle in but
/// individual cameras don't appear/disappear weekly), so a 7-day TTL
/// is generous. The existing in-memory + UserDefaults cache covers
/// "show me the most recent set on cold start" — this disk cache
/// is the per-bbox memory that the single-entry UserDefaults cache
/// can't represent (driving Helsinki → Tampere doesn't have to nuke
/// the Helsinki entry).
@MainActor
final class OSMCameraCache {

    static let ttl: TimeInterval = 7 * 24 * 3600

    /// Grid spacing for snapping bbox edges. 0.1° is ~11 km at 60°N
    /// — coarser than DigiroadCache because the Overpass bbox is
    /// already ~100 km wide; finer than that would just multiply
    /// cache files without changing hit rate.
    static let snapGridDeg: Double = 0.1

    private let cacheDir: URL

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.cacheDir = base.appendingPathComponent("audipad/osm-cameras", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir,
                                                 withIntermediateDirectories: true)
    }

    /// Stable cache key from a bbox. Each edge snaps to the grid so
    /// queries that differ by a few hundred meters share the entry.
    static func key(minLon: Double, minLat: Double,
                    maxLon: Double, maxLat: Double) -> String {
        func snap(_ x: Double) -> Int { Int((x / snapGridDeg).rounded()) }
        return "c_\(snap(minLat))_\(snap(minLon))_\(snap(maxLat))_\(snap(maxLon))"
    }

    func load(key: String) -> [SpeedCamera]? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(StoredEntry.self, from: data)
        else { return nil }
        guard Date().timeIntervalSince(entry.fetchedAt) < Self.ttl else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return entry.cameras.map { dto in
            SpeedCamera(
                latitude: dto.lat,
                longitude: dto.lon,
                speedLimit: dto.limit,
                kind: SpeedCamera.Kind(rawValue: dto.kind) ?? .fixed,
                direction: dto.direction
            )
        }
    }

    func store(_ cameras: [SpeedCamera], key: String) {
        let dtos = cameras.map { cam in
            StoredCamera(
                lat: cam.coordinate.latitude,
                lon: cam.coordinate.longitude,
                limit: cam.speedLimit,
                kind: cam.kind.rawValue,
                direction: cam.direction
            )
        }
        let entry = StoredEntry(fetchedAt: Date(), cameras: dtos)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: fileURL(for: key), options: .atomic)
    }

    private func fileURL(for key: String) -> URL {
        cacheDir.appendingPathComponent("\(key).json")
    }

    // MARK: - Stored shape

    private struct StoredEntry: Codable {
        let fetchedAt: Date
        let cameras: [StoredCamera]
    }

    private struct StoredCamera: Codable {
        let lat: Double
        let lon: Double
        let limit: Int
        let kind: String
        let direction: Double?
    }
}
