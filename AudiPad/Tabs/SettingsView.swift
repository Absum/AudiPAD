import SwiftUI

struct SettingsView: View {
    var body: some View {
        ZStack {
            SQ5Colors.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                SectionHeader(title: "Settings")
                    .padding(.horizontal, 24)
                    .padding(.top, 16)

                VStack(spacing: 0) {
                    SettingsRow(label: "OBD adapter",        value: "ELM327 — not paired")
                    Divider().background(SQ5Colors.border)
                    SettingsRow(label: "Display brightness", value: "Auto")
                    Divider().background(SQ5Colors.border)
                    SettingsRow(label: "Units",              value: "Metric")
                    Divider().background(SQ5Colors.border)
                    SettingsRow(label: "Version",            value: "0.1.0 (1)")
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(SQ5Colors.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(SQ5Colors.border, lineWidth: 1)
                        )
                )
                .padding(.horizontal, 24)

                Spacer()
            }
        }
    }
}

private struct SettingsRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(SQ5Typography.body)
                .foregroundStyle(SQ5Colors.textPrimary)
            Spacer()
            Text(value)
                .font(SQ5Typography.body)
                .foregroundStyle(SQ5Colors.textSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView().preferredColorScheme(.dark)
    }
}
