import SwiftUI

/// Racing tab — three independently-toggleable performance trackers
/// rendered as car-dash instrument panels. Tracking happens in
/// `RacingService` regardless of which tab is on screen; this view
/// just renders the live state + records.
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
                    VStack(spacing: 14) {
                        TopSpeedPanel(enabled: $topSpeedEnabled)
                        ZeroToHundredPanel(enabled: $zeroToHundredEnabled)
                        QuarterMilePanel(enabled: $quarterMileEnabled)
                        Spacer(minLength: 24)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                    .padding(.bottom, 24)
                }
            }
        }
    }
}

// MARK: - Top Speed instrument

private struct TopSpeedPanel: View {
    @EnvironmentObject private var racing: RacingService
    @Binding var enabled: Bool

    var body: some View {
        InstrumentPanel(
            label: "V-MAX",
            subLabel: "TOP SPEED MEMORY",
            statusLED: ledFor(enabled: enabled, isActive: true, hasRecord: racing.topSpeedRecord != nil),
            statePill: statusPill,
            enabled: $enabled,
            onReset: { racing.resetTopSpeed() }
        ) {
            HStack(spacing: 10) {
                LargeDigitReadout(
                    caption: "PEAK",
                    value: racing.topSpeedRecord.map { String(format: "%03.0f", $0.kph) } ?? "---",
                    unit: "km/h",
                    accent: true,
                    enabled: enabled,
                    timestamp: racing.topSpeedRecord?.recordedAt
                )
                LargeDigitReadout(
                    caption: "LIVE",
                    value: String(format: "%03.0f", racing.currentKph),
                    unit: "km/h",
                    accent: false,
                    enabled: enabled,
                    timestamp: nil
                )
            }
        }
    }

    private var statusPill: PanelStatus {
        guard enabled else { return .standby }
        return racing.topSpeedRecord == nil ? .armed("WATCHING") : .recorded("PEAK SET")
    }
}

// MARK: - 0-100 instrument

private struct ZeroToHundredPanel: View {
    @EnvironmentObject private var racing: RacingService
    @Binding var enabled: Bool

    var body: some View {
        InstrumentPanel(
            label: "0 → 100",
            subLabel: "ACCEL TIMER · KM/H",
            statusLED: ledFor(enabled: enabled,
                              isActive: isRunning,
                              hasRecord: racing.zeroToHundredBest != nil),
            statePill: statusPill,
            enabled: $enabled,
            onReset: { racing.resetZeroToHundred() }
        ) {
            VStack(spacing: 10) {
                LiveTimerReadout(
                    isRunning: isRunning,
                    elapsed: racing.zeroToHundredElapsed,
                    enabled: enabled
                )
                HStack(spacing: 8) {
                    LargeDigitReadout(
                        caption: "BEST E.T.",
                        value: racing.zeroToHundredBest.map { String(format: "%.2f", $0.seconds) } ?? "---",
                        unit: "s",
                        accent: true,
                        enabled: enabled,
                        timestamp: racing.zeroToHundredBest?.recordedAt
                    )
                    LargeDigitReadout(
                        caption: "LAST RUN",
                        value: racing.zeroToHundredLast.map { String(format: "%.2f", $0.seconds) } ?? "---",
                        unit: "s",
                        accent: false,
                        enabled: enabled,
                        timestamp: racing.zeroToHundredLast?.recordedAt
                    )
                }
            }
        }
    }

    private var isRunning: Bool {
        if case .running = racing.zeroToHundredState { return true }
        return false
    }

    private var statusPill: PanelStatus {
        guard enabled else { return .standby }
        switch racing.zeroToHundredState {
        case .armingForStop: return .waiting("STOP TO ARM")
        case .armed:         return .armed("ARMED")
        case .running:       return .running("RUNNING")
        case .completed:     return .recorded("COMPLETE")
        }
    }
}

// MARK: - ¼ Mile instrument

private struct QuarterMilePanel: View {
    @EnvironmentObject private var racing: RacingService
    @Binding var enabled: Bool

    private static let target: Double = 402.336

