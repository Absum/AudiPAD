import SwiftUI
import MapKit
import SceneKit
import Combine
import CoreLocation

struct MapTabView: View {
    @EnvironmentObject private var location: LocationService
    @EnvironmentObject private var traffic: TrafficIncidentService
    @EnvironmentObject private var cameraService: SpeedCameraService
    @EnvironmentObject private var roadLimits: RoadSpeedLimitService
    @StateObject private var vm = MapViewModel()
    @StateObject private var controller = MapController()
    @StateObject private var completer = SearchCompleter()
    @State private var searchText: String = ""
    @State private var isSearching: Bool = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            MapBackground(
                controller: controller,
                routePolyline: vm.routePolyline,
                incidents: traffic.incidents,
                cameras: cameraService.cameras
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

            // Bottom-left road info panel
            VStack {
                Spacer()
                RoadInfoPanel(road: roadLimits.currentRoad,
                              limit: roadLimits.current?.limit)
                    .padding(.leading, 24)
                    .padding(.bottom, vm.routeInfo == nil ? 26 : 150)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)

            // Right-edge floating controls — compass, center-on-me, zoom
            VStack {
                Spacer()
                MapControls(
                    canCenter: location.isAuthorized && location.location != nil,
                    isFollowing: controller.followUser,
                    isHeadingUp: controller.headingUp,
                    mapHeading: controller.currentMapHeading,
                    onToggleCompass: { controller.toggleHeadingUp() },
                    onCenter: {
                        if let here = location.location?.coordinate {
                            controller.centerOnUser(here)
                        }
                    },
                    onTiltUp:   { controller.tiltUp() },
                    onTiltDown: { controller.tiltDown() },
                    onZoomIn:   { controller.zoomIn() },
                    onZoomOut:  { controller.zoomOut() }
                )
                .padding(.trailing, 24)
                .padding(.bottom, vm.routeInfo == nil ? 26 : 150)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 0) {
                TopBar(showSpeed: true)

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
                            completer.update(query: newValue, near: controller.currentRegion)
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
                                await vm.search(query: name, near: controller.currentRegion)
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
            // Hand the controller a snapper that projects each fix onto the
            // nearest road centerline. The user-location dot still uses the
            // raw GPS — only the camera tracks the snapped position.
            controller.snapper = { [weak roadLimits] loc in
                roadLimits?.snapped(loc)
            }
        }
        .onReceive(location.$location) { loc in
            // Manual follow + heading-up applied here. Avoids
            // `MKUserTrackingMode.follow`, which resets zoom on every
            // location tick.
            guard let loc else { return }
            controller.applyLocationUpdate(loc)
        }
        .onReceive(vm.$routePolyline.compactMap { $0 }) { polyline in
            // Fit the camera to the calculated route, then re-engage follow
            // so the driver picks up nav-style view immediately.
            let rect = polyline.boundingMapRect
            let padded = rect.insetBy(dx: -rect.size.width * 0.1,
                                      dy: -rect.size.height * 0.1)
            controller.fitRegion(MKCoordinateRegion(padded))
        }
        .onChange(of: vm.routeInfo != nil) { hasRoute in
            if hasRoute { controller.setFollow(true) }
        }
    }

    private func runDirectSearch() {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searchFocused = false
        isSearching = true
        Task {
            await vm.search(query: searchText, near: controller.currentRegion)
            await MainActor.run { isSearching = false }
        }
    }

    private func runSearch(for completion: MKLocalSearchCompletion) {
        isSearching = true
        Task {
            await vm.search(completion: completion, near: controller.currentRegion)
            await MainActor.run { isSearching = false }
        }
    }
}

// MARK: - Map controller
//
// Owns the live MKMapView reference, the persisted user preferences
// (follow / heading-up / saved zoom + center), and exposes the small set of
// imperative commands the UI fires (zoom in/out, center-on-me, toggle
// compass). All map state lives in the MKMapView; this class never pushes a
// stale region back into the map, which is what caused the zoom bouncing in
// the previous implementation.

