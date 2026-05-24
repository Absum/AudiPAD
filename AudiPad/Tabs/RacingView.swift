import SwiftUI

/// Racing tab — three independent trackers presented in the same
/// typographic language as the Drive tab: no card chrome, hairline
/// rules between sections, big light SF values, small uppercase
/// tracked labels. Fits the iPad landscape viewport without scroll.
struct RacingView: View {
    @EnvironmentObject private var racing: RacingService
    @EnvironmentObject private var vehicle: VehicleViewModel
    @EnvironmentObject private var motion: MotionService
    @EnvironmentObject private var lapTimer: LapTimerService
    @EnvironmentObject private var location: LocationService

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

                topSpeedSection
                Hairline()
                zeroToHundredSection
                Hairline()
                quarterMileSection
                Hairline()
                telemetrySection

                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Telemetry row (G-Force + Lap Timer, side-by-side)

    private var telemetrySection: some View {
        HStack(alignment: .top, spacing: 0) {
            gForceColumn
            Rectangle()
                .fill(SQ5Colors.aluminum.opacity(0.22))
                .frame(width: 1)
                .padding(.vertical, 16)
            lapTimerColumn
        }
    }

    // MARK: - G-Force (left half of telemetry row)

    private var gForceColumn: some View {
        VStack(spacing: 0) {
            RacingSectionLabel(
                title: "G-Force",
                subtitle: gForceSubtitle,
                isOn: true,
                onToggle: {},
                onReset: hasGRecord ? { motion.resetPeaks() } : nil,
                hideToggle: true,
                extraTrailing: {
                    AnyView(
                        Button(action: { motion.calibrate() }) {
                            HStack(spacing: 4) {
                                Image(systemName: "scope")
                                    .font(.system(size: 9, weight: .semibold))
                                Text("CAL")
                                    .font(.system(size: 9, weight: .semibold))
                                    .tracking(1.8)
                            }
                            .foregroundStyle(SQ5Colors.textTertiary)
                        }
                        .buttonStyle(.plain)
                    )
                }
            )
            HStack(alignment: .center, spacing: 14) {
                GMeterWidget(
                    lateralG: motion.currentLateralG,
                    longitudinalG: motion.currentLongitudinalG,
                    trail: motion.trail
                )
                .frame(width: 110, height: 110)
                .padding(.leading, 26)
                VStack(alignment: .leading, spacing: 8) {
                    GLineReadout(label: "Peak Lat.",
                                 value: motion.peakLateralG,
                                 accent: true)
                    GLineReadout(label: "Peak Long.",
                                 value: motion.peakLongitudinalG,
                                 accent: true)
                    GLineReadout(label: "Peak Combined",
                                 value: motion.peakCombinedG,
                                 accent: false)
                }
                .padding(.trailing, 26)
                .padding(.vertical, 14)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var hasGRecord: Bool {
        motion.peakLateralG > 0 || motion.peakLongitudinalG > 0 || motion.peakCombinedG > 0
    }

    private var gForceSubtitle: String {
        let mag = sqrt(motion.currentLateralG * motion.currentLateralG
                     + motion.currentLongitudinalG * motion.currentLongitudinalG)
        return String(format: "Live · %.2f g", mag)
    }

    // MARK: - Lap Timer (right half of telemetry row)

    private var lapTimerColumn: some View {
        VStack(spacing: 0) {
            RacingSectionLabel(
                title: "Lap Timer",
                subtitle: lapTimerSubtitle,
                isOn: lapTimer.state != .idle,
                onToggle: {},
                onReset: lapTimer.state != .idle ? { lapTimer.clearLine() } : nil,
                hideToggle: true,
                extraTrailing: {
                    AnyView(
                        Button(action: dropLineTapped) {
                            HStack(spacing: 4) {
                                Image(systemName: lapTimer.state == .idle
                                      ? "flag.fill" : "arrow.counterclockwise")
                                    .font(.system(size: 9, weight: .semibold))
                                Text(lapTimer.state == .idle ? "DROP LINE" : "RE-DROP")
                                    .font(.system(size: 9, weight: .semibold))
                                    .tracking(1.8)
                            }
                            .foregroundStyle(canDropLine ? SQ5Colors.accent : SQ5Colors.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canDropLine)
                    )
                }
            )
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    LapBigReadout(
                        label: lapTimer.state == .running ? "Current Lap" : "Lap Timer",
                        seconds: lapTimer.state == .running ? lapTimer.currentLapElapsed : 0,
                        accent: lapTimer.state == .running
                    )
                }
                .padding(.leading, 26)
                .padding(.vertical, 14)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 8) {
                    LapStatLine(label: "Best",
                                value: lapTimer.bestLapSeconds.map { Self.formatLap($0) } ?? "—",
                                accent: true)
                    LapStatLine(label: "Last",
                                value: lapTimer.lastLapSeconds.map { Self.formatLap($0) } ?? "—",
                                accent: false)
                    LapStatLine(label: "Laps",
                                value: "\(lapTimer.lapCount)",
                                accent: false)
                }
                .padding(.trailing, 26)
                .padding(.vertical, 14)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var canDropLine: Bool {
        // Need a fresh GPS fix with a valid course to capture a
        // meaningful start-line heading.
        guard let loc = location.location else { return false }
        return loc.course >= 0
    }

    private func dropLineTapped() {
        guard let loc = location.location else { return }
        lapTimer.dropLine(at: loc)
    }

    private var lapTimerSubtitle: String {
        switch lapTimer.state {
        case .idle:                  return "Drive then tap Drop Line"
        case .waitingForFirstCross:  return "Line set — cross to start"
        case .running:               return "Running"
        }
    }

    private static func formatLap(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = seconds - Double(mins * 60)
        return mins > 0 ? String(format: "%d:%05.2f", mins, secs)
                        : String(format: "%.2fs", seconds)
    }

    // MARK: - Top Speed

    private var topSpeedSection: some View {
        VStack(spacing: 0) {
            RacingSectionLabel(
                title: "Top Speed",
                subtitle: "All-time memory",
                isOn: topSpeedEnabled,
                onToggle: { topSpeedEnabled.toggle() },
                onReset: racing.topSpeedRecord != nil ? { racing.resetTopSpeed() } : nil
            )
            HStack(spacing: 0) {
                RacingHero(
                    label: "Peak",
                    value: racing.topSpeedRecord.map { String(format: "%.0f", $0.kph) } ?? "—",
                    unit: "km/h",
                    enabled: topSpeedEnabled,
                    accent: true,
                    timestamp: racing.topSpeedRecord?.recordedAt
                )
                KpiDivider()
                RacingHero(
                    label: "Live",
                    value: String(format: "%.0f", racing.currentKph),
                    unit: "km/h",
                    enabled: topSpeedEnabled,
                    accent: false,
                    timestamp: nil
                )
            }
        }
    }

    // MARK: - 0-100

    private var zeroToHundredSection: some View {
        VStack(spacing: 0) {
            RacingSectionLabel(
                title: "0 — 100 km/h",
                subtitle: zeroToHundredStateText,
                isOn: zeroToHundredEnabled,
                onToggle: { zeroToHundredEnabled.toggle() },
                onReset: hasZeroToHundredRecord ? { racing.resetZeroToHundred() } : nil
            )
            HStack(spacing: 0) {
                RacingHero(
                    label: "Best E.T.",
                    value: racing.zeroToHundredBest.map { String(format: "%.2f", $0.seconds) } ?? "—",
                    unit: "s",
                    enabled: zeroToHundredEnabled,
                    accent: true,
                    timestamp: racing.zeroToHundredBest?.recordedAt
                )
                KpiDivider()
                RacingHero(
                    label: "Last Run",
                    value: racing.zeroToHundredLast.map { String(format: "%.2f", $0.seconds) } ?? "—",
                    unit: "s",
                    enabled: zeroToHundredEnabled,
                    accent: false,
                    timestamp: racing.zeroToHundredLast?.recordedAt
                )
                KpiDivider()
                RacingHero(
                    label: "Live",
                    value: (zeroToHundredEnabled && zeroToHundredIsRunning)
                        ? String(format: "%.2f", racing.zeroToHundredElapsed)
                        : "—",
                    unit: "s",
                    enabled: zeroToHundredEnabled,
                    accent: false,
                    pulsing: zeroToHundredIsRunning,
                    timestamp: nil
                )
            }
        }
    }

    private var hasZeroToHundredRecord: Bool {
        racing.zeroToHundredBest != nil || racing.zeroToHundredLast != nil
    }

    private var zeroToHundredIsRunning: Bool {
        if case .running = racing.zeroToHundredState { return true }
        return false
    }

    private var zeroToHundredStateText: String {
        guard zeroToHundredEnabled else { return "Disarmed" }
        switch racing.zeroToHundredState {
        case .armingForStop: return "Stop the car to arm"
        case .armed:         return "Armed — floor it"
        case .running:       return "Running"
        case .completed:     return "Complete — stop to re-arm"
        }
    }

    // MARK: - ¼ Mile

    private static let quarterTargetMeters: Double = 402.336

    private var quarterMileSection: some View {
        VStack(spacing: 0) {
            RacingSectionLabel(
                title: "¼ Mile · 402 m",
                subtitle: quarterMileStateText,
                isOn: quarterMileEnabled,
                onToggle: { quarterMileEnabled.toggle() },
                onReset: hasQuarterMileRecord ? { racing.resetQuarterMile() } : nil
            )
            HStack(spacing: 0) {
                RacingHero(
                    label: "Best E.T.",
                    value: racing.quarterMileBest.map { String(format: "%.2f", $0.seconds) } ?? "—",
                    unit: "s",
                    enabled: quarterMileEnabled,
                    accent: true,
                    timestamp: racing.quarterMileBest?.recordedAt
                )
                KpiDivider()
                RacingHero(
                    label: "Best Trap",
                    value: racing.quarterMileBest.map { String(format: "%.0f", $0.trapKph) } ?? "—",
                    unit: "km/h",
                    enabled: quarterMileEnabled,
                    accent: true,
                    timestamp: nil
                )
                KpiDivider()
                RacingHero(
                    label: "Last",
                    value: racing.quarterMileLast.map { String(format: "%.2f", $0.seconds) } ?? "—",
                    unit: "s",
                    enabled: quarterMileEnabled,
                    accent: false,
                    timestamp: racing.quarterMileLast?.recordedAt
                )
                KpiDivider()
                RacingHero(
                    label: "Live",
                    value: (quarterMileEnabled && quarterMileIsRunning)
                        ? String(format: "%.2f", racing.quarterMileElapsed)
                        : "—",
                    unit: "s",
                    enabled: quarterMileEnabled,
                    accent: false,
                    pulsing: quarterMileIsRunning,
                    timestamp: nil
                )
            }
            // Live distance bar — same hairline language as HeroStat's
            // fill underline, just full-width and ticked.
            QuarterMileProgress(
                progress: racing.quarterMileDistance / Self.quarterTargetMeters,
                meters: racing.quarterMileDistance,
                enabled: quarterMileEnabled
            )
            .padding(.horizontal, 30)
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
    }

    private var hasQuarterMileRecord: Bool {
        racing.quarterMileBest != nil || racing.quarterMileLast != nil
    }

    private var quarterMileIsRunning: Bool {
        if case .running = racing.quarterMileState { return true }
        return false
    }

    private var quarterMileStateText: String {
        guard quarterMileEnabled else { return "Disarmed" }
        switch racing.quarterMileState {
        case .armingForStop: return "Stop the car to arm"
        case .armed:         return "Armed — floor it"
        case .running:       return "Running"
        case .completed:     return "Complete — stop to re-arm"
        }
    }
}

// MARK: - Section label (with inline arm rocker)

/// Mirror of `DriveSectionLabel` from the Drive tab — red accent rule
/// + uppercase tracked title — extended with a subtitle line, an
/// arm/disarm rocker on the trailing edge, and an inline reset.
private struct RacingSectionLabel: View {
    let title: String
    let subtitle: String
    let isOn: Bool
    let onToggle: () -> Void
    /// Nil hides the reset (no record to clear yet).
    let onReset: (() -> Void)?
    /// `true` for sections without an on/off concept (e.g. G-force
    /// is always running while the iPad is mounted).
    var hideToggle: Bool = false
    /// Optional trailing button shown left of the rocker — e.g. the
    /// G-force section's Calibrate.
    var extraTrailing: () -> AnyView = { AnyView(EmptyView()) }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Rectangle()
                .fill(isOn ? SQ5Colors.accent : SQ5Colors.aluminum.opacity(0.4))
                .frame(width: 3, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(2.5)
                    .foregroundStyle(isOn ? SQ5Colors.textSecondary : SQ5Colors.textTertiary)
                Text(subtitle)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(SQ5Colors.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            extraTrailing()
            if let onReset {
                Button(action: onReset) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9, weight: .semibold))
                        Text("RESET")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(1.8)
                    }
                    .foregroundStyle(SQ5Colors.textTertiary)
                }
                .buttonStyle(.plain)
            }
            if !hideToggle {
                ArmRocker(isOn: isOn, onToggle: onToggle)
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }
}

/// Inline two-state pill (DISARMED · ARMED) replacing the iOS-style
/// Toggle. Active half fills with success green for "ARMED", dim for
/// "DISARMED". Reads as a rocker without box chrome — fits the
/// hairline aesthetic.
private struct ArmRocker: View {
    let isOn: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isOn ? SQ5Colors.success : SQ5Colors.textTertiary.opacity(0.5))
                    .frame(width: 7, height: 7)
                    .shadow(color: isOn ? SQ5Colors.success.opacity(0.7) : .clear,
                            radius: isOn ? 4 : 0)
                Text(isOn ? "ARMED" : "DISARMED")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.8)
                    .foregroundStyle(isOn ? SQ5Colors.textPrimary : SQ5Colors.textTertiary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Hero stat (per-tracker readout, mirrors DriveView.HeroStat)

private struct RacingHero: View {
    let label: String
    let value: String
    let unit: String
    let enabled: Bool
    var accent: Bool = false
    /// `true` while a live timer is counting — pulses the value
    /// subtly so the eye knows the number is changing.
    var pulsing: Bool = false
    let timestamp: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(SQ5Typography.caption)
                .tracking(1.8)
                .foregroundStyle(SQ5Colors.textTertiary)

            HStack(alignment: .lastTextBaseline, spacing: 6) {
                // Fixed-width container so the trailing unit Text
                // doesn't jitter horizontally when the value's
                // formatted-string width changes (e.g. "0.00" → "—"
                // → "7.02" → minimum-scaled values). Width is sized
                // to comfortably fit "999.99" at this font + leaves
                // headroom for unit/scale animation.
                Text(value)
                    .font(.system(size: 42, weight: .light, design: .default))
                    .foregroundStyle(valueColor)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(minWidth: 110, alignment: .trailing)
                Text(unit)
                    .font(SQ5Typography.subtitle)
                    .foregroundStyle(SQ5Colors.textSecondary)
                    .opacity(enabled ? 1 : 0.4)
            }

            Text(timestampText)
                .font(.system(size: 9, weight: .regular))
                .tracking(1.2)
                .foregroundStyle(SQ5Colors.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .opacity(enabled ? 1 : 0.35)
        .scaleEffect(pulsing ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.35).repeatForever(autoreverses: true),
                   value: pulsing)
    }

    private var valueColor: Color {
        if !enabled { return SQ5Colors.textTertiary }
        return accent ? SQ5Colors.accent : SQ5Colors.textPrimary
    }

    private var timestampText: String {
        guard let timestamp else { return " " }
        return Self.formatter.localizedString(for: timestamp, relativeTo: Date()).uppercased()
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

// MARK: - Quarter-mile progress (full-width, ticked)

private struct QuarterMileProgress: View {
    let progress: Double
    let meters: Double
    let enabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(SQ5Colors.border)
                        .frame(height: 3)
                    Capsule()
                        .fill(enabled ? SQ5Colors.accent : SQ5Colors.textTertiary)
                        .frame(width: max(0, geo.size.width * clamped), height: 3)
                        .animation(.easeOut(duration: 0.25), value: clamped)
                    // Tick marks at 25/50/75 % — same aluminum hairline
                    // language as KpiDivider.
                    ForEach([0.25, 0.50, 0.75], id: \.self) { fraction in
                        Rectangle()
                            .fill(SQ5Colors.aluminum.opacity(0.35))
                            .frame(width: 1, height: 7)
                            .offset(x: geo.size.width * fraction, y: -2)
                    }
                }
            }
            .frame(height: 7)

            HStack {
                Text("DISTANCE")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.8)
                    .foregroundStyle(SQ5Colors.textTertiary)
                Spacer()
                Text("\(Int(meters.rounded())) / 402 m")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(SQ5Colors.textSecondary)
                    .monospacedDigit()
            }
        }
        .opacity(enabled ? 1 : 0.4)
    }

    private var clamped: Double { max(0, min(1, progress)) }
}

