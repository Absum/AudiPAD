import SwiftUI
import CoreLocation

/// Cross-cutting alert for a nearby severe traffic incident (accident
/// or road closure). Mirrors `SpeedCameraAlertBanner`'s shape so the
/// per-tab placement logic in ContentView works the same way.
struct TrafficAlertBanner: View {
    let incident: TrafficIncident
    let distanceMeters: CLLocationDistance

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(severityColor)
                Image(systemName: categoryIcon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(SQ5Colors.textPrimary)

                HStack(spacing: 6) {
                    Text(distanceLabel)
                        .font(SQ5Typography.subtitle)
                        .foregroundStyle(SQ5Colors.textPrimary)
                        .monospacedDigit()
                    Text("·")
                        .foregroundStyle(SQ5Colors.textTertiary)
                    Text(incident.headline)
                        .font(SQ5Typography.subtitle)
                        .foregroundStyle(SQ5Colors.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(SQ5Colors.surface.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(severityColor, lineWidth: 1.5)
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 3)
    }

    private var headline: String {
        switch incident.category {
        case .accident: return "ACCIDENT AHEAD"
        case .closure:  return "ROAD CLOSED AHEAD"
        }
    }

    private var categoryIcon: String {
        switch incident.category {
        case .accident: return "exclamationmark.triangle.fill"
        case .closure:  return "xmark.octagon.fill"
        }
    }

    private var severityColor: Color {
        switch incident.severity {
        case .minor:    return SQ5Colors.warning
        case .major:    return SQ5Colors.warning
        case .critical: return SQ5Colors.danger
        }
    }

    private var distanceLabel: String {
        if distanceMeters >= 1000 {
            return String(format: "%.1f km", distanceMeters / 1000)
        }
        return "\(Int(distanceMeters)) m"
    }
}