    var body: some View {
        InstrumentPanel(
            label: "¼ MILE",
            subLabel: "QUARTER MILE · 402 m",
            statusLED: ledFor(enabled: enabled,
                              isActive: isRunning,
                              hasRecord: racing.quarterMileBest != nil),
            statePill: statusPill,
            enabled: $enabled,
            onReset: { racing.resetQuarterMile() }
        ) {
            VStack(spacing: 10) {
                LiveTimerReadout(
                    isRunning: isRunning,
                    elapsed: racing.quarterMileElapsed,
                    enabled: enabled
                )
                TickedProgressBar(
                    progress: racing.quarterMileDistance / Self.target,
                    distanceLabel: distanceLabel,
                    enabled: enabled
                )
                HStack(spacing: 8) {
                    LargeDigitReadout(
                        caption: "BEST E.T.",
                        value: racing.quarterMileBest.map { String(format: "%.2f", $0.seconds) } ?? "---",
                        unit: "s",
                        accent: true,
                        enabled: enabled,
                        timestamp: racing.quarterMileBest?.recordedAt
                    )
                    LargeDigitReadout(
                        caption: "BEST TRAP",
                        value: racing.quarterMileBest.map { String(format: "%03.0f", $0.trapKph) } ?? "---",
                        unit: "km/h",
                        accent: true,
                        enabled: enabled,
                        timestamp: nil
                    )
                    LargeDigitReadout(
                        caption: "LAST",
                        value: racing.quarterMileLast.map { String(format: "%.2f", $0.seconds) } ?? "---",
                        unit: "s",
                        accent: false,
                        enabled: enabled,
                        timestamp: racing.quarterMileLast?.recordedAt
                    )
                }
            }
        }
    }

    private var isRunning: Bool {
        if case .running = racing.quarterMileState { return true }
        return false
    }

    private var distanceLabel: String {
        let m = Int(racing.quarterMileDistance.rounded())
        return "\(m) / 402 m"
    }

    private var statusPill: PanelStatus {
        guard enabled else { return .standby }
        switch racing.quarterMileState {
        case .armingForStop: return .waiting("STOP TO ARM")
        case .armed:         return .armed("ARMED")
        case .running:       return .running("RUNNING")
        case .completed:     return .recorded("COMPLETE")
        }
    }
}

// MARK: - Panel chrome

private enum PanelStatus {
    case standby
    case waiting(String)
    case armed(String)
    case running(String)
    case recorded(String)

    var text: String {
        switch self {
        case .standby:                return "STANDBY"
        case .waiting(let s),
             .armed(let s),
             .running(let s),
             .recorded(let s): return s
        }
    }

    var color: Color {
        switch self {
        case .standby:  return SQ5Colors.textTertiary
        case .waiting:  return SQ5Colors.textSecondary
        case .armed:    return SQ5Colors.warning
        case .running:  return SQ5Colors.accent
        case .recorded: return SQ5Colors.success
        }
    }
}

/// Top-right LED in the panel header. Color encodes the panel's
/// overall state at a glance.
private struct StatusLED: View {
    let color: Color
    let glowing: Bool

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: glowing ? color.opacity(0.85) : .clear,
                    radius: glowing ? 4 : 0)
    }
}

private func ledFor(enabled: Bool, isActive: Bool, hasRecord: Bool) -> StatusLED {
    if !enabled {
        return StatusLED(color: SQ5Colors.textTertiary.opacity(0.5), glowing: false)
    }
    if isActive {
        return StatusLED(color: SQ5Colors.accent, glowing: true)
    }
    if hasRecord {
        return StatusLED(color: SQ5Colors.success, glowing: true)
    }
    return StatusLED(color: SQ5Colors.warning, glowing: true)
}

/// Shared instrument-panel chrome. Sharp 4pt corners, thin bezel
/// stroke, dark inset interior, header strip with label + LED, and
/// a footer strip with state pill + rocker switch + reset.
private struct InstrumentPanel<Content: View>: View {
    let label: String
    let subLabel: String
    let statusLED: StatusLED
    let statePill: PanelStatus
    @Binding var enabled: Bool
    let onReset: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            // Header strip
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 16, weight: .heavy, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(SQ5Colors.textPrimary)
                    Text(subLabel)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(SQ5Colors.textTertiary)
                }
                Spacer()
                StatusPillView(status: statePill)
                statusLED
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(SQ5Colors.surfaceElevated)

            Divider().background(SQ5Colors.border)

            // Recessed display area
            content
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SQ5Colors.background.opacity(0.55))

            Divider().background(SQ5Colors.border)

            // Footer strip — channel switch + reset
            HStack(spacing: 12) {
                ChannelSwitch(isOn: $enabled)
                Spacer()
                ResetSwitch(action: onReset, enabled: enabled)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(SQ5Colors.surfaceElevated)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(enabled ? SQ5Colors.accent.opacity(0.55) : SQ5Colors.border,
                        lineWidth: 1)
        )
    }
}

/// Right-hand pill in the header strip showing the panel's current
/// state in one or two words ("ARMED", "RUNNING", "PEAK SET", …).
private struct StatusPillView: View {
    let status: PanelStatus

