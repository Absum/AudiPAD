import SwiftUI

@main
struct AudiPadApp: App {
    /// Owned at the App level so the `.onOpenURL` redirect from the
    /// Spotify auth flow lands here regardless of which tab is on screen.
    @StateObject private var spotify = SpotifyService()
    @StateObject private var screenWake = ScreenWakeService()

    @Environment(\.scenePhase) private var scenePhase

    init() {
        SQ5Theme.applyGlobalAppearance()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .background(SQ5Colors.background.ignoresSafeArea())
                .persistentSystemOverlays(.hidden)
                .environmentObject(spotify)
                .environmentObject(screenWake)
                .onOpenURL { url in
                    // Spotify returns here via `audipad://spotify-auth-callback?...`
                    // after the user taps Authorize in the Spotify app.
                    spotify.handle(url: url)
                }
                .onChange(of: scenePhase) { phase in
                    screenWake.update(scenePhase: phase)
                }
        }
    }
}
