import SwiftUI

@main
struct AudiPadApp: App {
    /// Owned at the App level so the `.onOpenURL` redirect from the
    /// Spotify auth flow lands here regardless of which tab is on screen.
    @StateObject private var spotify = SpotifyService()
    @StateObject private var screenWake = ScreenWakeService()

    /// Lifted from `ContentView` so the deep-link handler below can
    /// switch tabs in response to `audipad://map` (and friends) when
    /// the Shortcuts "Charger Connected" automation opens us via URL.
    @State private var selectedTab: AppTab = .home

    @Environment(\.scenePhase) private var scenePhase

    init() {
        SQ5Theme.applyGlobalAppearance()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(selectedTab: $selectedTab)
                .preferredColorScheme(.dark)
                .background(SQ5Colors.background.ignoresSafeArea())
                .persistentSystemOverlays(.hidden)
                .environmentObject(spotify)
                .environmentObject(screenWake)
                .onOpenURL { url in
                    handle(url: url)
                }
                .onChange(of: scenePhase) { phase in
                    screenWake.update(scenePhase: phase)
                }
        }
    }

    /// Route an incoming `audipad://` URL. Two flavours:
    ///   * `audipad://spotify-auth-callback?…` — OAuth return.
    ///   * `audipad://<tab>` — deep-link to a tab (`map`, `home`,
    ///     `drive`, `media`, `settings`). Used by the Charger-Connected
    ///     Shortcut so the dashboard opens straight on the map.
    private func handle(url: URL) {
        let host = url.host ?? ""
        if host == "spotify-auth-callback" {
            spotify.handle(url: url)
            return
        }
        if let tab = AppTab(deepLinkHost: host) {
            selectedTab = tab
        }
    }
}

private extension AppTab {
    init?(deepLinkHost host: String) {
        switch host {
        case "home":     self = .home
        case "drive":    self = .drive
        case "map":      self = .map
        case "media":    self = .media
        case "racing":   self = .racing
        case "settings": self = .settings
        default: return nil
        }
    }
}