@MainActor
final class MapController: ObservableObject {
    /// Centered on the user's location, with `MKUserTrackingMode.follow`.
    @Published var followUser: Bool {
        didSet { UserDefaults.standard.set(followUser, forKey: Self.followKey) }
    }
    /// Map rotates so the direction of travel (GPS course) is up. Off = north up.
    @Published var headingUp: Bool {
        didSet { UserDefaults.standard.set(headingUp, forKey: Self.headingKey) }
    }
    /// Current camera heading, mirrored from `regionDidChange` so the compass
    /// badge can rotate with the map.
    @Published var currentMapHeading: Double = 0
    /// Current visible region — read by `SearchCompleter` and the route
    /// calculator so search results bias near what's on screen.
    @Published var currentRegion: MKCoordinateRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 60.1699, longitude: 24.9384),
        span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
    )

    weak var mapView: MKMapView?

    /// Single annotation that represents the user — replaces the iOS
    /// blue dot so we can render a car-shaped icon tilted to lie flat on
    /// the road with the map's pitch.
    let carAnnotation = CarPositionAnnotation()

    /// Optional snapper used to project the raw GPS fix onto the nearest
    /// road centerline (map-matching). Returns nil when off-road; the
    /// camera falls back to the raw coord. Wired from `MapTabView` so the
    /// controller doesn't need to know about `RoadSpeedLimitService`.
    var snapper: ((CLLocation) -> CLLocationCoordinate2D?)?

    /// Authoritative zoom level — never read from `map.camera.altitude`
    /// because that returns the *in-flight* value during animation. If
    /// location updates sampled the in-flight altitude they'd lock the
    /// zoom at whatever transient value was visible mid-animation, which
    /// is exactly what made `+/-` look like it "decides the zoom itself".
    private var desiredAltitude: CLLocationDistance = 2500

    /// Authoritative camera pitch (0° = flat top-down, 60° = steep 3D
    /// view). Same rationale as `desiredAltitude` — applying location
    /// updates with the in-flight pitch reading would lock pitch at a
    /// mid-animation value the moment a tilt button is tapped.
    private var desiredPitch: CGFloat = 50

    private static let followKey  = "audipad.map.followUser"
    private static let headingKey = "audipad.map.headingUp"
    private static let altKey     = "audipad.map.altitude"
    private static let latKey     = "audipad.map.centerLat"
    private static let lonKey     = "audipad.map.centerLon"
    private static let pitchKey   = "audipad.map.pitch"

    init() {
        let d = UserDefaults.standard
        self.followUser = (d.object(forKey: Self.followKey) as? Bool) ?? true
        self.headingUp  = d.bool(forKey: Self.headingKey)
        let saved = d.double(forKey: Self.altKey)
        self.desiredAltitude = saved > 0 ? saved : 2500
        let savedPitch = d.double(forKey: Self.pitchKey)
        self.desiredPitch = (savedPitch > 0 || d.object(forKey: Self.pitchKey) != nil) ? CGFloat(savedPitch) : 50
    }

    // MARK: Saved camera (zoom + center) — restored on launch.

    var savedAltitude: CLLocationDistance { desiredAltitude }
    var savedPitch: CGFloat { desiredPitch }

    var savedCenter: CLLocationCoordinate2D {
        let lat = UserDefaults.standard.double(forKey: Self.latKey)
        let lon = UserDefaults.standard.double(forKey: Self.lonKey)
        // Default fallback: Helsinki.
        if lat == 0 && lon == 0 {
            return CLLocationCoordinate2D(latitude: 60.1699, longitude: 24.9384)
        }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    func persistCamera() {
        guard let map = mapView else { return }
        let d = UserDefaults.standard
        d.set(desiredAltitude, forKey: Self.altKey)
        d.set(Double(desiredPitch), forKey: Self.pitchKey)
        d.set(map.camera.centerCoordinate.latitude,  forKey: Self.latKey)
        d.set(map.camera.centerCoordinate.longitude, forKey: Self.lonKey)
    }

    /// Called by the pinch-end gesture handler so user-driven zooms get
    /// captured into `desiredAltitude`. Without this, the next location
    /// update would force the camera back to whatever the pre-pinch zoom
    /// was.
    func syncDesiredAltitudeToCurrent() {
        guard let map = mapView else { return }
        desiredAltitude = map.camera.altitude
    }

    // MARK: User commands

    func setFollow(_ on: Bool) {
        if followUser != on { followUser = on }
    }

    func toggleHeadingUp() {
        headingUp.toggle()
        if !headingUp {
            // Going back to north-up — snap immediately rather than waiting
            // for the next location update.
            applyHeading(to: 0, animated: true)
        }
    }

    func zoomIn()  { adjustAltitude(factor: 0.5) }
    func zoomOut() { adjustAltitude(factor: 2.0) }

    /// More 3D / horizon-facing view (raises pitch toward 60°).
    func tiltUp()   { adjustPitch(by: +10) }
    /// Flatter / top-down view (drops pitch toward 0°).
    func tiltDown() { adjustPitch(by: -10) }

    private func adjustPitch(by delta: CGFloat) {
        guard let map = mapView else { return }
        let newPitch = max(0, min(desiredPitch + delta, 60))
        if abs(newPitch - desiredPitch) < 0.5 { return }
        desiredPitch = newPitch
        let cam = map.camera
        let next = MKMapCamera(lookingAtCenter: cam.centerCoordinate,
                               fromDistance: cam.altitude,
                               pitch: newPitch,
                               heading: cam.heading)
        map.setCamera(next, animated: true)
        // Pitch changed → car body's 3D pose needs to lean accordingly.
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.35
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
        refreshCarTransform()
        SCNTransaction.commit()
    }

    private func adjustAltitude(factor: Double) {
        guard let map = mapView else { return }
        let newAlt = max(min(desiredAltitude * factor, 20_000_000), 80)
        if abs(newAlt - desiredAltitude) < 1 { return }
        desiredAltitude = newAlt
        let cam = map.camera
        let next = MKMapCamera(lookingAtCenter: cam.centerCoordinate,
                               fromDistance: newAlt,
                               pitch: desiredPitch,
                               heading: cam.heading)
        map.setCamera(next, animated: true)
    }

    func centerOnUser(_ coord: CLLocationCoordinate2D) {
        guard let map = mapView else { return }
        setFollow(true)
        let cam = map.camera
        let next = MKMapCamera(lookingAtCenter: coord,
                               fromDistance: desiredAltitude,
                               pitch: desiredPitch,
                               heading: cam.heading)
        map.setCamera(next, animated: true)
    }

    func fitRegion(_ region: MKCoordinateRegion) {
        mapView?.setRegion(region, animated: true)
    }

    // MARK: Per-location update (manual follow + heading)
    //
    // We do follow + heading-up manually instead of using
    // `MKUserTrackingMode.follow`. The system mode resets the camera
    // distance on every location tick, which clobbers any pinch-zoom the
    // user just did. By driving `setCamera` ourselves we keep the user's
    // chosen altitude and only ever touch center + heading.

    func applyLocationUpdate(_ location: CLLocation) {
        guard let map = mapView else { return }
        let cam = map.camera

        // Map-matched position — projects the raw GPS coord onto the
        // nearest road centerline so the camera tracks the road rather
        // than drifting next to it. Falls back to the raw coord when the
        // user is off-road or no road data is cached nearby.
        let trackedCoord = snapper?(location) ?? location.coordinate

        // Make the car visible on first fix. Heading goes through the
        // same animated path as the rest of the marker pose below.
        carAnnotation.isVisible = true
        if location.course >= 0, location.speed > 0.5 {
            carAnnotation.heading = location.course
        }

        var newCenter = cam.centerCoordinate
        var newHeading = cam.heading

        if headingUp, location.course >= 0, location.speed > 1.5 {
            newHeading = location.course
        }

        if followUser {
            // In heading-up follow we offset the camera centerpoint
            // forward of the user along the heading, so the user dot lands
            // 1/3 from the bottom of the map — leaves the road ahead with
            // most of the screen real estate, like every nav app.
            if headingUp {
                let forwardBearing = (location.course >= 0) ? location.course : newHeading
                newCenter = Self.forwardOffsetCenter(for: trackedCoord,
                                                    bearing: forwardBearing,
                                                    on: map)
            } else {
                newCenter = trackedCoord
            }
        }

        let next = MKMapCamera(lookingAtCenter: newCenter,
                               fromDistance: desiredAltitude,
                               pitch: desiredPitch,
                               heading: newHeading)

        // One tween for the whole pose: camera, annotation position, and
        // SceneKit yaw all glide together over 1 s with a linear curve.
        // Without this, the car would "snap" to each new GPS fix while
        // the camera was still gliding toward it — visible hopping
        // relative to the underlying map.
        UIView.animate(withDuration: 1.0,
                       delay: 0,
                       options: [.curveLinear, .beginFromCurrentState, .allowUserInteraction]) {
            map.setCamera(next, animated: false)
            // MKMapView observes annotation.coordinate via KVO; setting it
            // inside a UIView.animate block triggers an animated update
            // of the annotation's projected screen position.
            self.carAnnotation.coordinate = trackedCoord
        }

        // SceneKit nodes don't participate in UIKit animations — drive
        // the yaw + camera-orbit transform through SCNTransaction with the
        // same duration so the car body and the camera lean in sync with
        // the position tween.
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 1.0
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .linear)
        refreshCarTransform()
        SCNTransaction.commit()
    }

    /// Push the latest map heading + pitch into the car annotation view's
    /// 3D transform. Called after a location update (car heading may have
    /// changed) and from the coordinator on region change (map heading /
    /// pitch may have changed). Cheap — no allocation, just a few matrix
    /// multiplies, so safe to run on every animation tick.
    func refreshCarTransform() {
        guard let map = mapView else { return }
        guard let view = map.view(for: carAnnotation) as? CarAnnotationView else { return }
        view.applyTransform(carHeading: carAnnotation.heading,
                            mapHeading: map.camera.heading,
                            mapPitch:   map.camera.pitch)
    }

    /// Returns a coordinate offset forward of the user along `bearing`,
    /// chosen so that placing the camera centerpoint here lands the user
    /// dot 2/3 of the way down the visible map (= 1/3 from the bottom).
    /// The offset distance is derived from the map's current meters-per-
    /// point at screen center — so it scales correctly with zoom + pitch.
    private static func forwardOffsetCenter(for userCoord: CLLocationCoordinate2D,
                                            bearing: Double,
                                            on map: MKMapView) -> CLLocationCoordinate2D {
        let h = map.bounds.height
        guard h > 0 else { return userCoord }

        // Meters per screen point sampled at the map's centerline.
        let p1 = CGPoint(x: map.bounds.midX, y: map.bounds.midY)
        let p2 = CGPoint(x: map.bounds.midX, y: map.bounds.midY + 1)
        let c1 = map.convert(p1, toCoordinateFrom: map)
        let c2 = map.convert(p2, toCoordinateFrom: map)
        let mPerPt = CLLocation(latitude: c1.latitude, longitude: c1.longitude)
            .distance(from: CLLocation(latitude: c2.latitude, longitude: c2.longitude))

        // We want the user at y = 2h/3 instead of y = h/2 → shift camera
        // center forward by (2h/3 − h/2) = h/6 screen points worth of map.
        let forwardMeters = mPerPt * (h / 6)
        return geoOffset(from: userCoord, bearing: bearing, meters: forwardMeters)
    }

    /// Spherical-earth offset: walk `meters` from `coord` along `bearing`
    /// (compass degrees) and return the new coordinate.
    private static func geoOffset(from coord: CLLocationCoordinate2D,
                                  bearing: Double,
                                  meters: Double) -> CLLocationCoordinate2D {
        let R = 6378137.0
        let δ = meters / R
        let θ = bearing * .pi / 180
        let φ1 = coord.latitude * .pi / 180
        let λ1 = coord.longitude * .pi / 180
        let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1),
                            cos(δ) - sin(φ1) * sin(φ2))
        return CLLocationCoordinate2D(latitude: φ2 * 180 / .pi,
                                      longitude: λ2 * 180 / .pi)
    }

    private func applyHeading(to target: CLLocationDirection, animated: Bool) {
        guard let map = mapView else { return }
        let cam = map.camera
        if abs(cam.heading - target) < 1 { return }
        let next = MKMapCamera(lookingAtCenter: cam.centerCoordinate,
                               fromDistance: cam.altitude,
                               pitch: desiredPitch,
                               heading: target)
        map.setCamera(next, animated: animated)
    }
}

