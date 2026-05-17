import SwiftUI

struct ContentView: View {
    @State private var selectedTab: AppTab = .home

    /// Shared across all tabs so data is consistent + so cross-cutting
    /// features (speed camera monitor, traffic incidents) can subscribe
    /// to one source.
    @StateObject private var vehicle = VehicleViewModel()
    @StateObject private var cameraService = SpeedCameraService()
    @StateObject private var cameras = SpeedCameraMonitor()
    @StateObject private var locationService = LocationService()
    @StateObject private var traffic = TrafficIncidentService()
    @StateObject private var trafficMonitor = TrafficIncidentMonitor()
    @StateObject private var roadLimits = RoadSpeedLimitService()
    @StateObject private var alertAudio = AlertAudio()

    var body: some View {
        HStack(spacing: 0) {
            NavRail(selection: $selectedTab)

            let placement = AlertPlacement.for(tab: selectedTab)
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
            // Alert as a content overlay — its frame is just the banner
            // size + padding, so it doesn't blanket the tab and steal
            // touches from interactive content (toggles, search, etc.).
            // Camera alerts take priority; traffic incidents surface when
            // no camera alert is active.
            .overlay(alignment: placement.alignment) {
                Group {
                    if let approach = cameras.nearestApproaching {
                        SpeedCameraAlertBanner(approach: approach)
                            .transition(.move(edge: placement.transitionEdge)
                                        .combined(with: .opacity))
                    } else if let incident = trafficMonitor.severeNearby {
                        TrafficAlertBanner(incident: incident,
                                           distanceMeters: trafficMonitor.severeDistanceMeters)
                            .transition(.move(edge: placement.transitionEdge)
                                        .combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, placement.topPadding)
                .padding(.bottom, placement.bottomPadding)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.3), value: cameras.nearestApproaching != nil)
                .animation(.easeOut(duration: 0.3), value: trafficMonitor.severeNearby != nil)
            }
            .animation(.easeInOut(duration: 0.25), value: selectedTab)
        }
        .environmentObject(vehicle)
        .environmentObject(locationService)
        .environmentObject(traffic)
        .environmentObject(cameraService)
        .environmentObject(roadLimits)
        .background(SQ5Colors.background.ignoresSafeArea())
        .onAppear {
            traffic.start(movingProvider: { [weak vehicle] in
                guard let vehicle else { return false }
                return vehicle.snapshot.speedKph > 5
            })
            cameraService.start(userCenterProvider: { [weak locationService, weak vehicle] in
                // Prefer real GPS when available; fall back to simulated
                // vehicle coordinate so the service still works on the
                // bench without location permission.
                locationService?.location?.coordinate ?? vehicle?.snapshot.coordinate
            })
            roadLimits.start(coordProvider: { [weak locationService, weak vehicle] in
                locationService?.location?.coordinate ?? vehicle?.snapshot.coordinate
            })
        }
        .onDisappear {
            traffic.stop()
            cameraService.stop()
            roadLimits.stop()
        }
        .onReceive(vehicle.$snapshot) { snap in
            cameras.update(cameras: cameraService.cameras, vehicle: snap.coordinate)
            trafficMonitor.update(incidents: traffic.incidents,
                                  userLocation: snap.coordinate)
        }
        .onReceive(cameraService.$cameras) { latest in
            cameras.update(cameras: latest, vehicle: vehicle.snapshot.coordinate)
        }
        .onReceive(traffic.$incidents) { incidents in
            trafficMonitor.update(incidents: incidents,
                                  userLocation: vehicle.snapshot.coordinate)
        }
        .onReceive(cameras.$nearestApproaching) { approach in
            // Fires once per camera-id transition, no need to debounce here.
            alertAudio.onSpeedCameraApproach(approach)
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
        case .top:    return 120
        case .bottom: return 0
        }
    }

    /// Bottom padding applied for `.bottom` placement — sits close to the edge.
    var bottomPadding: CGFloat {
        switch self {
        case .top:    return 0
        case .bottom: return 14
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
