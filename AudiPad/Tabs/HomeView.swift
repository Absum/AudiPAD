import SwiftUI

struct HomeView: View {
    var body: some View {
        ZStack {
            SQ5Colors.background.ignoresSafeArea()

            VStack(spacing: 0) {
                BrandBar()

                Rectangle()
                    .fill(SQ5Colors.border)
                    .frame(height: 1)

                // Hero gauges
                HStack(spacing: 18) {
                    SQ5Gauge(value: 87,
                             minValue: 0,
                             maxValue: 240,
                             label: "Speed",
                             unit: "km/h",
                             majorStep: 20)
                        .frame(maxWidth: .infinity)

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
                .padding(.bottom, 12)

                // KPI strip
                HStack(spacing: 10) {
                    KpiTile(label: "Coolant", value: "92",  unit: "°C")
                    KpiTile(label: "Oil",     value: "104", unit: "°C")
                    KpiTile(label: "Boost",   value: "1.4", unit: "bar")
                    KpiTile(label: "Intake",  value: "38",  unit: "°C")
                    KpiTile(label: "Gear",    value: "D5")
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
