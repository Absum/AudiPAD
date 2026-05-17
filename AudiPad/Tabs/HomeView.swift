import SwiftUI

struct HomeView: View {
    // Mock state. Replaced by live OBD/CV data once those layers land.
    private let currentSpeedLimit: TrafficSign = .speedLimit(80)
    private let recentSigns: [TrafficSign] = [
        .speedLimit(80),
        .speedLimit(50),
        .endOfSpeedLimit(50),
        .yield
    ]

    var body: some View {
        ZStack {
            SQ5Colors.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // Thin top-right status row (no Audi/SQ5 wordmark — that lives in the NavRail)
                HStack(spacing: 14) {
                    Spacer()
                    StatusPill(symbol: "thermometer.medium", value: "23°", caption: "AIR")
                    StatusPill(symbol: "fuelpump.fill",      value: "65%", caption: "FUEL")
                    Text(Date().formatted(date: .omitted, time: .shortened))
                        .font(SQ5Typography.subtitle)
                        .foregroundStyle(SQ5Colors.textSecondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 26)
                .padding(.top, 18)
                .padding(.bottom, 8)

                // Gauge cluster (Audi-S line: large outer + small center boost), with the
                // current speed-limit sign centered above and the "SQ5" brand mark below
                // the boost gauge.
                ZStack(alignment: .top) {
                    HStack(spacing: 14) {
                        SQ5Gauge(value: 87,
                                 minValue: 0,
                                 maxValue: 240,
                                 label: "Speed",
                                 unit: "km/h",
                                 majorStep: 20)
                            .frame(maxWidth: .infinity)

                        VStack(spacing: 18) {
                            // Boost (CGQB 3.0 V6 BiTDI, stock):
                            // peak ~1.9–2.2 bar absolute (≈ 0.9–1.2 bar gauge/relative).
                            // Range 0–2.5 absolute with redline at 2.0; OBD reports
                            // absolute, so this matches what the live PID will feed in.
                            SQ5Gauge(value: 1.8,
                                     minValue: 0,
                                     maxValue: 2.5,
                                     label: "Boost",
                                     unit: "bar",
                                     redlineStart: 2.0,
                                     majorStep: 0.5,
                                     minorBetween: 1,
                                     formatter: { String(format: "%.1f", $0) })
                                .frame(width: 210)

                            Image("SQ5Logo")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 48)
                        }

                        SQ5Gauge(value: 2400,
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
                        KpiCell(label: "Range",   value: "624", unit: "km",
                                symbol: "fuelpump")
                        KpiDivider()
                        KpiCell(label: "Avg",     value: "8.2", unit: "L/100",
                                symbol: "chart.bar")
                        KpiDivider()
                        KpiCell(label: "Now",     value: "6.7", unit: "L/100",
                                symbol: "drop.fill")
                        KpiDivider()
                        KpiCell(label: "Gear",    value: "D5",
                                symbol: "gearshift.layout.sixspeed")
                        KpiDivider()
                        KpiCell(label: "Coolant", value: "92",  unit: "°C",
                                symbol: "thermometer.medium")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 22)
            }
        }
    }
}

struct HomeView_Previews: PreviewProvider {
    static var previews: some View {
        HomeView()
            .preferredColorScheme(.dark)
            .previewInterfaceOrientation(.landscapeLeft)
    }
}