// MARK: - Floating map controls (right-edge two-column grid)

private struct MapControls: View {
    let canCenter: Bool
    let isFollowing: Bool
    let isHeadingUp: Bool
    let mapHeading: Double
    let onToggleCompass: () -> Void
    let onCenter: () -> Void
    let onTiltUp: () -> Void
    let onTiltDown: () -> Void
    let onZoomIn: () -> Void
    let onZoomOut: () -> Void

    var body: some View {
        // Two columns so the compass/follow row visually lines up with
        // the tilt/zoom pair underneath, instead of floating centered
        // above a wider 2-button row. Left column = compass + tilt
        // (rotation-ish controls), right column = follow + zoom
        // (position-ish controls).
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 20) {
                // Compass — toggles heading-up vs north-up. Visual rotates
                // with the map so the red N-arrow always points to true
                // north. Card border goes accent when heading-up is active.
                Button(action: onToggleCompass) {
                    CompassIcon(mapHeading: mapHeading)
                        .frame(width: 68, height: 68)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(controlCard(active: isHeadingUp))

                VStack(spacing: 12) {
                    SquareIconButton(symbol: "chevron.up", action: onTiltUp)
                    SquareIconButton(symbol: "chevron.down", action: onTiltDown)
                }
                .background(controlCard(active: false))
            }

            VStack(spacing: 20) {
                // Center-on-me — card border goes accent when follow is on.
                Button(action: onCenter) {
                    Image(systemName: isFollowing ? "location.fill" : "location")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(canCenter ? SQ5Colors.textPrimary : SQ5Colors.textTertiary)
                        .frame(width: 68, height: 68)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canCenter)
                .background(controlCard(active: isFollowing))

                VStack(spacing: 12) {
                    SquareIconButton(symbol: "plus", action: onZoomIn)
                    SquareIconButton(symbol: "minus", action: onZoomOut)
                }
                .background(controlCard(active: false))
            }
        }
    }

    private func controlCard(active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(SQ5Colors.surface.opacity(0.94))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(active ? SQ5Colors.accent : SQ5Colors.border,
                            lineWidth: active ? 2.5 : 1)
            )
    }
}