    var body: some View {
        Text(status.text)
            .font(.system(size: 9, weight: .heavy, design: .monospaced))
            .tracking(1.8)
            .foregroundStyle(status.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .stroke(status.color.opacity(0.6), lineWidth: 1)
            )
    }
}

/// Large monospaced numeric readout — the gauge face. The "recessed
/// behind glass" effect comes from the panel parent's background
/// inset; this view just sets the typography + caption.
private struct LargeDigitReadout: View {
    let caption: String
    let value: String
    let unit: String
    let accent: Bool
    let enabled: Bool
    let timestamp: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption)
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .tracking(1.8)
                .foregroundStyle(SQ5Colors.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .foregroundStyle(valueColor)
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(SQ5Colors.textTertiary)
            }
            Text(timestampLine)
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundStyle(SQ5Colors.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var valueColor: Color {
        guard enabled else { return SQ5Colors.textTertiary }
        return accent ? SQ5Colors.accent : SQ5Colors.textPrimary
    }

    private var timestampLine: String {
        guard let timestamp else { return " " }
        return Self.formatter.localizedString(for: timestamp, relativeTo: Date())
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

/// Live elapsed-time readout for runs in progress. Big monospaced
/// digits, accent color when RUNNING, dimmed when idle.
private struct LiveTimerReadout: View {
    let isRunning: Bool
    let elapsed: Double
    let enabled: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("ELAPSED")
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .tracking(1.8)
                .foregroundStyle(SQ5Colors.textTertiary)
            Spacer()
            Text(elapsed > 0 ? String(format: "%05.2f", elapsed) : "00.00")
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .monospacedDigit()
            Text("s")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(SQ5Colors.textTertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(SQ5Colors.surface)
        .overlay(
            Rectangle()
                .stroke(SQ5Colors.border, lineWidth: 1)
        )
    }

    private var color: Color {
        if !enabled { return SQ5Colors.textTertiary }
        return isRunning ? SQ5Colors.accent : SQ5Colors.textSecondary
    }
}

/// Quarter-mile progress bar with tick marks at the milestones.
private struct TickedProgressBar: View {
    let progress: Double
    let distanceLabel: String
    let enabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("DISTANCE")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(SQ5Colors.textTertiary)
                Spacer()
                Text(distanceLabel)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(enabled ? SQ5Colors.textPrimary : SQ5Colors.textTertiary)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(SQ5Colors.surface)
                    Rectangle()
                        .fill(enabled ? SQ5Colors.accent : SQ5Colors.textTertiary)
                        .frame(width: geo.size.width * max(0, min(1, progress)))
                    // Tick marks at 25 / 50 / 75 %.
                    HStack(spacing: 0) {
                        ForEach([0.25, 0.50, 0.75], id: \.self) { _ in
                            Spacer()
                            Rectangle()
                                .fill(SQ5Colors.border)
                                .frame(width: 1, height: 6)
                                .offset(y: -2)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .overlay(
                    Rectangle()
                        .stroke(SQ5Colors.border, lineWidth: 1)
                )
            }
            .frame(height: 10)
        }
    }
}

/// Custom flat rocker that replaces SwiftUI's iOS-shaped Toggle.
/// Reads as "OFF / ON" — the active segment fills with accent.
private struct ChannelSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 0) {
                segment(text: "OFF", active: !isOn,
                        activeColor: SQ5Colors.textTertiary,
                        textOnActive: SQ5Colors.textPrimary)
                segment(text: "ON", active: isOn,
                        activeColor: SQ5Colors.accent,
                        textOnActive: SQ5Colors.textPrimary)
            }
            .frame(height: 26)
            .overlay(
                Rectangle()
                    .stroke(SQ5Colors.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func segment(text: String, active: Bool,
                         activeColor: Color, textOnActive: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .heavy, design: .monospaced))
            .tracking(2)
            .foregroundStyle(active ? textOnActive : SQ5Colors.textTertiary)
            .frame(width: 44)
            .frame(maxHeight: .infinity)
            .background(active ? activeColor : SQ5Colors.background)
    }
}

/// Tactile-switch styled Reset that visually feels like the panel's
/// own button rather than a generic SwiftUI control.
private struct ResetSwitch: View {
    let action: () -> Void
    let enabled: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 10, weight: .heavy))
                Text("RESET")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .tracking(1.8)
            }
            .foregroundStyle(enabled ? SQ5Colors.textPrimary : SQ5Colors.textTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .overlay(
                Rectangle()
                    .stroke(SQ5Colors.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
