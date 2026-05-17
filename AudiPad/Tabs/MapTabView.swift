import SwiftUI
import MapKit

struct MapTabView: View {
    @StateObject private var vm = MapViewModel()
    @State private var searchText: String = ""
    @State private var isSearching: Bool = false

    var body: some View {
        ZStack(alignment: .top) {
            MapBackground(region: $vm.region,
                          routePolyline: vm.routePolyline)
                .ignoresSafeArea()

            // Top gradient so TopBar stays readable over any map tile color
            LinearGradient(
                colors: [SQ5Colors.background.opacity(0.95),
                         SQ5Colors.background.opacity(0.0)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 140)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)

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
                        .onSubmit { runSearch() }

                    if isSearching {
                        ProgressView()
                            .tint(SQ5Colors.textTertiary)
                            .scaleEffect(0.7)
                    } else if !searchText.isEmpty {
                        Button {
                            searchText = ""
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
                .padding(.bottom, 8)

                Spacer()

                // Route info overlay (bottom, only when route exists)
                if let info = vm.routeInfo {
                    RouteInfoCard(info: info,
                                  onClear: {
                                      searchText = ""
                                      vm.clearRoute()
                                  })
                    .padding(.horizontal, 26)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: vm.routeInfo != nil)
        }
    }

    private func runSearch() {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSearching = true
        Task {
            await vm.search(query: searchText)
            await MainActor.run { isSearching = false }
        }
    }
}

// MARK: - Route info card

private struct RouteInfoCard: View {
    let info: MapViewModel.RouteInfo
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
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
                    .font(.system(size: 24, weight: .light, design: .default))
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
                    .background(
                        Circle().fill(SQ5Colors.surfaceElevated)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(SQ5Colors.background.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(SQ5Colors.border, lineWidth: 1)
                )
        )
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

    /// Default region: Helsinki (user is FI-based per Nordic SKU iPad).
    @Published var region: MKCoordinateRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 60.1699, longitude: 24.9384),
        span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
    )
    @Published var routePolyline: MKPolyline? = nil
    @Published var routeInfo: RouteInfo? = nil

    func search(query: String) async {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        req.region = region

        do {
            let response = try await MKLocalSearch(request: req).start()
            guard let destination = response.mapItems.first else { return }
            await calculateRoute(to: destination)
        } catch {
            // Swallow for now — no destination found / no network. v1 silence is OK.
        }
    }

    private func calculateRoute(to destination: MKMapItem) async {
        // Route from current map-center (no location permission required for v1).
        let source = MKMapItem(placemark: MKPlacemark(coordinate: region.center))

        let req = MKDirections.Request()
        req.source = source
        req.destination = destination
        req.transportType = .automobile

        do {
            let response = try await MKDirections(request: req).calculate()
            guard let route = response.routes.first else { return }
            self.routePolyline = route.polyline
            self.routeInfo = RouteInfo(
                title: destination.name ?? "Destination",
                distance: Self.formatDistance(route.distance),
                duration: Self.formatDuration(route.expectedTravelTime)
            )
            // Fit the route into view with a little padding.
            let rect = route.polyline.boundingMapRect.insetBy(dx: -route.polyline.boundingMapRect.size.width * 0.1,
                                                              dy: -route.polyline.boundingMapRect.size.height * 0.1)
            self.region = MKCoordinateRegion(rect)
        } catch {
            // No route possible — leave existing state.
        }
    }

    func clearRoute() {
        routePolyline = nil
        routeInfo = nil
    }

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

private struct MapBackground: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    let routePolyline: MKPolyline?

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = false
        map.pointOfInterestFilter = .excludingAll
        map.overrideUserInterfaceStyle = .dark
        map.setRegion(region, animated: false)
        return map
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        // Animate region change if it's noticeably different from current.
        if regionDiffers(uiView.region, region) {
            uiView.setRegion(region, animated: true)
        }
        // Replace overlays
        uiView.removeOverlays(uiView.overlays)
        if let p = routePolyline {
            uiView.addOverlay(p, level: .aboveRoads)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func regionDiffers(_ a: MKCoordinateRegion, _ b: MKCoordinateRegion) -> Bool {
        let dLat = abs(a.center.latitude - b.center.latitude)
        let dLon = abs(a.center.longitude - b.center.longitude)
        let dSpan = abs(a.span.latitudeDelta - b.span.latitudeDelta) + abs(a.span.longitudeDelta - b.span.longitudeDelta)
        return dLat > 0.0005 || dLon > 0.0005 || dSpan > 0.005
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
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
            .preferredColorScheme(.dark)
            .previewInterfaceOrientation(.landscapeLeft)
    }
}