/// Shared button used for the zoom +/- and tilt up/down map controls.
private struct SquareIconButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(SQ5Colors.textPrimary)
                .frame(width: 68, height: 68)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Compass icon
//
// Outer ring + a red N-marker that rotates by `-mapHeading` in screen
// space, so the marker always points to true north regardless of which way
// the map is facing. Ring color flips to the accent when heading-up is on.

private struct CompassIcon: View {
    let mapHeading: Double  // 0…360 — current map camera heading

    private let ringColor: Color = SQ5Colors.textPrimary

    var body: some View {
        ZStack {
            Circle()
                .stroke(ringColor, lineWidth: 2)
                .frame(width: 46, height: 46)

            // North marker — rotates to track actual north on the map.
            ZStack {
                Triangle()
                    .fill(Color(red: 0.92, green: 0.20, blue: 0.20))
                    .frame(width: 9, height: 13)
                    .offset(y: -17)
                Text("N")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(ringColor)
                    .offset(y: -30)
            }
            .rotationEffect(.degrees(-mapHeading))

            // Center dot
            Circle()
                .fill(ringColor)
                .frame(width: 3, height: 3)
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Road info panel (bottom-left)

/// Compact "you are here" panel — current road name + ref + speed limit.
/// Renders nothing when all three are nil so it stays out of the driver's
/// way before the first fetch lands.
private struct RoadInfoPanel: View {
    let road: RoadSpeedLimitService.RoadInfo?
    let limit: Int?

    private var hasAnyContent: Bool {
        (road?.name != nil) || (road?.ref != nil) || (limit != nil)
    }

    var body: some View {
        if hasAnyContent {
            HStack(alignment: .center, spacing: 16) {
                if let limit {
                    TrafficSignView(sign: .speedLimit(limit))
                        .frame(width: 66, height: 66)
                }
                VStack(alignment: .leading, spacing: 6) {
                    if let ref = road?.ref, !ref.isEmpty {
                        RoadShieldStack(ref: ref)
                    }
                    if let name = road?.name, !name.isEmpty {
                        Text(name)
                            .font(.system(size: 27, weight: .medium))
                            .foregroundStyle(SQ5Colors.textPrimary)
                            .lineLimit(1)
                    } else if road?.ref == nil {
                        Text("Off road")
                            .font(.system(size: 27, weight: .medium))
                            .foregroundStyle(SQ5Colors.textSecondary)
                    }
                }
            }
            // Asymmetric horizontal padding — extra room on the trailing
            // side so the road name doesn't crowd the rounded right edge.
            .padding(.leading, 14)
            .padding(.trailing, 24)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(SQ5Colors.surface.opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(SQ5Colors.border, lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 2)
        }
    }
}

// MARK: - Finnish-style road shields

private struct RoadShieldStack: View {
    let ref: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(parsedShields.enumerated()), id: \.offset) { _, shield in
                RoadShield(shield: shield)
            }
        }
    }

    private var parsedShields: [RoadShield.Shield] {
        ref.split(whereSeparator: { ";,/".contains($0) })
            .map(String.init)
            .compactMap { RoadShield.Shield.parse($0) }
    }
}

private struct RoadShield: View {
    enum Kind {
        case european, national, main, regional, connecting
    }

