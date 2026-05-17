import SwiftUI

struct DriveView: View {
    @EnvironmentObject private var vehicle: VehicleViewModel

    var body: some View {
        ZStack(alignment: .top) {
            SQ5Colors.background.ignoresSafeArea()

            VStack(spacing: 0) {
                TopBar(fuelPercent: vehicle.snapshot.fuelPercent)

                // ── POWERTRAIN ─────────────────────────────────────────────
                DriveSectionLabel(title: "Powertrain")
                    .padding(.horizontal, 26)
                    .padding(.top, 8)
                    .padding(.bottom, 10)

                HStack(spacing: 0) {
                    HeroStat(label: "Boost",
                             value: String(format: "%.1f", vehicle.snapshot.boostBar),
                             unit: "bar",
                             progress: vehicle.snapshot.boostBar / 2.5,
                             warnThreshold: 0.8)
                    KpiDivider()
                    HeroStat(label: "Throttle",
                             value: "\(Int((vehicle.snapshot.throttle * 100).rounded()))",
                             unit: "%",
                             progress: vehicle.snapshot.throttle,
                             warnThreshold: 0.85)
                    KpiDivider()
                    HeroStat(label: "Oil Temp",
                             value: "\(Int(vehicle.snapshot.oilC.rounded()))",
                             unit: "°C",
                             progress: vehicle.snapshot.oilC / 140.0,
                             warnThreshold: 0.85)
                }
                .padding(.horizontal, 20)

                // ── LIVE READINGS ──────────────────────────────────────────
                DriveSectionLabel(title: "Live Readings")
                    .padding(.horizontal, 26)
                    .padding(.top, 28)
                    .padding(.bottom, 10)

                Rectangle()
                    .fill(SQ5Colors.aluminum.opacity(0.22))
                    .frame(height: 1)
                    .padding(.horizontal, 34)

                let cols = [GridItem(.flexible(), spacing: 0),
                            GridItem(.flexible(), spacing: 0),
                            GridItem(.flexible(), spacing: 0),
                            GridItem(.flexible(), spacing: 0)]
                LazyVGrid(columns: cols, spacing: 0) {
                    ReadingCell(label: "RPM",
                                value: "\(Int(vehicle.snapshot.rpm.rounded()))")
                    ReadingCell(label: "Speed",
                                value: "\(Int(vehicle.snapshot.speedKph.rounded()))",
                                unit: "km/h")
                    ReadingCell(label: "Gear",
                                value: vehicle.snapshot.gear)
                    ReadingCell(label: "Coolant",
                                value: "\(Int(vehicle.snapshot.coolantC.rounded()))",
                                unit: "°C")
                    ReadingCell(label: "Intake",
                                value: "\(Int(vehicle.snapshot.intakeC.rounded()))",
                                unit: "°C")
                    ReadingCell(label: "Fuel",
                                value: "\(Int(vehicle.snapshot.fuelPercent.rounded()))",
                                unit: "%")
                    ReadingCell(label: "Range",
                                value: "\(Int(vehicle.snapshot.rangeKm.rounded()))",
                                unit: "km")
                    ReadingCell(label: "Now",
                                value: String(format: "%.1f", vehicle.snapshot.nowConsumption),
                                unit: "L/100")
                }
                .padding(.horizontal, 30)
                .padding(.top, 4)

                Spacer()

                // ── CONNECTION FOOTER ──────────────────────────────────────
                HStack(spacing: 8) {
                    Circle()
                        .fill(SQ5Colors.danger)
                        .frame(width: 8, height: 8)
                    Text("ELM327 — not connected · showing simulated data")
                        .font(SQ5Typography.caption)
                        .foregroundStyle(SQ5Colors.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 16)
            }
        }
        .onAppear { vehicle.start() }
    }
}

// MARK: - Drive-tab-local components

private struct DriveSectionLabel: View {
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

/// Large stat with a horizontal fill bar underneath. Bar fades to accent red
/// once `progress` crosses `warnThreshold`.
private struct HeroStat: View {
    let label: String
    let value: String
    let unit: String
    let progress: Double
    var warnThreshold: Double = 0.85

    private var clamped: Double { max(0, min(1, progress)) }
    private var fillColor: Color {
        clamped >= warnThreshold ? SQ5Colors.accent : SQ5Colors.textPrimary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label.uppercased())
                .font(SQ5Typography.caption)
                .tracking(1.8)
                .foregroundStyle(SQ5Colors.textTertiary)

            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: 44, weight: .light, design: .default))
                    .foregroundStyle(SQ5Colors.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.35), value: value)
                Text(unit)
                    .font(SQ5Typography.subtitle)
                    .foregroundStyle(SQ5Colors.textSecondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(SQ5Colors.border)
                        .frame(height: 3)
                    Capsule()
                        .fill(fillColor)
                        .frame(width: max(0, geo.size.width * clamped), height: 3)
                        .animation(.easeOut(duration: 0.4), value: clamped)
                        .animation(.easeInOut(duration: 0.25), value: fillColor)
                }
            }
            .frame(height: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }
}

/// Compact read-only data point — label above, value below, no chrome.
private struct ReadingCell: View {
    let label: String
    let value: String
    var unit: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(SQ5Colors.textTertiary)
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 22, weight: .regular, design: .default))
                    .foregroundStyle(SQ5Colors.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.3), value: value)
                if let unit {
                    Text(unit)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SQ5Colors.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }
}

struct DriveView_Previews: PreviewProvider {
    static var previews: some View {
        DriveView()
            .preferredColorScheme(.dark)
            .previewInterfaceOrientation(.landscapeLeft)
    }
}
