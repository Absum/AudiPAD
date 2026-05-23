import SwiftUI

/// Racing tab — three independently-toggleable performance trackers.
/// Tracking happens in `RacingService` regardless of which tab is on
/// screen; this view just renders the live state + records.
struct RacingView: View {
    @EnvironmentObject private var racing: RacingService
    @EnvironmentObject private var vehicle: VehicleViewModel

    @AppStorage(RacingService.topSpeedEnabledKey)
    private var topSpeedEnabled: Bool = RacingService.defaultTopSpeedEnabled

    @AppStorage(RacingService.zeroToHundredEnabledKey)
    private var zeroToHundredEnabled: Bool = RacingService.defaultZeroToHundredEnabled

    @AppStorage(RacingService.quarterMileEnabledKey)
    private var quarterMileEnabled: Bool = RacingService.defaultQuarterMileEnabled

    var body: some View {
        ZStack(alignment: .top) {
            SQ5Colors.background.ignoresSafeArea()

            VStack(spacing: 0) {
                TopBar(fuelPercent: vehicle.snapshot.fuelPercent, showSpeed: true)

                ScrollView {
                    VStack(spacing: 18) {
                        TopSpeedCard(enabled: $topSpeedEnabled)
                        ZeroToHundredCard(enabled: $zeroToHundredEnabled)
                        QuarterMileCard(enabled: $quarterMileEnabled)
                        Spacer(minLength: 24)
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
            }
        }
    }
}

// MARK: - Top Speed card

private struct TopSpeedCard: View {
    @EnvironmentObject private var racing: RacingService
    @Binding var enabled: Bool

    var body: some View {
        RacingCard(
            title: "TOP SPEED",
            subtitle: "All-time maximum",
            enabled: $enabled,
            onReset: { racing.resetTopSpeed() }
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                StatBlock(
                    label: "RECORD",
                    primary: racing.topSpeedRecord.map { String(format: "%.0f", $0.kph) } ?? "—",
                    suffix: "km/h",
                    timestamp: racing.topSpeedRecord?.recordedAt,
                    accent: true
                )
                StatBlock(
                    label: "NOW",
                    primary: String(format: "%.0f", racing.currentKph),
                    suffix: "km/h",
                    timestamp: nil,
                    accent: false
                )
            }
        }
    }
}

// MARK: - 0-100 card

private struct ZeroToHundredCard: View {
    @EnvironmentObject private var racing: RacingService
    @Binding var enabled: Bool

    var body: some View {
        RacingCard(
            title: "0 - 100 KM/H",
            subtitle: "Acceleration from standstill",
            enabled: $enabled,
            onReset: { racing.resetZeroToHundred() }
        ) {
            VStack(spacing: 14) {
                LiveRunRow(stateText: stateText, elapsed: racing.zeroToHundredElapsed)
                Divider().background(SQ5Colors.border)
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    StatBlock(
                        label: "BEST",
                        primary: racing.zeroToHundredBest.map { formatTime($0.seconds) } ?? "—",
                        suffix: "s",
                        timestamp: racing.zeroToHundredBest?.recordedAt,
                        accent: true
                    )
                    StatBlock(
                        label: "LAST",
                        primary: racing.zeroToHundredLast.map { formatTime($0.seconds) } ?? "—",
                        suffix: "s",
                        timestamp: racing.zeroToHundredLast?.recordedAt,
                        accent: false
                    )
                }
            }
        }
    }

    private var stateText: String {
        switch racing.zeroToHundredState {
        case .armingForStop: return "Stop the car to arm the next run"
        case .armed:         return "Armed — floor it!"
        case .running:       return "RUNNING"
        case .completed:     return "Done — come to a stop to arm again"
        }
    }
}

// MARK: - ¼ Mile card

private struct QuarterMileCard: View {
    @EnvironmentObject private var racing: RacingService
    @Binding var enabled: Bool

    private static let target: Double = 402.336

