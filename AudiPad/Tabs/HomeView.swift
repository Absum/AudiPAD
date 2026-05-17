import SwiftUI

struct HomeView: View {
    @StateObject private var vehicle = VehicleViewModel()

    private let currentSpeedLimit: TrafficSign = .speedLimit(80)
    private let recentSigns: [TrafficSign] = [
        .speedLimit(80),
        .speedLimit(50),
        .endOfSpeedLimit(50),
        .yield
    ]

    var body: some View {
        // `ZStack(alignment: .top)` pins the VStack to the top of the screen — without
        // this it defaults to `.center` and the whole layout drifts vertically.
        ZStack(alignment: .top) {
            SQ5Colors.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top header: SQ5 brand mark on the left (vertically aligned with the
                // NavRail Audi rings — both centers land at y≈39 from the top), ambient
                // status pills + clock on the right.
                HStack(spacing: 14) {
                    Image("SQ5Logo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 30)

                    Spacer()

                    StatusPill(symbol: "thermometer.medium", value: "23°", caption: "AIR")
                    StatusPill(symbol: "fuelpump.fill",
                               value: "\(Int(vehicle.snapshot.fuelPercent.rounded()))%",
                               caption: "FUEL")
                    Text(Date().formatted(date: .omitted, time: .shortened))
                        .font(SQ5Typography.subtitle)
                        .foregroundStyle(SQ5Colors.textSecondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 26)
                .padding(.top, 24)
                .padding(.bottom, 8)

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
                .padding(.top, 12)
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
                .padding(.bottom, 22)
            }
        }
        .onAppear { vehicle.start() }
        .onDisappear { vehicle.stop() }
    }
}

struct HomeView_Previews: PreviewProvider {
    static var previews: some View {
        HomeView()
            .preferredColorScheme(.dark)
            .previewInterfaceOrientation(.landscapeLeft)
    }
}
