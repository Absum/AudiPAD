import SwiftUI

/// Shared top header used by Home + Drive (and likely Map/Media/Settings).
/// SQ5 brand mark on the left, ambient status pills + clock on the right.
/// Vertical alignment matches the NavRail Audi rings (both centers at y≈39pt).
struct TopBar: View {
    /// Fuel level (0–100) to display in the FUEL status pill.
    var fuelPercent: Double = 65

    var body: some View {
        HStack(spacing: 14) {
            Image("SQ5Logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 30)

            Spacer()

            StatusPill(symbol: "thermometer.medium",
                       value: "23°",
                       caption: "AIR")
            StatusPill(symbol: "fuelpump.fill",
                       value: "\(Int(fuelPercent.rounded()))%",
                       caption: "FUEL")
            Text(Date().formatted(date: .omitted, time: .shortened))
                .font(SQ5Typography.subtitle)
                .foregroundStyle(SQ5Colors.textSecondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 26)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }
}
