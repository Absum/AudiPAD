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

                HStack(spacing: 20) {
                    KpiTile(label: "Speed", value: "87", unit: "km/h", emphasis: .hero)
                    KpiTile(label: "RPM", value: "2 400", unit: nil, emphasis: .hero)
                }
                .padding(20)

                HStack(spacing: 12) {
                    KpiTile(label: "Fuel", value: "65", unit: "%")
                    KpiTile(label: "Coolant", value: "92", unit: "°C")
                    KpiTile(label: "Oil", value: "104", unit: "°C")
                    KpiTile(label: "Boost", value: "1.4", unit: "bar")
                    KpiTile(label: "Gear", value: "D5")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
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
