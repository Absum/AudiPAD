import SwiftUI

struct ContentView: View {
    @State private var selectedTab: AppTab = .home

    /// Shared across all tabs so data is consistent + so cross-cutting
    /// features (speed camera monitor) can subscribe to one source.
    @StateObject private var vehicle = VehicleViewModel()
    @StateObject private var cameras = SpeedCameraMonitor()
    @StateObject private var locationService = LocationService()

    var body: some View {
        HStack(spacing: 0) {
            NavRail(selection: $selectedTab)

            ZStack {
                Group {
                    switch selectedTab {
                    case .home:     HomeView()
                    case .drive:    DriveView()
                    case .map:      MapTabView()
                    case .media:    MediaView()
                    case .settings: SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Cross-cutting speed-camera alert. Mounted at the
                // ContentView level so it's visible regardless of selected tab.
                // Placement varies per tab (Map: top under search, others: bottom).
                if let approach = cameras.nearestApproaching {
                    let placement = AlertPlacement.for(tab: selectedTab)
                    SpeedCameraAlertBanner(approach: approach)
                        .padding(.horizontal, 24)
                        .padding(.top, placement.topPadding)
                        .padding(.bottom, placement.bottomPadding)
                        .frame(maxWidth: .infinity,
                               maxHeight: .infinity,
                               alignment: placement.alignment)
                        .allowsHitTesting(false)
                        .transition(.move(edge: placement.transitionEdge)
                                    .combined(with: .opacity))
                        .zIndex(10)
                }
            }
            .animation(.easeOut(duration: 0.3), value: cameras.nearestApproaching != nil)
            .animation(.easeInOut(duration: 0.25), value: selectedTab)
        }
        .environmentObject(vehicle)
        .environmentObject(locationService)
        .background(SQ5Colors.background.ignoresSafeArea())
        .onReceive(vehicle.$snapshot) { snap in
            cameras.update(vehicle: snap.coordinate)
        }
    }
}

// MARK: - Per-tab alert placement

private enum AlertPlacement {
    case top
    case bottom

    static func `for`(tab: AppTab) -> AlertPlacement {
        switch tab {
        case .map: return .top      // sits below the search bar
        default:   return .bottom   // bottom of view on Home/Drive/Media/Settings
        }
    }

    var alignment: Alignment {
        switch self {
        case .top:    return .top
        case .bottom: return .bottom
        }
    }

    var transitionEdge: Edge {
        switch self {
        case .top:    return .top
        case .bottom: return .bottom
        }
    }

    /// Top padding applied for `.top` placement — clears TopBar + search field.
    var topPadding: CGFloat {
        switch self {
        case .top:    return 110
        case .bottom: return 0
        }
    }

    /// Bottom padding applied for `.bottom` placement — sits close to the edge.
    var bottomPadding: CGFloat {
        switch self {
        case .top:    return 0
        case .bottom: return 24
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .preferredColorScheme(.dark)
            .previewInterfaceOrientation(.landscapeLeft)
    }
}
