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
                BrandBar()

                Rectangle()
                    .fill(SQ5Colors.border)
                    .frame(height: 1)

                // Hero gauges with small Boost gauge in between (Audi S-line cluster style)
                HStack(spacing: 14) {
                    ZStack(alignment: .topTrailing) {
                        SQ5Gauge(value: 87,
                                 minValue: 0,
                                 maxValue: 240,
                                 label: "Speed",
                                 unit: "km/h",
                                 majorStep: 20)

                        // Audi-VC-style current speed-limit indicator
                        TrafficSignView(sign: currentSpeedLimit)
                            .frame(width: 64, height: 64)
                            .shadow(color: .black.opacity(0.55), radius: 6, x: 0, y: 2)
                            .padding(.top, 10)
                            .padding(.trailing, 18)
                            .accessibilityLabel("Current speed limit")
                    }
                    .frame(maxWidth: .infinity)

                    // Small boost gauge (3.0 TDI biturbo: ~0–2.5 bar, redline ~2.0)
                    SQ5Gauge(value: 1.4,
                             minValue: 0,
                             maxValue: 2.5,
                             label: "Boost",
                             unit: "bar",
                             redlineStart: 2.0,
                             majorStep: 0.5,
                             minorBetween: 1,
                             formatter: { String(format: "%.1f", $0) })
                        .frame(width: 210)

                    SQ5Gauge(value: 2400,
                             minValue: 0,
                             maxValue: 7000,
                             label: "RPM",
                             unit: nil,
                             redlineStart: 4500,
                             majorStep: 1000)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 6)

                // Recently detected signs
                RecentSignsStrip(signs: recentSigns, size: 42)
                    .padding(.horizontal, 26)
                    .padding(.bottom, 10)

                // Driver-focused KPI strip (technical/diagnostic stuff lives in the Drive tab)
                HStack(spacing: 10) {
                    KpiTile(label: "Range",   value: "624", unit: "km",
                            symbol: "fuelpump")
                    KpiTile(label: "Avg",     value: "8.2", unit: "L/100",
                            symbol: "chart.bar")
                    KpiTile(label: "Now",     value: "6.7", unit: "L/100",
                            symbol: "drop.fill")
                    KpiTile(label: "Gear",    value: "D5",
                            symbol: "gearshift.layout.sixspeed")
                    KpiTile(label: "Coolant", value: "92",  unit: "°C",
                            symbol: "thermometer.medium")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
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
