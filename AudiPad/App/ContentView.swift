import SwiftUI
import CoreLocation

struct ContentView: View {
    /// Owned by `AudiPadApp` so the URL-scheme deep-link handler can
    /// flip tabs (e.g. `audipad://map` opens us straight on the map
    /// from the Charger-Connected Shortcut). Default is supplied for
    /// previews and any caller that doesn't need external control.
    @Binding var selectedTab: AppTab

    init(selectedTab: Binding<AppTab> = .constant(.home)) {
        self._selectedTab = selectedTab
    }

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
    @StateObject private var signHistory = SignHistoryService()
    @StateObject private var racing = RacingService()
    @StateObject private var motion = MotionService()
    @StateObject private var lapTimer = LapTimerService()
    @StateObject private var dashcam = DashcamService()

    @AppStorage(DashcamService.enabledKey) private var dashcamEnabled: Bool = DashcamService.defaultEnabled

    @Environment(\.scenePhase) private var scenePhase

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
                case .racing:   RacingView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Alert as a content overlay — its frame is just the banner
            // size + padding, so it doesn't blanket the tab and steal
            // touches from interactive content (toggles, search, etc.).
            // Camera alerts take priority; traffic incidents surface when
            // no camera alert is active.
            //
            // Map tab is handled separately — it positions the banner
            // *inside* its own header stack so it slots between the
            // maneuver banner and the Spotify strip while navigating.
            .overlay(alignment: placement.alignment) {
                Group {
                    if selectedTab != .map {
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
        .environmentObject(cameras)
        .environmentObject(roadLimits)
        .environmentObject(signHistory)
        .environmentObject(racing)
        .environmentObject(motion)
        .environmentObject(lapTimer)
        .environmentObject(dashcam)
        .onChange(of: scenePhase) { phase in
            // Pause CoreMotion + dashcam when backgrounded — saves
            // CPU + battery, and AVCaptureSession is required to
            // stop when the app loses foreground anyway.
            switch phase {
            case .active:
                motion.start()
                if dashcamEnabled { dashcam.enable() }
            case .inactive, .background:
                motion.stop()
                dashcam.disable()
            @unknown default:
                break
            }
        }
        .onChange(of: dashcamEnabled) { enabled in
            // User flipped the dashcam toggle in Settings. Honor
            // immediately so they can verify the recording light.
            if enabled { dashcam.enable() } else { dashcam.disable() }
        }
        .background(SQ5Colors.background.ignoresSafeArea())
        .onAppear {
            // Kick the location stack — without this, GPS stays dormant and
            // every consumer below falls back to the simulated vehicle coord.
            locationService.requestPermission()
            // scenePhase's onChange may not fire on initial launch since
            // the value didn't transition — kick motion explicitly here.
            motion.start()
            // Hand the dashcam its overlay data sources before any
            // recording starts, so the burned-in overlay has real
            // speed / road / G-force / GPS the moment a segment
            // begins instead of dashes.
            dashcam.configure(location: locationService,
                              roadLimits: roadLimits,
                              motion: motion)
            // Same caveat for the dashcam — if the user had it on
            // last session and we're cold-launching, enable here.
            if dashcamEnabled { dashcam.enable() }
            // Refresh the segment list so the Settings page shows
            // any segments left over from previous sessions.
            dashcam.refreshSegments()
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
            roadLimits.start(locationProvider: { [weak locationService, weak vehicle] in
                if let loc = locationService?.location { return loc }
                // Fall back to the simulated vehicle coord with no course
                // signal so the speed-limit lookup degrades gracefully
                // to plain edge proximity on the bench.
                guard let snap = vehicle?.snapshot else { return nil }
                return CLLocation(latitude: snap.coordinate.latitude,
                                  longitude: snap.coordinate.longitude)
            })
            signHistory.subscribe(to: roadLimits.$current)
        }
        .onDisappear {
            traffic.stop()
            cameraService.stop()
            roadLimits.stop()
        }
        .onReceive(vehicle.$snapshot) { snap in
            // Traffic uses a 20 km radius so mock-vs-GPS is forgiving; the
            // monitor still works on the bench. Camera approach detection,
            // by contrast, is GPS-only — see the location.$location handler.
            trafficMonitor.update(incidents: traffic.incidents,
                                  userLocation: snap.coordinate)
        }
        .onReceive(locationService.$location) { loc in
            // Camera approach: only evaluate against a real GPS fix. No fix
            // → no banner. The monitor applies speed + heading + camera-
            // facing + same-road gates on top of distance.
            guard let loc else { return }
            cameras.update(cameras: cameraService.cameras,
                           userLocation: loc,
                           linkID: { [roadLimits] coord, course in
                               roadLimits.linkID(snappedNear: coord, course: course)
                           })
            // Racing trackers run continuously while their toggles are
            // on, regardless of which tab is on screen — the user can
            // enable Top Speed once and have it record on any drive.
            racing.applyLocation(loc)
            // Lap timer only does work when a start-finish line has
            // been dropped; checks itself.
            lapTimer.applyLocation(loc)
        }
        .onReceive(cameraService.$cameras) { latest in
            guard let loc = locationService.location else { return }
            cameras.update(cameras: latest,
                           userLocation: loc,
                           linkID: { [roadLimits] coord, course in
                               roadLimits.linkID(snappedNear: coord, course: course)
                           })
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

    /// Top padding applied for `.top` placement — clears TopBar + search
    /// field with a comfortable gap so the banner doesn't feel glued to
    /// the search row.
    var topPadding: CGFloat {
        switch self {
        case .top:    return 130
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
