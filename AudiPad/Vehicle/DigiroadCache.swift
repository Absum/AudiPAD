import Foundation
import CoreLocation

/// Disk cache for Digiroad WFS speed-limit responses. Keyed by a
/// bbox-edges-snapped-to-grid string so neighbouring queries (the
/// around-user fetch as the user drifts a few meters, or a corridor
/// tile vs a future drive of the same road) hit the same entry.
///
/// Designed to be the cold-path of `RoadSpeedLimitService` — the
/// in-memory `digiroadSegments` array is still the hot read for the
/// same-road snap + speedometer feed. The disk cache means that:
///   - Cold-start with a previously-driven location: zero network for
///     speed limits; segments are loaded from disk in < 1 ms.
///   - Steady-state driving in a familiar area: every fetchDigiroad
///     call hits cache, never touches the WFS endpoint, no cellular.
///   - First drive through a new area: same network behaviour as
///     today; cache fills naturally.
///
/// Cache lives in NSCachesDirectory so iOS can reclaim it under
/// storage pressure (the data is reproducible from the WFS endpoint).
/// We never use Documents/ for this — that's iCloud-backup territory
/// and these tiles can be tens of MB after a few months of driving.
@MainActor
final class DigiroadCache {

    /// One cache file per bbox key. 30 days is generous — Digiroad
    /// updates are infrequent (road geometry / speed limits don't
    /// change weekly) and the cost of a stale segment is at worst a
    /// wrong speed-limit reading until the next refresh.
    static let ttl: TimeInterval = 30 * 24 * 3600

    /// Grid spacing for snapping bbox edges. 0.005° is ~550 m at 60°N
    /// — fine enough that two user-area fetches a few meters apart
    /// snap to the same key, coarse enough that the namespace doesn't
    /// explode for cross-country drives.
    static let snapGridDeg: Double = 0.005

    private let cacheDir: URL

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.cacheDir = base.appendingPathComponent("audipad/digiroad", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir,
                                                 withIntermediateDirectories: true)
    }

    /// Build a stable cache key from a WFS bbox. Edges snapped to
    /// `snapGridDeg` so small movements yield the same key.
    static func key(minLon: Double, minLat: Double,
                    maxLon: Double, maxLat: Double) -> String {
        func snap(_ x: Double) -> Int { Int((x / snapGridDeg).rounded()) }
        return "d_\(snap(minLat))_\(snap(minLon))_\(snap(maxLat))_\(snap(maxLon))"
    }

    /// Returns cached segments for `key` if the file exists and is
    /// within TTL; nil otherwise. Decoding is lazy + best-effort —
    /// any failure returns nil and lets the caller fall through to
    /// the network path.
    func load(key: String) -> [DigiroadCachedSegment]? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(StoredEntry.self, from: data)
        else { return nil }
        guard Date().timeIntervalSince(entry.fetchedAt) < Self.ttl else {
            // Expired — best-effort cleanup, ignore failures.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return entry.segments.map { dto in
            DigiroadCachedSegment(
                linkId: dto.linkId,
                limit: dto.limit,
                vertices: dto.vertices.compactMap {
                    $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[1],
                                                           longitude: $0[0]) : nil
                }
            )
        }
    }

    /// Persist segments for `key`. Best-effort — disk pressure or
    /// permission issues silently no-op, which is fine: the cache is
    /// only a perf optimisation, not a correctness requirement.
    func store(_ segments: [DigiroadCachedSegment], key: String) {
        let dtos = segments.map { seg in
            StoredSegment(
                linkId: seg.linkId,
                limit: seg.limit,
                vertices: seg.vertices.map { [$0.longitude, $0.latitude] }
            )
        }
        let entry = StoredEntry(fetchedAt: Date(), segments: dtos)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: fileURL(for: key), options: .atomic)
    }

    private func fileURL(for key: String) -> URL {
        cacheDir.appendingPathComponent("\(key).json")
    }

    // MARK: - Stored shape

    private struct StoredEntry: Codable {
        let fetchedAt: Date
        let segments: [StoredSegment]
    }

    /// On-disk DTO. Vertices are `[lon, lat]` to match the WFS wire
    /// format we already parse — round-trips cleanly.
    private struct StoredSegment: Codable {
        let linkId: String
        let limit: Int?
        let vertices: [[Double]]
    }
}
