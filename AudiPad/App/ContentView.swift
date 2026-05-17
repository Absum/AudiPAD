import SwiftUI

struct ContentView: View {
    enum Tab: Hashable {
        case home, drive, map, media, settings
    }

    @State private var selectedTab: Tab = .home

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "gauge.medium") }
                .tag(Tab.home)

            DriveView()
                .tabItem { Label("Drive", systemImage: "car.fill") }
                .tag(Tab.drive)

            MapTabView()
                .tabItem { Label("Map", systemImage: "map.fill") }
                .tag(Tab.map)

            MediaView()
                .tabItem { Label("Media", systemImage: "play.circle.fill") }
                .tag(Tab.media)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .tint(SQ5Colors.accent)
        .background(SQ5Colors.background.ignoresSafeArea())
    }
}

#Preview("ContentView — landscape", traits: .landscapeLeft) {
    ContentView()
        .preferredColorScheme(.dark)
}
