import Foundation

/// Where the dashboard pulls "current vehicle speed" from. ELM327 isn't
/// wired yet (waiting on jailbreak), but the preference shape is here so
/// switching becomes a one-line change once OBD-II lands.
enum SpeedSource: String, CaseIterable, Identifiable {
    case gps
    case obd

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .gps: return "GPS"
        case .obd: return "OBD-II"
        }
    }

    static let defaultsKey = "audipad.speed.source"
}
