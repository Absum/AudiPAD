import SwiftUI

enum AppTab: Hashable, CaseIterable {
    case home, drive, map, media, settings

    var label: String {
        switch self {
        case .home:     return "Home"
        case .drive:    return "Drive"
        case .map:      return "Map"
        case .media:    return "Media"
        case .settings: return "Setup"
        }
    }

    var icon: String {
        switch self {
        case .home:     return "gauge.medium"
        case .drive:    return "car.fill"
        case .map:      return "map.fill"
        case .media:    return "play.circle.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct NavRail: View {
    @Binding var selection: AppTab

    var body: some View {
        VStack(spacing: 0) {
            // Logomark at top
            Image("Logomark")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(SQ5Colors.textPrimary)
                .frame(width: 60, height: 22)
                .padding(.top, 28)
                .padding(.bottom, 24)

            // Hairline under logo
            Rectangle()
                .fill(SQ5Colors.border)
                .frame(height: 1)
                .padding(.horizontal, 18)

            // Tabs
            VStack(spacing: 0) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    NavRailButton(
                        tab: tab,
                        isSelected: selection == tab
                    ) {
                        selection = tab
                    }
                }
            }
            .padding(.top, 14)

            Spacer()

            // Footer indicator (placeholder for jailbreak/system status later)
            HStack(spacing: 8) {
                Circle()
                    .fill(SQ5Colors.success)
                    .frame(width: 7, height: 7)
                Text("SYS")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(SQ5Colors.textTertiary)
            }
            .padding(.bottom, 22)
        }
        .frame(width: 110)
        .background(
            SQ5Colors.background
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(SQ5Colors.border)
                        .frame(width: 1)
                }
        )
    }
}

private struct NavRailButton: View {
    let tab: AppTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                // Selection indicator
                Rectangle()
                    .fill(isSelected ? SQ5Colors.accent : Color.clear)
                    .frame(width: 3)

                VStack(spacing: 6) {
                    Image(systemName: tab.icon)
                        .font(.system(size: 26, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? SQ5Colors.textPrimary : SQ5Colors.textTertiary)
                        .frame(height: 30)
                    Text(tab.label.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.8)
                        .foregroundStyle(isSelected ? SQ5Colors.textSecondary : SQ5Colors.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(NavRailButtonStyle(isSelected: isSelected))
    }
}

private struct NavRailButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? SQ5Colors.surfaceElevated
                    : (isSelected ? SQ5Colors.surface.opacity(0.55) : Color.clear)
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct NavRail_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: 0) {
            NavRail(selection: .constant(.home))
            Rectangle().fill(SQ5Colors.surface)
        }
        .frame(width: 1366, height: 1024)
        .background(SQ5Colors.background)
        .previewLayout(.sizeThatFits)
    }
}
