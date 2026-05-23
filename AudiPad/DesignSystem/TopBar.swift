import SwiftUI

/// Shared top header used by every tab. SQ5 brand mark on the left,
/// ambient status pills + clock on the right.
///
/// `showSpeed`: tabs without a primary speed gauge (Map / Media /
/// Settings) opt in to a compact speed pill rendered next to the logo,
/// so the driver can glance at current speed from any screen.
struct TopBar: View {
    var fuelPercent: Double = 65
    var showSpeed: Bool = false

    @EnvironmentObject private var location: LocationService
    @EnvironmentObject private var vehicle: VehicleViewModel
    @EnvironmentObject private var dashcam: DashcamService
    @AppStorage(SpeedSource.defaultsKey) private var speedSourceRaw: String = SpeedSource.gps.rawValue

    private var currentSpeedKph: Double {
        switch SpeedSource(rawValue: speedSourceRaw) ?? .gps {
        case .gps:
            guard let s = location.location?.speed, s >= 0 else { return 0 }
            return s * 3.6
        case .obd:
            return vehicle.snapshot.speedKph
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Image("SQ5Logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 30)

            if showSpeed && currentSpeedKph > 0 {
                SpeedPill(kph: currentSpeedKph)
            }

            Spacer()

            if dashcam.isRecording {
                DashcamRECIndicator()
            }

            StatusPill(symbol: "thermometer.medium",
                       value: "23°",
                       caption: "AIR")
            StatusPill(symbol: "fuelpump.fill",
                       value: "\(Int(fuelPercent.rounded()))%",
                       caption: "FUEL")
            Text(Date().formatted(date: .omitted, time: .shortened))
                .font(.system(size: 24, weight: .medium, design: .default))
                .foregroundStyle(SQ5Colors.textSecondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 26)
        .padding(.top, 24)
        .padding(.bottom, 14)
    }
}

/// Pulsing red REC indicator surfaced whenever the dashcam is
/// actively rotating segments. Visible from any tab so the driver
/// always knows recording is on.
private struct DashcamRECIndicator: View {
    @State private var on: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(SQ5Colors.danger)
                .frame(width: 8, height: 8)
                .opacity(on ? 0.4 : 1.0)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                           value: on)
            Text("REC")
                .font(.system(size: 10, weight: .heavy))
                .tracking(1.6)
                .foregroundStyle(SQ5Colors.textSecondary)
        }
        .onAppear { on = true }
    }
}

/// Plain-text speed readout sized to sit beside the clock without
/// adding visual weight. Matches the clock's font + tracking so the
/// two read as siblings rather than competing chrome.
private struct SpeedPill: View {
    let kph: Double

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(Int(kph.rounded()))")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(SQ5Colors.textSecondary)
                .monospacedDigit()
            Text("km/h")
                .font(.system(size: 11, weight: .medium))
                .tracking(0.5)
                .foregroundStyle(SQ5Colors.textTertiary)
        }
    }
}
