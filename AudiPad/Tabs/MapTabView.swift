import SwiftUI
import MapKit
import Combine
import CoreLocation

struct MapTabView: View {
    @EnvironmentObject private var location: LocationService
    @StateObject private var vm = MapViewModel()
    @StateObject private var completer = SearchCompleter()
    @State private var searchText: String = ""
    @State private var isSearching: Bool = false
    @FocusState private var searchFocused: Bool

    /// Map's current following behavior. Drives both `MKUserTrackingMode`
    /// and the camera pitch.
    @State private var followMode: FollowMode = .none

    enum FollowMode {
        case none           // free pan/zoom
        case follow         // centered on user, no rotation, slight tilt
        case followHeading  // navigation: steep tilt + centered on user

        /// `.followWithHeading` requires active heading updates from a
        /// calibrated compass — unreliable when the device is stationary or
        /// indoor. We use `.follow` for both modes so the user dot is always
        /// centered; the visual difference between `.follow` and
        /// `.followHeading` is the camera pitch.
        var trackingMode: MKUserTrackingMode {
            switch self {
            case .none:                  return .none
            case .follow, .followHeading: return .follow
            }
        }

        var pitch: CGFloat {
            switch self {
            case .none:          return 40
            case .follow:        return 50
            case .followHeading: return 60
            }
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            MapBackground(
                region: $vm.region,
                routePolyline: vm.routePolyline,
                followMode: followMode,
                showsUser: location.isAuthorized,
                onUserInteraction: { followMode = .none }
            )
            .ignoresSafeArea()

            // Top gradient
            LinearGradient(
                colors: [SQ5Colors.background.opacity(0.95),
                         SQ5Colors.background.opacity(0.0)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 160)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)

            // Right-edge floating control stack: center-on-me, zoom in, zoom out
            VStack {
                Spacer()
                MapControls(
                    canCenter: location.isAuthorized && location.location != nil,
                    isFollowing: followMode != .none,
                    onCenter: { centerOnUser() },
                    onZoomIn: { vm.zoomIn() },
                    onZoomOut: { vm.zoomOut() }
                )
                .padding(.trailing, 24)
                .padding(.bottom, vm.routeInfo == nil ? 26 : 150)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 0) {
                TopBar()

                // Search field
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(SQ5Colors.textSecondary)

                    TextField("Destination", text: $searchText)
                        .font(SQ5Typography.body)
                        .foregroundStyle(SQ5Colors.textPrimary)
                        .submitLabel(.search)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                        .focused($searchFocused)
                        .onSubmit { runDirectSearch() }
                        .onChange(of: searchText) { newValue in
                            completer.update(query: newValue, near: vm.region)
                        }

                    if isSearching {
                        ProgressView()
                            .tint(SQ5Colors.textTertiary)
                            .scaleEffect(0.7)
                    } else if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            completer.clear()
                            vm.clearRoute()
                            followMode = .none
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(SQ5Colors.textTertiary)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(SQ5Colors.surface.opacity(0.95))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(SQ5Colors.border, lineWidth: 1)
                        )
                )
                .padding(.horizontal, 26)
                .padding(.top, 4)
                .padding(.bottom, 6)

                if searchFocused && !completer.results.isEmpty {
                    SuggestionList(
                        results: completer.results,
                        onSelect: { completion in
                            searchText = completion.title
                            searchFocused = false
                            runSearch(for: completion)
                        }
                    )
                    .padding(.horizontal, 26)
                    .padding(.bottom, 6)
                }
                else if searchFocused && searchText.isEmpty && !vm.recentDestinations.isEmpty {
                    RecentDestinationsList(
                        names: vm.recentDestinations,
                        onSelect: { name in
                            searchText = name
                            searchFocused = false
                            isSearching = true
                            Task {
                                await vm.search(query: name)
                                await MainActor.run { isSearching = false }
                            }
                        },
                        onClear: { vm.clearRecents() }
                    )
                    .padding(.horizontal, 26)
                    .padding(.bottom, 6)
                }

                Spacer()

