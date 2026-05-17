import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var vehicle: VehicleViewModel

    private let currentSpeedLimit: TrafficSign = .speedLimit(80)
    private let recentSigns: [TrafficSign] = [
        .speedLimit(80),
        .speedBump,
        .stop,
        .speedLimit(50)
    ]

    var body: some View {
        // `ZStack(alignment: .top)` pins the VStack to the top of the screen — without
        // this it defaults to `.center` and the whole layout drifts vertically.
        ZStack(alignment: .top) {
            SQ5Colors.background.ignoresSafeArea()

            VStack(spacing: 0) {
                TopBar(fuelPercent: vehicle.snapshot.fuelPercent)

                // Hero gauges with small Boost gauge in between (Audi S-line cluster style)
                // and the speed-limit sign centered above the whole cluster.
                ZStack(alignment: .top) {
                    HStack(spacing: 14) {
                        SQ5Gauge(value: vehicle.snapshot.speedKph,
                                 minValue: 0,
                                 maxValue: 240,
                                 label: "Speed",
                                 unit: "km/h",
                                 majorStep: 20)
                            .frame(maxWidth: .infinity)

                        // Boost (CGQB 3.0 V6 BiTDI, stock):
                        // peak ~1.9–2.2 bar absolute (≈ 0.9–1.2 bar gauge/relative).
                        // Range 0–2.5 absolute with redline at 2.0; OBD reports
                        // absolute, so this matches what the live PID will feed in.
                        // Dropped 20pt down so the gauge top clears the centered
                        // speed-limit sign overlay.
                        SQ5Gauge(value: vehicle.snapshot.boostBar,
                                 minValue: 0,
                                 maxValue: 2.5,
                                 label: "Boost",
                                 unit: "bar",
                                 redlineStart: 2.0,
                                 majorStep: 0.5,
                                 minorBetween: 1,
                                 formatter: { String(format: "%.1f", $0) })
                            .frame(width: 210)
                            .padding(.top, 40)

                        SQ5Gauge(value: vehicle.snapshot.rpm,
                                 minValue: 0,
                                 maxValue: 7000,
                                 label: "RPM",
                                 unit: nil,
                                 redlineStart: 4500,
                                 majorStep: 1000)
                            .frame(maxWidth: .infinity)
                    }

                    TrafficSignView(sign: currentSpeedLimit)
                        .frame(width: 70, height: 70)
                        .shadow(color: .black.opacity(0.7), radius: 10, x: 0, y: 4)
                        .padding(.top, -8)
                        .accessibilityLabel("Current speed limit")
                }
                .padding(.horizontal, 20)
                .padding(.top, 42)
                .padding(.bottom, 6)

                // Recently detected signs
                RecentSignsStrip(signs: recentSigns, size: 42)
                    .padding(.horizontal, 26)
                    .padding(.bottom, 28)

                // Driver-focused KPI strip — flat cells separated by hairlines,
                // top hairline marks the section (Audi MMI / VC convention).
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(SQ5Colors.aluminum.opacity(0.22))
                        .frame(height: 1)
                        .padding(.horizontal, 14)

                    HStack(spacing: 0) {
                        KpiCell(label: "Range",
                                value: "\(Int(vehicle.snapshot.rangeKm.rounded()))",
                                unit: "km",
                                symbol: "fuelpump")
                        KpiDivider()
                        KpiCell(label: "Avg",
                                value: String(format: "%.1f", vehicle.snapshot.avgConsumption),
                                unit: "L/100",
                                symbol: "chart.bar")
                        KpiDivider()
                        KpiCell(label: "Now",
                                value: String(format: "%.1f", vehicle.snapshot.nowConsumption),
                                unit: "L/100",
                                symbol: "drop.fill")
                        KpiDivider()
                        KpiCell(label: "Gear",
                                value: vehicle.snapshot.gear,
                                symbol: "gearshift.layout.sixspeed")
                        KpiDivider()
                        KpiCell(label: "Coolant",
                                value: "\(Int(vehicle.snapshot.coolantC.rounded()))",
                                unit: "°C",
                                symbol: "thermometer.medium")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

                // Now-playing strip — fills the space at the bottom of Home.
                // Mock data for now; wires up to MPNowPlayingInfoCenter later.
                NowPlayingStrip()
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
            }
        }
        .onAppear { vehicle.start() }
    }
}

// MARK: - Now playing strip (Home bottom)

private struct NowPlayingStrip: View {
    // Mock state — replaced by `MPNowPlayingInfoCenter` once the Media tab's
    // remote-command integration lands.
    private let title = "Forge"
    private let artist = "Justice"
    private let isPlaying = true

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(SQ5Colors.aluminum.opacity(0.22))
                .frame(height: 1)
                .padding(.horizontal, 14)

            HStack(spacing: 14) {
                // Album art (placeholder)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(SQ5Colors.surfaceElevated)
                    .frame(width: 52, height: 52)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(SQ5Colors.textTertiary)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(SQ5Colors.border, lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text("NOW PLAYING")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1.8)
                        .foregroundStyle(SQ5Colors.textTertiary)
                    Text(title)
                        .font(SQ5Typography.subtitle)
                        .foregroundStyle(SQ5Colors.textPrimary)
                        .lineLimit(1)
                    Text(artist)
                        .font(SQ5Typography.caption)
                        .foregroundStyle(SQ5Colors.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 22) {
                    TransportIcon(symbol: "backward.fill", size: 22)
                    TransportIcon(symbol: isPlaying ? "pause.fill" : "play.fill", size: 30)
                    TransportIcon(symbol: "forward.fill", size: 22)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
        }
    }
}

private struct TransportIcon: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(SQ5Colors.textPrimary)
            .frame(width: size + 18, height: size + 18)
            .contentShape(Rectangle())
    }
}

struct HomeView_Previews: PreviewProvider {
    static var previews: some View {
        HomeView()
            .preferredColorScheme(.dark)
            .previewInterfaceOrientation(.landscapeLeft)
    }
}