    struct Shield {
        let label: String
        let kind: Kind

        static func parse(_ raw: String) -> Shield? {
            let trimmed = raw.trimmingCharacters(in: .whitespaces).uppercased()
            guard !trimmed.isEmpty else { return nil }
            let stripped = trimmed
                .replacingOccurrences(of: "^(VT|KT|MT|ST|YT)\\s*",
                                      with: "",
                                      options: .regularExpression)
            if stripped.hasPrefix("E"),
               let n = Int(stripped.dropFirst().trimmingCharacters(in: .whitespaces)) {
                return Shield(label: "E\(n)", kind: .european)
            }
            if let n = Int(stripped) {
                let kind: Kind
                switch n {
                case 1...39:    kind = .national
                case 40...99:   kind = .main
                case 100...999: kind = .regional
                default:        kind = .connecting
                }
                return Shield(label: "\(n)", kind: kind)
            }
            return nil
        }
    }

    let shield: Shield

    var body: some View {
        Text(shield.label)
            .font(.system(size: 16, weight: .heavy))
            .foregroundStyle(textColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(minWidth: 34)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(borderColor, lineWidth: 1.5)
            )
    }

    private var fillColor: Color {
        switch shield.kind {
        case .european:   return Color(red: 0.0, green: 0.45, blue: 0.20)
        case .national:   return Color(red: 0.78, green: 0.10, blue: 0.10)
        case .main:       return Color(red: 1.0, green: 0.82, blue: 0.10)
        case .regional, .connecting: return .white
        }
    }

    private var textColor: Color {
        switch shield.kind {
        case .european, .national: return .white
        case .main, .regional, .connecting: return .black
        }
    }