                if let info = vm.routeInfo {
                    NavigationCard(
                        info: info,
                        nextStep: vm.nextStep,
                        onClear: {
                            searchText = ""
                            vm.clearRoute()
                            followMode = .none
                        }
                    )
                    .padding(.horizontal, 26)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: vm.routeInfo != nil)
        }
        .onAppear {
            location.requestPermission()
        }
        .onChange(of: vm.routeInfo != nil) { hasRoute in
            // Auto-enter navigation mode when a route is set; relax back on clear.
            if hasRoute {
                followMode = .followHeading
            } else if followMode == .followHeading {
                followMode = .none
            }
        }
    }

    private func runDirectSearch() {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searchFocused = false
        isSearching = true
        Task {
            await vm.search(query: searchText)
            await MainActor.run { isSearching = false }
        }
    }

    private func runSearch(for completion: MKLocalSearchCompletion) {
        isSearching = true
        Task {
            await vm.search(completion: completion)
            await MainActor.run { isSearching = false }
        }
    }

    private func centerOnUser() {
        guard let here = location.location else { return }
        vm.region = MKCoordinateRegion(
            center: here.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        followMode = vm.routeInfo != nil ? .followHeading : .follow
    }
}

// MARK: - Floating map controls (right-edge column)

private struct MapControls: View {
    let canCenter: Bool
    let isFollowing: Bool
    let onCenter: () -> Void
    let onZoomIn: () -> Void
    let onZoomOut: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            // Center-on-me button (separate card so it visually stands apart)
            Button(action: onCenter) {
                Image(systemName: isFollowing ? "location.fill" : "location")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(canCenter ? (isFollowing ? SQ5Colors.accent : SQ5Colors.textPrimary)
                                               : SQ5Colors.textTertiary)
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
            .disabled(!canCenter)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(SQ5Colors.surface.opacity(0.94))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(SQ5Colors.border, lineWidth: 1)
                    )
            )

            // Zoom in / out stack
            VStack(spacing: 6) {
                ZoomButton(symbol: "plus", action: onZoomIn)
                ZoomButton(symbol: "minus", action: onZoomOut)
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(SQ5Colors.surface.opacity(0.94))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(SQ5Colors.border, lineWidth: 1)
                    )
            )
        }
    }
}

private struct ZoomButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(SQ5Colors.textPrimary)
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Predictive suggestions list

private struct SuggestionList: View {
    let results: [MKLocalSearchCompletion]
    let onSelect: (MKLocalSearchCompletion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(results.prefix(5).enumerated()), id: \.offset) { idx, item in
                Button { onSelect(item) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(SQ5Colors.textTertiary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(SQ5Typography.body)
                                .foregroundStyle(SQ5Colors.textPrimary)
                                .lineLimit(1)
                            if !item.subtitle.isEmpty {
                                Text(item.subtitle)
                                    .font(SQ5Typography.caption)
                                    .foregroundStyle(SQ5Colors.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if idx < min(results.count, 5) - 1 {
                    Rectangle()
                        .fill(SQ5Colors.border)
                        .frame(height: 1)
                        .padding(.horizontal, 14)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(SQ5Colors.surface.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(SQ5Colors.border, lineWidth: 1)
                )
        )
    }
}

// MARK: - Recent destinations

private struct RecentDestinationsList: View {
    let names: [String]
    let onSelect: (String) -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("RECENT")
                    .font(SQ5Typography.caption)
                    .tracking(1.8)
                    .foregroundStyle(SQ5Colors.textTertiary)
                Spacer()
                Button(action: onClear) {
                    Text("Clear")
                        .font(SQ5Typography.caption)
                        .foregroundStyle(SQ5Colors.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ForEach(Array(names.prefix(5).enumerated()), id: \.offset) { idx, name in
                Button { onSelect(name) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(SQ5Colors.textTertiary)
                            .frame(width: 18)
                        Text(name)
                            .font(SQ5Typography.body)
                            .foregroundStyle(SQ5Colors.textPrimary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if idx < min(names.count, 5) - 1 {
                    Rectangle()
                        .fill(SQ5Colors.border)
                        .frame(height: 1)
                        .padding(.horizontal, 14)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(SQ5Colors.surface.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(SQ5Colors.border, lineWidth: 1)
                )
        )
    }
}

// MARK: - Navigation card (when route is active)

private struct NavigationCard: View {
    let info: MapViewModel.RouteInfo
    let nextStep: String?
    let onClear: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if let step = nextStep {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.turn.up.right")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(SQ5Colors.accent)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(SQ5Colors.surfaceElevated))
                    Text(step)
                        .font(SQ5Typography.subtitle)
                        .foregroundStyle(SQ5Colors.textPrimary)
                        .lineLimit(2)
                    Spacer()
                }
            }

            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("DESTINATION")
                        .font(SQ5Typography.caption)
                        .tracking(1.5)
                        .foregroundStyle(SQ5Colors.textTertiary)
                    Text(info.title)
                        .font(SQ5Typography.subtitle)
                        .foregroundStyle(SQ5Colors.textPrimary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(info.distance)
                        .font(.system(size: 28, weight: .light, design: .default))
                        .foregroundStyle(SQ5Colors.textPrimary)
                        .monospacedDigit()
                    Text(info.duration)
                        .font(SQ5Typography.caption)
                        .foregroundStyle(SQ5Colors.textSecondary)
                }

                Button(action: onClear) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SQ5Colors.textTertiary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(SQ5Colors.surfaceElevated))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(SQ5Colors.background.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(SQ5Colors.border, lineWidth: 1)
                )
        )
    }
}

// MARK: - Search completer

@MainActor
final class SearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published private(set) var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String, near region: MKCoordinateRegion) {
        completer.region = region
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            results = []
            return
        }
        completer.queryFragment = query
    }

    func clear() {
        results = []
        completer.queryFragment = ""
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let next = completer.results
        Task { @MainActor in self.results = next }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }
}

// MARK: - View model

@MainActor
final class MapViewModel: ObservableObject {
    struct RouteInfo: Equatable {
        var title: String
        var distance: String
        var duration: String
    }

