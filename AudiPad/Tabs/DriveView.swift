import SwiftUI

struct DriveView: View {
    var body: some View {
        ZStack {
            SQ5Colors.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "Live OBD")
                    .padding(.horizontal, 24)
                    .padding(.top, 16)

                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12)
                        ],
                        spacing: 12
                    ) {
                        ForEach(mockPids) { pid in
                            PidRow(pid: pid)
                        }
                    }
                    .padding(.horizontal, 24)
                }

                StatusBar(connected: false)
            }
        }
    }

    private var mockPids: [MockPid] {
        [
            .init(name: "Engine RPM",      value: "2 400", unit: "rpm"),
            .init(name: "Vehicle speed",   value: "87",    unit: "km/h"),
            .init(name: "Coolant temp",    value: "92",    unit: "°C"),
            .init(name: "Intake temp",     value: "38",    unit: "°C"),
            .init(name: "MAF rate",        value: "21.4",  unit: "g/s"),
            .init(name: "Throttle pos",    value: "18",    unit: "%"),
            .init(name: "Boost pressure",  value: "1.4",   unit: "bar"),
            .init(name: "Fuel level",      value: "65",    unit: "%"),
            .init(name: "Battery voltage", value: "14.2",  unit: "V")
        ]
    }
}

private struct MockPid: Identifiable {
    let id = UUID()
    let name: String
    let value: String
    let unit: String
}

private struct PidRow: View {
    let pid: MockPid

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(pid.name.uppercased())
                .font(SQ5Typography.caption)
                .tracking(1)
                .foregroundStyle(SQ5Colors.textTertiary)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(pid.value)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(SQ5Colors.textPrimary)
                    .monospacedDigit()
                Text(pid.unit)
                    .font(SQ5Typography.caption)
                    .foregroundStyle(SQ5Colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(SQ5Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(SQ5Colors.border, lineWidth: 1)
                )
        )
    }
}

private struct StatusBar: View {
    let connected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connected ? SQ5Colors.success : SQ5Colors.danger)
                .frame(width: 8, height: 8)
            Text(connected
                 ? "ELM327 connected"
                 : "ELM327 not connected — showing mock data")
                .font(SQ5Typography.caption)
                .foregroundStyle(SQ5Colors.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }
}

struct DriveView_Previews: PreviewProvider {
    static var previews: some View {
        DriveView()
            .preferredColorScheme(.dark)
            .previewInterfaceOrientation(.landscapeLeft)
    }
}