    private var borderColor: Color {
        switch shield.kind {
        case .european, .national: return .white
        case .main, .regional, .connecting: return Color(red: 0.10, green: 0.10, blue: 0.10)
        }
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

    @Published var routePolyline: MKPolyline? = nil
    @Published var routeInfo: RouteInfo? = nil
    @Published var nextStep: String? = nil
    @Published var recentDestinations: [String] = []

    private let recentsKey = "audipad.map.recentDestinations.v1"
    private let recentsLimit = 8

    init() { loadRecents() }

    // MARK: Search

    func search(query: String, near region: MKCoordinateRegion) async {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        req.region = region
        await runSearch(req, source: region.center)
    }

    func search(completion: MKLocalSearchCompletion, near region: MKCoordinateRegion) async {
        let req = MKLocalSearch.Request(completion: completion)
        req.region = region
        await runSearch(req, source: region.center)
    }

    private func runSearch(_ req: MKLocalSearch.Request, source: CLLocationCoordinate2D) async {
        do {
            let response = try await MKLocalSearch(request: req).start()
            guard let destination = response.mapItems.first else { return }
            await calculateRoute(to: destination, from: source)
        } catch {}
    }

    private func calculateRoute(to destination: MKMapItem, from source: CLLocationCoordinate2D) async {
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: source))
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

// MARK: - MKMapView wrapper
//
// The map view owns its own camera state — this wrapper only sets it up
// once (with the persisted zoom + center), reacts to follow-mode flips, and
// observes region changes so we can mirror them back into the controller.
// Crucially, we do NOT push region updates from SwiftUI into the map
// during `updateUIView`, which is what caused the zoom-bouncing in the
// prior implementation.

private struct MapBackground: UIViewRepresentable {
    @ObservedObject var controller: MapController
    let routePolyline: MKPolyline?
    let incidents: [TrafficIncident]
    let cameras: [SpeedCamera]

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        // We render the user position as a custom car-shaped annotation
        // (see CarPositionAnnotation / CarAnnotationView) so we can map-
        // match it onto the road centerline and tilt it flat with pitch.
        // The system blue dot is suppressed.
        map.showsUserLocation = false
        map.showsTraffic = true
        map.pointOfInterestFilter = .excludingAll
        map.overrideUserInterfaceStyle = .dark
        map.isPitchEnabled = true
        map.isRotateEnabled = true

        // Restore saved camera so the user's zoom + center + pitch all carry
        // across app launches.
        let cam = MKMapCamera(
            lookingAtCenter: controller.savedCenter,
            fromDistance: controller.savedAltitude,
            pitch: controller.savedPitch,
            heading: 0
        )
        map.setCamera(cam, animated: false)

        controller.mapView = map

        // Add the car-shape user-position annotation. Hidden until the
        // first location fix arrives; `applyLocationUpdate` sets
        // `isVisible = true` once we have a coord.
        map.addAnnotation(controller.carAnnotation)

        // Pan to disengage follow. Constrain to 1 finger so two-finger
        // pinch/rotate don't also count as "pan" — otherwise zooming kicks
        // you out of follow mode.
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleUserPan))
        pan.delegate = context.coordinator
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        map.addGestureRecognizer(pan)