    @Published var region: MKCoordinateRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 60.1699, longitude: 24.9384),
        span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
    )
    @Published var routePolyline: MKPolyline? = nil
    @Published var routeInfo: RouteInfo? = nil
    @Published var nextStep: String? = nil
    @Published var recentDestinations: [String] = []

    private let recentsKey = "audipad.map.recentDestinations.v1"
    private let recentsLimit = 8

    init() { loadRecents() }

    // MARK: Zoom

    func zoomIn() {
        let span = region.span
        region.span = MKCoordinateSpan(
            latitudeDelta: max(span.latitudeDelta * 0.5, 0.002),
            longitudeDelta: max(span.longitudeDelta * 0.5, 0.002)
        )
    }

    func zoomOut() {
        let span = region.span
        region.span = MKCoordinateSpan(
            latitudeDelta: min(span.latitudeDelta * 2, 120),
            longitudeDelta: min(span.longitudeDelta * 2, 120)
        )
    }

    // MARK: Search

    func search(query: String) async {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        req.region = region
        await runSearch(req)
    }

    func search(completion: MKLocalSearchCompletion) async {
        let req = MKLocalSearch.Request(completion: completion)
        req.region = region
        await runSearch(req)
    }

    private func runSearch(_ req: MKLocalSearch.Request) async {
        do {
            let response = try await MKLocalSearch(request: req).start()
            guard let destination = response.mapItems.first else { return }
            await calculateRoute(to: destination)
        } catch {}
    }

    private func calculateRoute(to destination: MKMapItem) async {
        let source = MKMapItem(placemark: MKPlacemark(coordinate: region.center))
        let req = MKDirections.Request()
        req.source = source
        req.destination = destination
        req.transportType = .automobile

        do {
            let response = try await MKDirections(request: req).calculate()
            guard let route = response.routes.first else { return }
            self.routePolyline = route.polyline
            self.nextStep = route.steps.first(where: { !$0.instructions.isEmpty })?.instructions
            let title = destination.name ?? "Destination"
            self.routeInfo = RouteInfo(
                title: title,
                distance: Self.formatDistance(route.distance),
                duration: Self.formatDuration(route.expectedTravelTime)
            )
            let rect = route.polyline.boundingMapRect
            let padded = rect.insetBy(dx: -rect.size.width * 0.1,
                                      dy: -rect.size.height * 0.1)
            self.region = MKCoordinateRegion(padded)
            addToRecents(title)
        } catch {}
    }

    func clearRoute() {
        routePolyline = nil
        routeInfo = nil
        nextStep = nil
    }

    // MARK: Recents

    private func loadRecents() {
        if let data = UserDefaults.standard.data(forKey: recentsKey),
           let names = try? JSONDecoder().decode([String].self, from: data) {
            recentDestinations = names
        }
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recentDestinations) {
            UserDefaults.standard.set(data, forKey: recentsKey)
        }
    }

    func addToRecents(_ name: String) {
        var list = recentDestinations.filter { $0 != name }
        list.insert(name, at: 0)
        if list.count > recentsLimit { list = Array(list.prefix(recentsLimit)) }
        recentDestinations = list
        saveRecents()
    }

    func clearRecents() {
        recentDestinations = []
        saveRecents()
    }

    // MARK: Formatters

    private static func formatDistance(_ meters: CLLocationDistance) -> String {
        if meters >= 1000 {
            return String(format: "%.1f km", meters / 1000)
        }
        return "\(Int(meters)) m"
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h) h \(m) min" }
        return "\(m) min"
    }
}

