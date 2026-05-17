import SwiftUI

/// Flat "instrument cluster" KPI cell — no background, no border. Use inside an
/// HStack with `KpiDivider` between cells (Audi MMI / VC convention).
struct KpiCell: View {
    let label: String
    let value: String
    var unit: String? = nil
    var symbol: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(SQ5Colors.textTertiary)
                }
                Text(label.uppercased())
                    .font(SQ5Typography.caption)
                    .tracking(1.8)
                    .foregroundStyle(SQ5Colors.textTertiary)
            }

            HStack(alignment: .lastTextBaseline, spacing: 5) {
                Text(value)
                    .font(.system(size: 32, weight: .light, design: .default))
                    .foregroundStyle(SQ5Colors.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit {
                    Text(unit)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(SQ5Colors.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

/// Thin vertical hairline divider between KPI cells.
/// Uses the aluminum-aged color at low opacity for an Audi MMI feel.
/// Explicit height: a bare `Rectangle().frame(width:1)` is greedy in the
/// other axis and would inflate the surrounding HStack to consume all
/// available vertical space in its parent VStack.
struct KpiDivider: View {
    var body: some View {
        Rectangle()
            .fill(SQ5Colors.aluminum.opacity(0.22))
            .frame(width: 1, height: 56)
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
