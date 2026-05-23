import Foundation

/// Which basemap the Map tab should render under the route, car
/// marker, and other overlays. Defaults to Apple Maps so any user
/// upgrading from a pre-Stadia build keeps their existing visual
/// until they actively opt in via Settings.
enum MapBasemap: String, CaseIterable, Identifiable {
    /// Apple Maps — the system default. `showsTraffic = true` works,
    /// 3D buildings + Apple's POI editorial layer are visible.
    case apple
    /// Stadia AlidadeSmoothDark — OSM-data dark style served via
    /// MKTileOverlay with `canReplaceMapContent = true`. Cached on
    /// disk for 30 days per Stadia ToS. Requires an API key entered
    /// in Settings — without one we silently fall back to `apple`.
    case stadiaDark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple:      return "Apple Maps"
        case .stadiaDark: return "Stadia Dark (OSM)"
        }
    }

    /// `@AppStorage` keys + a single shared default. Keeping them
    /// here means the Map tab and Settings tab agree on naming and
    /// nobody can typo a key.
    enum Defaults {
        static let basemapKey  = "audipad.map.basemap"
        static let stadiaKeyKey = "audipad.map.stadia.apiKey"
        static let defaultBasemap = MapBasemap.apple
    }
}
