import SwiftUI

struct KpiTile: View {
    enum Emphasis { case normal, hero }

    let label: String
    let value: String
    var unit: String? = nil
    var emphasis: Emphasis = .normal

    var body: some View {
        VStack(alignment: .leading, spacing: emphasis == .hero ? 14 : 4) {
            Text(label.uppercased())
                .font(SQ5Typography.caption)
                .tracking(1.5)
                .foregroundStyle(SQ5Colors.textTertiary)

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(value)
                    .font(emphasis == .hero ? SQ5Typography.display : SQ5Typography.title)
                    .foregroundStyle(SQ5Colors.textPrimary)
                    .monospacedDigit()
                if let unit {
                    Text(unit)
                        .font(emphasis == .hero ? SQ5Typography.subtitle : SQ5Typography.caption)
                        .foregroundStyle(SQ5Colors.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(emphasis == .hero ? 28 : 16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(SQ5Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(SQ5Colors.border, lineWidth: 1)
                )
        )
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 14) {
            Rectangle()
                .fill(SQ5Colors.accent)
                .frame(width: 4, height: 26)
            Text(title.uppercased())
                .font(SQ5Typography.title)
                .tracking(2)
                .foregroundStyle(SQ5Colors.textPrimary)
        }
    }
}

struct BrandBar: View {
    var body: some View {
        HStack(spacing: 18) {
            Text("AUDI")
                .font(.system(size: 22, weight: .bold))
                .tracking(8)
                .foregroundStyle(SQ5Colors.textPrimary)
            Rectangle()
                .fill(SQ5Colors.aluminum.opacity(0.5))
                .frame(width: 1, height: 22)
            Text("SQ5")
                .font(.system(size: 20, weight: .semibold))
                .tracking(4)
                .foregroundStyle(SQ5Colors.accent)
            Spacer()
            Text(Date().formatted(date: .omitted, time: .shortened))
                .font(SQ5Typography.subtitle)
                .foregroundStyle(SQ5Colors.textSecondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}