    var body: some View {
        RacingCard(
            title: "¼ MILE",
            subtitle: "Time + trap speed over 402 m",
            enabled: $enabled,
            onReset: { racing.resetQuarterMile() }
        ) {
            VStack(spacing: 14) {
                LiveRunRow(stateText: stateText, elapsed: racing.quarterMileElapsed)
                ProgressBar(progress: racing.quarterMileDistance / Self.target,
                            label: distanceLabel)
                Divider().background(SQ5Colors.border)
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    StatBlock(
                        label: "BEST E.T.",
                        primary: racing.quarterMileBest.map { formatTime($0.seconds) } ?? "—",
                        suffix: "s",
                        timestamp: racing.quarterMileBest?.recordedAt,
                        accent: true
                    )
                    StatBlock(
                        label: "BEST TRAP",
                        primary: racing.quarterMileBest.map { String(format: "%.0f", $0.trapKph) } ?? "—",
                        suffix: "km/h",
                        timestamp: nil,
                        accent: true
                    )
                    StatBlock(
                        label: "LAST",
                        primary: racing.quarterMileLast.map { lastSummary($0) } ?? "—",
                        suffix: "",
                        timestamp: racing.quarterMileLast?.recordedAt,
                        accent: false
                    )
                }
            }
        }
    }

    private func lastSummary(_ r: RacingService.QuarterMileRecord) -> String {
        "\(formatTime(r.seconds))s · \(Int(r.trapKph))"
    }

    private var distanceLabel: String {
        let m = Int(racing.quarterMileDistance.rounded())
        return "\(m) / 402 m"
    }

    private var stateText: String {
        switch racing.quarterMileState {
        case .armingForStop: return "Stop the car to arm the next run"
        case .armed:         return "Armed — floor it!"
        case .running:       return "RUNNING"
        case .completed:     return "Done — come to a stop to arm again"
        }
    }
}

// MARK: - Shared sub-components

private struct RacingCard<Content: View>: View {
    let title: String
    let subtitle: String
    @Binding var enabled: Bool
    let onReset: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .heavy))
                        .tracking(2)
                        .foregroundStyle(SQ5Colors.textPrimary)
                    Text(subtitle)
                        .font(SQ5Typography.caption)
                        .foregroundStyle(SQ5Colors.textTertiary)
                }
                Spacer()
                Toggle("", isOn: $enabled)
                    .labelsHidden()
                    .tint(SQ5Colors.accent)
            }

            if enabled {
                content
                HStack {
                    Spacer()
                    Button(action: onReset) {
                        Text("RESET")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(1.6)
                            .foregroundStyle(SQ5Colors.textTertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(SQ5Colors.border, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("Disabled — flip the toggle to start recording.")
                    .font(SQ5Typography.caption)
                    .foregroundStyle(SQ5Colors.textTertiary)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(SQ5Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(enabled ? SQ5Colors.accent.opacity(0.6) : SQ5Colors.border,
                                lineWidth: enabled ? 1.5 : 1)
                )
        )
    }
}

private struct StatBlock: View {
    let label: String
    let primary: String
    let suffix: String
    let timestamp: Date?
    let accent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .heavy))
                .tracking(1.6)
                .foregroundStyle(SQ5Colors.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(primary)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent ? SQ5Colors.accent : SQ5Colors.textPrimary)
                    .monospacedDigit()
                if !suffix.isEmpty {
                    Text(suffix)
                        .font(SQ5Typography.caption)
                        .foregroundStyle(SQ5Colors.textTertiary)
                }
            }
            if let timestamp {
                Text(Self.relativeFormatter.localizedString(for: timestamp, relativeTo: Date()))
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(SQ5Colors.textTertiary)
            } else {
                Spacer().frame(height: 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

private struct LiveRunRow: View {
    let stateText: String
    let elapsed: Double

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(stateText)
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(SQ5Colors.textSecondary)
            Spacer()
            Text(elapsed > 0 ? String(format: "%.2fs", elapsed) : "—")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(SQ5Colors.accent)
                .monospacedDigit()
        }
    }
}

private struct ProgressBar: View {
    let progress: Double
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(SQ5Colors.border.opacity(0.5))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(SQ5Colors.accent)
                        .frame(width: geo.size.width * max(0, min(1, progress)))
                }
            }
            .frame(height: 6)
            Text(label)
                .font(SQ5Typography.caption)
                .foregroundStyle(SQ5Colors.textTertiary)
                .monospacedDigit()
        }
    }
}

private func formatTime(_ seconds: Double) -> String {
    String(format: "%.2f", seconds)
}