        // Pinch end → capture the new zoom into the controller so location
        // updates respect it instead of forcing the previous altitude back.
        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handlePinch))
        pinch.delegate = context.coordinator
        map.addGestureRecognizer(pinch)

        context.coordinator.controller = controller
        return map
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        context.coordinator.controller = controller

        // System blue dot stays suppressed regardless of permission state
        // — our CarAnnotationView is the only user-position glyph.

        // Note: we do NOT use `MKUserTrackingMode.follow` — see
        // `MapController.applyLocationUpdate`. The user's pinch-zoom would
        // otherwise be reset by the system on every location update.

        // Route overlay diffing — keep only the current polyline.
        for existing in uiView.overlays.compactMap({ $0 as? MKPolyline }) where existing !== routePolyline {
            uiView.removeOverlay(existing)
        }
        if let p = routePolyline, !uiView.overlays.contains(where: { ($0 as? MKPolyline) === p }) {
            uiView.addOverlay(p, level: .aboveRoads)
        }

        // Incident pins — diff by situationId so existing pins don't flicker.
        let existingIncidents = uiView.annotations.compactMap { $0 as? TrafficIncidentAnnotation }
        let existingIncidentIds = Set(existingIncidents.map(\.situationId))
        let incomingIncidentIds = Set(incidents.map(\.situationId))
        let incidentsToRemove = existingIncidents.filter { !incomingIncidentIds.contains($0.situationId) }
        if !incidentsToRemove.isEmpty { uiView.removeAnnotations(incidentsToRemove) }
        let incidentsToAdd = incidents
            .filter { !existingIncidentIds.contains($0.situationId) }
            .map { TrafficIncidentAnnotation(incident: $0) }
        if !incidentsToAdd.isEmpty { uiView.addAnnotations(incidentsToAdd) }

        // Camera pins — same diff strategy.
        let existingCameras = uiView.annotations.compactMap { $0 as? SpeedCameraAnnotation }
        let existingCameraIds = Set(existingCameras.map(\.cameraId))
        let incomingCameraIds = Set(cameras.map(\.id))
        let camerasToRemove = existingCameras.filter { !incomingCameraIds.contains($0.cameraId) }
        if !camerasToRemove.isEmpty { uiView.removeAnnotations(camerasToRemove) }
        let camerasToAdd = cameras
            .filter { !existingCameraIds.contains($0.id) }
            .map { SpeedCameraAnnotation(camera: $0) }
        if !camerasToAdd.isEmpty { uiView.addAnnotations(camerasToAdd) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        weak var controller: MapController?

        @objc func handleUserPan(_ recognizer: UIPanGestureRecognizer) {
            // Drop out of follow on user-initiated pan (drag). Pinch and
            // rotate gestures don't reach this handler.
            if recognizer.state == .began {
                controller?.setFollow(false)
            }
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            if recognizer.state == .ended || recognizer.state == .cancelled {
                controller?.syncDesiredAltitudeToCurrent()
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // Mirror live camera state back to the controller, then persist
            // so the user's zoom/center carries across app launches.
            guard let controller else { return }
            controller.currentRegion = mapView.region
            controller.currentMapHeading = mapView.camera.heading
            controller.persistCamera()
            // Map heading or pitch may have changed — refresh the car
            // annotation's 3D transform so it stays oriented to its
            // compass heading and lying flat on the (possibly newly
            // tilted) road plane.
            controller.refreshCarTransform()
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

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }

            if let car = annotation as? CarPositionAnnotation {
                let reuseId = "Car"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseId) as? CarAnnotationView)
                    ?? CarAnnotationView(annotation: car, reuseIdentifier: reuseId)
                view.annotation = car
                view.isHidden = !car.isVisible
                view.displayPriority = .required
                if let map = controller?.mapView {
                    view.applyTransform(carHeading: car.heading,
                                        mapHeading: map.camera.heading,
                                        mapPitch:   map.camera.pitch)
                }
                return view
            }

            if let inc = annotation as? TrafficIncidentAnnotation {
                let reuseId = "TrafficIncident"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseId) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: reuseId)
                view.annotation = annotation
                view.markerTintColor = inc.markerColor
                view.glyphImage = UIImage(systemName: inc.glyphSymbol)
                view.canShowCallout = true
                view.titleVisibility = .visible
                view.displayPriority = .required
                return view
            }

            if let cam = annotation as? SpeedCameraAnnotation {
                let reuseId = "SpeedCamera"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseId) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: reuseId)
                view.annotation = annotation
                view.markerTintColor = UIColor(SQ5Colors.accent)
                view.glyphImage = UIImage(systemName: cam.glyphSymbol)
                view.canShowCallout = true
                view.titleVisibility = .visible
                view.transform = CGAffineTransform(scaleX: 0.78, y: 0.78)
                view.displayPriority = .defaultHigh
                return view
            }

            return nil
        }
    }
}

// MARK: - Car-shape user-position annotation
//
// We use a custom annotation instead of MKUserLocation so we can:
//   • Position the dot at the snapped (road-matched) coord instead of raw GPS
//   • Render a car-shaped icon
//   • Apply a 3D CATransform3D that combines a Z rotation (compass heading
//     relative to current map heading) with an X rotation (map pitch), so
//     the icon looks like it's lying flat on the road and points the way
//     the car is moving — like the proper nav-arrow in Apple/Google Maps.

final class CarPositionAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D = CLLocationCoordinate2D(
        latitude: 60.1699, longitude: 24.9384
    )
    /// Compass heading (0…360, 0 = north, clockwise) of the car's motion.
    /// Updated only when we have a meaningful GPS course — otherwise the
    /// icon keeps the last heading rather than spinning erratically.
    var heading: Double = 0
    /// Render-gate flag — flipped to true the first time a location fix
    /// arrives so the icon doesn't render at the default Helsinki coord
    /// before we know where the user actually is.
    var isVisible: Bool = false

    override init() { super.init() }
}

private final class CarAnnotationView: MKAnnotationView {
    private let scnView = SCNView()
    private let carNode = CarModel.makeNode()
    private let cameraNode = SCNNode()
    /// Camera-rig distance from the car. With orthographic projection the
    /// distance doesn't affect size — only the angle of view.
    private let orbitRadius: Float = 12

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = false

