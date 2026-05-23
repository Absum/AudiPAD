import Foundation
import MapKit

/// MKTileOverlay subclass that serves Stadia Maps' AlidadeSmoothDark
/// raster tiles, with a disk cache in NSCachesDirectory so previously-
/// visited tiles render offline. Stadia's terms allow client-side
/// caching for "reasonable periods" (their docs cite the OSMF policy
/// of ~30 days) for personal use — that's exactly our use case here.
///
/// `canReplaceMapContent = true` tells MKMapView to skip rendering its
/// own basemap where this overlay covers. The route polyline, car
/// annotation, camera + incident pins all sit on top of the overlay
/// via `overlayLevel: .aboveRoads`-style layering, so they keep
/// working byte-for-byte.
final class StadiaTileSource: MKTileOverlay {

    /// 30-day TTL matches the Stadia / OSMF guidance for client-side
    /// tile caching. Past this we re-fetch — keeps map labels and any
    /// style updates from Stadia eventually filtering through.
    static let ttl: TimeInterval = 30 * 24 * 3600

    private let apiKey: String
    private let cacheDir: URL

    init(apiKey: String) {
        self.apiKey = apiKey

        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("audipad/stadia-tiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.cacheDir = dir

        // Stadia AlidadeSmoothDark URL template. `{r}` is an optional
        // suffix for retina (@2x) tiles — we always request retina so
        // the iPad's Retina display gets sharp labels. `512` tile size
        // means MKMapView shows roughly the same content area per
        // tile as Apple's native zoom, just at higher pixel density.
        super.init(urlTemplate: nil)
        self.tileSize = CGSize(width: 512, height: 512)
        self.canReplaceMapContent = true
        // We don't pass a `urlTemplate` to super because the API key
        // is appended via `url(forTilePath:)` below — MKTileOverlay's
        // template engine doesn't substitute custom query params.
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        // AlidadeSmoothDark, retina tiles, with the API key as a
        // query parameter. Stadia accepts the key in either header
        // or query; query is simpler since URLSession sends it
        // automatically with no per-request configuration.
        var components = URLComponents()
        components.scheme = "https"
        components.host = "tiles.stadiamaps.com"
        components.path = "/tiles/alidade_smooth_dark/\(path.z)/\(path.x)/\(path.y)@2x.png"
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        return components.url!
    }

    /// Overridden so we can check the disk cache before going to
    /// the network. Returns image data; MKMapView turns it into a
    /// rendered tile via the system's MKTileOverlayRenderer.
    override func loadTile(at path: MKTileOverlayPath,
                           result: @escaping (Data?, Error?) -> Void) {
        let fileURL = cacheFileURL(for: path)

        // Cache hit + fresh → serve from disk, no network.
        if let data = try? Data(contentsOf: fileURL),
           let fresh = isCacheFresh(fileURL: fileURL),
           fresh {
            result(data, nil)
            return
        }

        // Miss or stale → network fetch, write back on success.
        let url = self.url(forTilePath: path)
        var req = URLRequest(url: url)
        // Stadia requires a User-Agent identifying the application —
        // matches the pattern we use elsewhere in AudiPad.
        req.setValue("AudiPad/0.2 (github.com/Absum/AudiPAD)",
                     forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        let task = URLSession.shared.dataTask(with: req) { data, response, error in
            if let error {
                // Network failure: serve the stale cached tile if we
                // have one — better than a blank square in a tunnel.
                if let stale = try? Data(contentsOf: fileURL) {
                    result(stale, nil)
                } else {
                    result(nil, error)
                }
                return
            }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data
            else {
                if let stale = try? Data(contentsOf: fileURL) {
                    result(stale, nil)
                } else {
                    result(nil, URLError(.badServerResponse))
                }
                return
            }
            // Write to disk (best-effort) and return.
            try? data.write(to: fileURL, options: .atomic)
            result(data, nil)
        }
        task.resume()
    }

    /// Used by MapBackground.applyBasemap to decide whether a
    /// previously-mounted overlay is still valid for the current
    /// stored API key. If the user pastes a new key in Settings we
    /// want the live overlay torn down and recreated.
    func matchesKey(_ key: String) -> Bool { apiKey == key }

    // MARK: - Cache helpers

    /// One file per tile path. We bake the zoom and tile coords into
    /// the filename so the cache is self-describing on inspection.
    private func cacheFileURL(for path: MKTileOverlayPath) -> URL {
        let name = "z\(path.z)_x\(path.x)_y\(path.y)@2x.png"
        return cacheDir.appendingPathComponent(name)
    }

    /// Treat the file's modification date as the cache age. Cheaper
    /// than maintaining a sidecar manifest and accurate enough for
    /// 30-day TTL purposes.
    private func isCacheFresh(fileURL: URL) -> Bool? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let modified = attrs[.modificationDate] as? Date
        else { return nil }
        return Date().timeIntervalSince(modified) < Self.ttl
    }
}
