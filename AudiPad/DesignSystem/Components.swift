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

/// Top brand bar — Wordmark (image) + SQ5 accent + clock.
struct BrandBar: View {
    var body: some View {
        HStack(spacing: 16) {
            Image("Wordmark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 24)

            Rectangle()
                .fill(SQ5Colors.aluminum.opacity(0.45))
                .frame(width: 1, height: 22)

            Text("SQ5")
                .font(.system(size: 22, weight: .semibold, design: .default))
                .tracking(4)
                .foregroundStyle(SQ5Colors.accent)

            Spacer()

            HStack(spacing: 14) {
                StatusPill(symbol: "thermometer.medium", value: "23°", caption: "AIR")
                StatusPill(symbol: "fuelpump.fill",      value: "65%", caption: "FUEL")
                Text(Date().formatted(date: .omitted, time: .shortened))
                    .font(SQ5Typography.subtitle)
                    .foregroundStyle(SQ5Colors.textSecondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 16)
    }
}

private struct StatusPill: View {
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