// MARK: - Telemetry-row compact readouts

/// Single-line G-peak readout used in the telemetry row's G-Force
/// column. Tighter than a full RacingHero — the row has limited
/// vertical space because it shares the bottom of the viewport with
/// the Lap Timer column.
private struct GLineReadout: View {
    let label: String
    let value: Double
    let accent: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.8)
                .foregroundStyle(SQ5Colors.textTertiary)
            Spacer(minLength: 12)
            Text(value > 0 ? String(format: "%.2f", value) : "—")
                .font(.system(size: 22, weight: .light, design: .default))
                .foregroundStyle(accent ? SQ5Colors.accent : SQ5Colors.textPrimary)
                .monospacedDigit()
            Text("g")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SQ5Colors.textSecondary)
        }
    }
}

/// Live lap-timer readout — big SF Light counting up while RUNNING.
private struct LapBigReadout: View {
    let label: String
    let seconds: Double
    let accent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(SQ5Typography.caption)
                .tracking(1.8)
                .foregroundStyle(SQ5Colors.textTertiary)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(seconds > 0 ? formatted : "00.00")
                    .font(.system(size: 36, weight: .light, design: .default))
                    .foregroundStyle(accent ? SQ5Colors.accent : SQ5Colors.textTertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("s")
                    .font(SQ5Typography.subtitle)
                    .foregroundStyle(SQ5Colors.textSecondary)
            }
        }
    }

    private var formatted: String {
        let mins = Int(seconds) / 60
        let secs = seconds - Double(mins * 60)
        return mins > 0 ? String(format: "%d:%05.2f", mins, secs)
                        : String(format: "%05.2f", seconds)
    }
}

/// Compact stat line for the Lap Timer column (Best / Last / Laps).
private struct LapStatLine: View {
    let label: String
    let value: String
    let accent: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.8)
                .foregroundStyle(SQ5Colors.textTertiary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 18, weight: .light, design: .default))
                .foregroundStyle(accent ? SQ5Colors.accent : SQ5Colors.textPrimary)
                .monospacedDigit()
        }
    }
}

// MARK: - Section divider

private struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(SQ5Colors.aluminum.opacity(0.22))
            .frame(height: 1)
            .padding(.horizontal, 34)
    }
}
