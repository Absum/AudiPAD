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
                DashcamSaveButton {
                    dashcam.saveLastSeconds(dashcam.saveDurationPref)
                }
                if let ack = dashcam.lastSaveAcknowledged {
                    DashcamSaveAcknowledged(seconds: ack.seconds)
                }
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

/// Panic-save button — locks the previous N seconds of dashcam
/// footage so loop-cleanup won't touch it. Only visible alongside
/// the REC indicator (i.e. while actively recording). Matches the
/// REC dot's visual weight so the pair reads as one control group.
private struct DashcamSaveButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 10, weight: .bold))
                Text("SAVE")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(1.6)
            }
            .foregroundStyle(SQ5Colors.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(SQ5Colors.accent.opacity(0.85), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Brief acknowledgement pill that flashes for ~2.5 s after a save,
/// confirming the duration that was locked. Disappears via
/// DashcamService clearing its `lastSaveAcknowledged` published
/// property.
private struct DashcamSaveAcknowledged: View {
    let seconds: Int

    var body: some View {
        Text("SAVED \(seconds)s")
            .font(.system(size: 10, weight: .heavy))
            .tracking(1.6)
            .foregroundStyle(SQ5Colors.success)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(SQ5Colors.success.opacity(0.15))
            )
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
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
