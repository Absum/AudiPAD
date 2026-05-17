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

            ZStack(alignment: .bottom) {
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
                if let approach = cameras.nearestApproaching {
                    SpeedCameraAlertBanner(approach: approach)
                        .padding(.horizontal, 24)
                        // Sits above the Home now-playing strip when both are
                        // visible; floats a bit higher than the bottom edge on
                        // other tabs — consistent across the app.
                        .padding(.bottom, 110)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(10)
                }
            }
            .animation(.easeOut(duration: 0.3), value: cameras.nearestApproaching != nil)
        }
        .environmentObject(vehicle)
        .environmentObject(locationService)
        .background(SQ5Colors.background.ignoresSafeArea())
        .onReceive(vehicle.$snapshot) { snap in
            cameras.update(vehicle: snap.coordinate)
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
