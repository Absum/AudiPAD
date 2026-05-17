import SwiftUI

struct KpiTile: View {
    enum Emphasis { case normal, hero }

    let label: String
    let value: String
    var unit: String? = nil
    var symbol: String? = nil
    var emphasis: Emphasis = .normal

    var body: some View {
        VStack(alignment: .leading, spacing: emphasis == .hero ? 14 : 6) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: emphasis == .hero ? 12 : 10, weight: .medium))
                        .foregroundStyle(SQ5Colors.textTertiary)
                }
                Text(label.uppercased())
                    .font(SQ5Typography.caption)
                    .tracking(1.5)
                    .foregroundStyle(SQ5Colors.textTertiary)
            }

            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(value)
                    .font(emphasis == .hero ? SQ5Typography.displayMid : SQ5Typography.title)
                    .foregroundStyle(SQ5Colors.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit {
                    Text(unit)
                        .font(emphasis == .hero ? SQ5Typography.subtitle : SQ5Typography.caption)
                        .foregroundStyle(SQ5Colors.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(emphasis == .hero ? 22 : 14)
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

/// Small icon + value + caption pill used for ambient indicators (air temp, fuel, etc.).
/// Public — used directly in HomeView's top-right status row.
struct StatusPill: View {
    let symbol: String
    let value: String
    let caption: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SQ5Colors.textTertiary)
            VStack(alignment: .leading, spacing: -2) {
                Text(value)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SQ5Colors.textPrimary)
                    .monospacedDigit()
                Text(caption)
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(SQ5Colors.textTertiary)
            }
        }
    }
}