// MARK: - MKMapView wrapper with 3D + user tracking

private struct MapBackground: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    let routePolyline: MKPolyline?
    let followMode: MapTabView.FollowMode
    let showsUser: Bool
    let onUserInteraction: () -> Void

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = showsUser
        map.pointOfInterestFilter = .excludingAll
        map.overrideUserInterfaceStyle = .dark
        map.isPitchEnabled = true
        map.isRotateEnabled = true
        map.setRegion(region, animated: false)

        // Initial 3D camera — slight perspective tilt so it doesn't read as flat
        let cam = MKMapCamera(
            lookingAtCenter: region.center,
            fromDistance: 2500,
            pitch: followMode.pitch,
            heading: 0
        )
        map.setCamera(cam, animated: false)

        // Detect user PAN gestures so we drop out of follow modes when the
        // user explicitly drags the map. Pinch (zoom) is NOT intercepted —
        // zoom shouldn't kill nav mode, only re-centering should.
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleUserInteraction))
        pan.delegate = context.coordinator
        map.addGestureRecognizer(pan)
        context.coordinator.onUserInteraction = onUserInteraction

        return map
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        uiView.showsUserLocation = showsUser
        context.coordinator.onUserInteraction = onUserInteraction

        // Update tracking mode
        if uiView.userTrackingMode != followMode.trackingMode {
            uiView.setUserTrackingMode(followMode.trackingMode, animated: true)
        }

        // Push the new pitch into the camera (smooth animation)
        let current = uiView.camera
        if abs(current.pitch - followMode.pitch) > 0.5 {
            let next = MKMapCamera(
                lookingAtCenter: current.centerCoordinate,
                fromDistance: current.altitude,
                pitch: followMode.pitch,
                heading: current.heading
            )
            uiView.setCamera(next, animated: true)
        }

        // Region update — only when NOT following the user (otherwise the
        // tracking mode owns the camera).
        if followMode == .none && regionDiffers(uiView.region, region) {
            uiView.setRegion(region, animated: true)
        }

        // Overlay refresh
        uiView.removeOverlays(uiView.overlays)
        if let p = routePolyline {
            uiView.addOverlay(p, level: .aboveRoads)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func regionDiffers(_ a: MKCoordinateRegion, _ b: MKCoordinateRegion) -> Bool {
        let dLat = abs(a.center.latitude - b.center.latitude)
        let dLon = abs(a.center.longitude - b.center.longitude)
        let dSpan = abs(a.span.latitudeDelta - b.span.latitudeDelta)
                  + abs(a.span.longitudeDelta - b.span.longitudeDelta)
        return dLat > 0.0005 || dLon > 0.0005 || dSpan > 0.0005
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var onUserInteraction: (() -> Void)?

        @objc func handleUserInteraction(_ recognizer: UIGestureRecognizer) {
            // Drop out of follow on any user-initiated pan/pinch
            if recognizer.state == .began || recognizer.state == .changed {
                onUserInteraction?()
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true   // play nicely with the map's own recognizers
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: polyline)
                r.strokeColor = UIColor(SQ5Colors.accent)
                r.lineWidth = 6
                r.lineCap = .round
                r.lineJoin = .round
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

struct MapTabView_Previews: PreviewProvider {
    static var previews: some View {
        MapTabView()
            .environmentObject(LocationService())
            .preferredColorScheme(.dark)
            .previewInterfaceOrientation(.landscapeLeft)
    }
}