        // Annotation footprint on screen. Big enough to show a 3/4 view
        // legibly without dominating the map.
        let size = CGSize(width: 104, height: 104)
        bounds = CGRect(origin: .zero, size: size)
        centerOffset = .zero

        scnView.frame = bounds
        scnView.backgroundColor = .clear
        scnView.isOpaque = false
        scnView.antialiasingMode = .multisampling4X
        scnView.preferredFramesPerSecond = 30
        addSubview(scnView)

        let scene = SCNScene()
        scene.background.contents = UIColor.clear
        scene.rootNode.addChildNode(carNode)

        // Orthographic camera so the car's screen size is independent of
        // the orbit radius — only the *angle* the camera makes with the
        // ground plane varies, which is what we want for map-pitch parallax.
        let cam = SCNCamera()
        cam.usesOrthographicProjection = true
        cam.orthographicScale = 3.4
        cameraNode.camera = cam
        scene.rootNode.addChildNode(cameraNode)

        // Lighting tuned for a black body. A single directional key would
        // flatten the form into a silhouette — we add a fill from the
        // opposite side so both flanks pick up a specular highlight, and
        // keep ambient lower so faces in shadow stay dark and the shape
        // reads.
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 1100
        key.light?.color = UIColor.white
        key.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 4, 0)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 450
        fill.light?.color = UIColor(white: 0.92, alpha: 1.0)
        fill.eulerAngles = SCNVector3(-Float.pi / 4, -Float.pi * 3 / 4, 0)
        scene.rootNode.addChildNode(fill)

        let amb = SCNNode()
        amb.light = SCNLight()
        amb.light?.type = .ambient
        amb.light?.intensity = 220
        amb.light?.color = UIColor(white: 0.80, alpha: 1.0)
        scene.rootNode.addChildNode(amb)

        scnView.scene = scene

        // Initial pose — looking straight down at the roof.
        applyTransform(carHeading: 0, mapHeading: 0, mapPitch: 0)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// Pose the SceneKit scene so the rendered image mirrors what the
    /// map camera sees.
    ///   • Car yaw  ← (carHeading − mapHeading) — front always points
    ///     along the geographic direction of travel.
    ///   • Camera orbits the car along the screen-vertical plane, with
    ///     angle = mapPitch. At pitch 0 the camera is directly overhead
    ///     (we see only the roof); at pitch 50° the camera leans toward
    ///     the rear and we see the roof + a chunk of side panels — the
    ///     parallax that a static PNG can't fake.
    func applyTransform(carHeading: Double, mapHeading: Double, mapPitch: Double) {
        let yaw = Float((carHeading - mapHeading) * .pi / 180)
        carNode.eulerAngles = SCNVector3(0, -yaw, 0)

        let p = Float(mapPitch * .pi / 180)
        // Camera sits on a Y-Z circle around the car, looking at the origin.
        cameraNode.position    = SCNVector3(0, orbitRadius * cos(p), orbitRadius * sin(p))
        cameraNode.eulerAngles = SCNVector3(-(.pi / 2) + p, 0, 0)
    }
}

// MARK: - Speed camera MKAnnotation wrapper

private final class SpeedCameraAnnotation: NSObject, MKAnnotation {
    let cameraId: UUID
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?
    let glyphSymbol: String

    init(camera: SpeedCamera) {
        self.cameraId = camera.id
        self.coordinate = camera.coordinate
        self.title = "\(camera.speedLimit) km/h"
        switch camera.kind {
        case .fixed:        self.subtitle = "Speed camera"
        case .mobile:       self.subtitle = "Mobile camera"
        case .averageSpeed: self.subtitle = "Average-speed zone"
        }
        switch camera.kind {
        case .fixed:        self.glyphSymbol = "camera.fill"
        case .mobile:       self.glyphSymbol = "car.2.fill"
        case .averageSpeed: self.glyphSymbol = "timer"
        }
        super.init()
    }
}

// MARK: - Traffic incident MKAnnotation wrapper

private final class TrafficIncidentAnnotation: NSObject, MKAnnotation {
    let situationId: String
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?
    let markerColor: UIColor
    let glyphSymbol: String

    init(incident: TrafficIncident) {
        self.situationId = incident.situationId
        self.coordinate = incident.coordinate
        self.title = incident.headline
        self.subtitle = incident.detail
        switch incident.severity {
        case .minor:    self.markerColor = UIColor(SQ5Colors.warning)
        case .major:    self.markerColor = UIColor(SQ5Colors.warning)
        case .critical: self.markerColor = UIColor(SQ5Colors.danger)
        }
        switch incident.category {
        case .accident: self.glyphSymbol = "exclamationmark.triangle.fill"
        case .closure:  self.glyphSymbol = "xmark.octagon.fill"
        }
        super.init()
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
