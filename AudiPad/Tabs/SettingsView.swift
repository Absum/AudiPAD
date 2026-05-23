import SwiftUI
import CoreLocation

struct SettingsView: View {
    @EnvironmentObject private var location: LocationService
    @EnvironmentObject private var traffic: TrafficIncidentService
    @EnvironmentObject private var vehicle: VehicleViewModel
    @EnvironmentObject private var cameraService: SpeedCameraService
    @EnvironmentObject private var roadLimits: RoadSpeedLimitService

    @AppStorage(AlertAudio.enabledDefaultsKey) private var audioAlertsEnabled = true
    @AppStorage(SpeedSource.defaultsKey) private var speedSourceRaw: String = SpeedSource.gps.rawValue
    @AppStorage(NavigatorSettings.showSpeedometerKey) private var showSpeedometer: Bool = true
    @AppStorage(NavigatorSettings.showBoostGaugeKey) private var showBoostGauge: Bool = true
    @AppStorage(MapBasemap.Defaults.basemapKey) private var basemapRaw: String = MapBasemap.Defaults.defaultBasemap.rawValue
    @AppStorage(MapBasemap.Defaults.stadiaKeyKey) private var stadiaApiKey: String = ""

    var body: some View {
        ZStack(alignment: .top) {
            SQ5Colors.background.ignoresSafeArea()

            VStack(spacing: 0) {
                TopBar(fuelPercent: vehicle.snapshot.fuelPercent, showSpeed: true)

                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        statusSection
                        mapSection
                        navigatorSection
                        configSection
                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    // MARK: - Status (diagnostic — proves data is flowing)

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(title: "Status")
                .padding(.bottom, 12)

            VStack(spacing: 0) {
                StatusRow(
                    label: "Location",
                    primary: locationStatusText,
                    secondary: locationDetailText
                )
                Divider().background(SQ5Colors.border)
                StatusRow(
                    label: "Speed cameras",
                    primary: "\(cameraService.cameras.count) loaded",
                    secondary: nearestCameraText
                )
                Divider().background(SQ5Colors.border)
                StatusRow(
                    label: "Traffic incidents",
                    primary: "\(traffic.incidents.count) active in Finland",
                    secondary: trafficStatusText
                )
                Divider().background(SQ5Colors.border)
                StatusRow(
                    label: "Speed limit (road data)",
                    primary: speedLimitPrimaryText,
                    secondary: speedLimitSecondaryText
                )
                Divider().background(SQ5Colors.border)
                StatusRow(
                    label: "Vehicle data",
                    primary: "Simulated",
                    secondary: "ELM327 connects post-jailbreak"
                )
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(SQ5Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(SQ5Colors.border, lineWidth: 1)
                    )
            )
        }
    }

    // MARK: - Navigator (Map-tab specific prefs)

    private var navigatorSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(title: "Navigator")
                .padding(.bottom, 12)

            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Show speedometer")
                            .font(SQ5Typography.body)
                            .foregroundStyle(SQ5Colors.textPrimary)
                        Text("Stylised dial in the Map tab's bottom-left cluster")
                            .font(SQ5Typography.caption)
                            .foregroundStyle(SQ5Colors.textTertiary)
                    }
                    Spacer()
                    Toggle("", isOn: $showSpeedometer)
                        .labelsHidden()
                        .tint(SQ5Colors.accent)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                Divider().background(SQ5Colors.border)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Show boost gauge")
                            .font(SQ5Typography.body)
                            .foregroundStyle(SQ5Colors.textPrimary)
                        Text("Vertical turbo-boost gauge next to the speedometer")
                            .font(SQ5Typography.caption)
                            .foregroundStyle(SQ5Colors.textTertiary)
                    }
                    Spacer()
                    Toggle("", isOn: $showBoostGauge)
                        .labelsHidden()
                        .tint(SQ5Colors.accent)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(SQ5Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(SQ5Colors.border, lineWidth: 1)
                    )
            )
        }
    }

    // MARK: - Map (basemap selection)

    private var mapSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(title: "Map")
                .padding(.bottom, 12)

            VStack(spacing: 0) {
                // Basemap picker — Apple Maps vs Stadia Dark.
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Basemap")
                            .font(SQ5Typography.body)
                            .foregroundStyle(SQ5Colors.textPrimary)
                        Text(basemapHelpText)
                            .font(SQ5Typography.caption)
                            .foregroundStyle(SQ5Colors.textTertiary)
                    }
                    Spacer()
                    Picker("", selection: $basemapRaw) {
                        ForEach(MapBasemap.allCases) { bm in
                            Text(bm.displayName).tag(bm.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(SQ5Colors.accent)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

                Divider().background(SQ5Colors.border)

                // Stadia API key — only relevant when Stadia is
                // picked; surfaced unconditionally so the user can
                // paste a key before flipping the picker.
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Stadia API key")
                            .font(SQ5Typography.body)
                            .foregroundStyle(SQ5Colors.textPrimary)
                        Spacer()
                        Text(stadiaKeyStatusText)
                            .font(SQ5Typography.caption)
                            .foregroundStyle(stadiaKeyStatusColor)
                    }
                    SecureField("Paste key from stadiamaps.com",
                                text: $stadiaApiKey)
                        .textFieldStyle(.plain)
                        .font(SQ5Typography.mono)
                        .foregroundStyle(SQ5Colors.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(SQ5Colors.background)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(SQ5Colors.border, lineWidth: 1)
                                )
                        )
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                    Text("Free at stadiamaps.com → sign up → API keys. ~200K tile loads/month on the free tier covers a daily driver many times over.")
                        .font(SQ5Typography.caption)
                        .foregroundStyle(SQ5Colors.textTertiary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(SQ5Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(SQ5Colors.border, lineWidth: 1)
                    )
            )
        }
    }

    private var basemapHelpText: String {
        switch MapBasemap(rawValue: basemapRaw) ?? .apple {
        case .apple:
            return "Apple Maps with native traffic + POIs. Tile cache opaque."
        case .stadiaDark:
            return stadiaApiKey.isEmpty
                ? "Stadia selected, but no key set — falling back to Apple Maps."
                : "OSM-data dark style. Tiles disk-cached for 30 days; offline-friendly."
        }
    }

    private var stadiaKeyStatusText: String {
        stadiaApiKey.isEmpty ? "Missing" : "Configured"
    }

    private var stadiaKeyStatusColor: Color {
        stadiaApiKey.isEmpty ? SQ5Colors.warning : SQ5Colors.success
    }

    // MARK: - Config (placeholder for now)

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(title: "Configuration")
                .padding(.bottom, 12)

            VStack(spacing: 0) {
                HStack {
                    Text("Audio alerts")
                        .font(SQ5Typography.body)
                        .foregroundStyle(SQ5Colors.textPrimary)
                    Spacer()
                    Toggle("", isOn: $audioAlertsEnabled)
                        .labelsHidden()
                        .tint(SQ5Colors.accent)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                Divider().background(SQ5Colors.border)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Speed source")
                            .font(SQ5Typography.body)
                            .foregroundStyle(SQ5Colors.textPrimary)
                        Text("OBD-II available post-jailbreak via ELM327")
                            .font(SQ5Typography.caption)
                            .foregroundStyle(SQ5Colors.textTertiary)
                    }
                    Spacer()
                    Picker("", selection: $speedSourceRaw) {
                        ForEach(SpeedSource.allCases) { src in
                            Text(src.displayLabel).tag(src.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    .tint(SQ5Colors.accent)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                Divider().background(SQ5Colors.border)
                StatusRow(label: "App version", primary: Self.appVersionString, secondary: nil)
                Divider().background(SQ5Colors.border)
                StatusRow(label: "Display brightness", primary: "Auto", secondary: nil)
                Divider().background(SQ5Colors.border)
                StatusRow(label: "Units", primary: "Metric", secondary: nil)
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(SQ5Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(SQ5Colors.border, lineWidth: 1)
                    )
            )
        }
    }

    // MARK: - Derived display strings

    private var locationStatusText: String {
        switch location.status {
        case .notDetermined: return "Not requested"
        case .restricted:    return "Restricted"
        case .denied:        return "Denied — enable in Settings"
        case .authorizedAlways, .authorizedWhenInUse:
            return location.location == nil ? "Authorized · waiting for fix" : "Authorized · fix acquired"
        @unknown default:    return "Unknown"
        }
    }

    private var locationDetailText: String? {
        guard let coord = location.location?.coordinate else { return nil }
        return String(format: "%.4f, %.4f", coord.latitude, coord.longitude)
    }

    private var nearestCameraText: String? {
        guard let user = location.location?.coordinate ?? Optional(vehicle.snapshot.coordinate)
        else { return nil }
        let here = CLLocation(latitude: user.latitude, longitude: user.longitude)
        let nearest = cameraService.cameras
            .map { ($0, here.distance(from: CLLocation(latitude: $0.coordinate.latitude,
                                                       longitude: $0.coordinate.longitude))) }
            .min { $0.1 < $1.1 }
        guard let n = nearest else { return nil }
        let km = n.1 / 1000.0
        if let updated = cameraService.lastUpdated {
            return String(format: "nearest %.1f km · refreshed %@", km, updated.formatted(date: .omitted, time: .shortened))
        } else {
            return String(format: "nearest %.1f km · using bundled fallback", km)
        }
    }

    private var speedLimitPrimaryText: String {
        guard let r = roadLimits.current else { return "—" }
        return "\(r.limit) km/h"
    }

    private var speedLimitSecondaryText: String? {
        guard let r = roadLimits.current else {
            if let err = roadLimits.lastError { return "fetch failed: \(err)" }
            return "waiting for first fetch"
        }
        var parts: [String] = ["source: \(r.source.rawValue)"]
        if r.appliedSeasonalAdjustment {
            parts.append("winter adjustment applied")
        }
        parts.append("at " + r.timestamp.formatted(date: .omitted, time: .shortened))
        return parts.joined(separator: " · ")
    }

    private var trafficStatusText: String? {
        let user = location.location?.coordinate ?? vehicle.snapshot.coordinate
        let here = CLLocation(latitude: user.latitude, longitude: user.longitude)
        let nearby = traffic.incidents.filter {
            let loc = CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
            return here.distance(from: loc) <= 20_000
        }
        let severe = nearby.filter { $0.severity == .major || $0.severity == .critical }.count
        let parts: [String] = [
            "\(nearby.count) within 20 km",
            "\(severe) severe",
        ]
        if let updated = traffic.lastUpdated {
            return parts.joined(separator: " · ")
                + " · refreshed " + updated.formatted(date: .omitted, time: .shortened)
        } else if let err = traffic.lastError {
            return "fetch failed: \(err)"
        }
        return parts.joined(separator: " · ")
    }

    /// Reads CFBundleShortVersionString + CFBundleVersion from the
    /// Info.plist so this row stays in sync with the values in
    /// project.yml (xcodegen → Info.plist) without us having to edit
    /// the string here on every bump.
    static var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

// MARK: - Pieces

private struct SectionLabel: View {
    let title: String
    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(SQ5Colors.accent)
                .frame(width: 3, height: 14)
            Text(title.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .tracking(2.5)
                .foregroundStyle(SQ5Colors.textSecondary)
            Spacer()
        }
    }
}

private struct StatusRow: View {
    let label: String
    let primary: String
    let secondary: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(SQ5Typography.body)
                    .foregroundStyle(SQ5Colors.textPrimary)
                Spacer()
                Text(primary)
                    .font(SQ5Typography.body)
                    .foregroundStyle(SQ5Colors.textSecondary)
                    .monospacedDigit()
            }
            if let secondary {
                Text(secondary)
                    .font(SQ5Typography.caption)
                    .foregroundStyle(SQ5Colors.textTertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .preferredColorScheme(.dark)
            .previewInterfaceOrientation(.landscapeLeft)
            .environmentObject(LocationService())
            .environmentObject(TrafficIncidentService())
            .environmentObject(VehicleViewModel())
            .environmentObject(SpeedCameraService())
            .environmentObject(RoadSpeedLimitService())
    }
}
