import SwiftUI

@main
struct AudiPadApp: App {
    init() {
        SQ5Theme.applyGlobalAppearance()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .background(SQ5Colors.background.ignoresSafeArea())
                .persistentSystemOverlays(.hidden)
        }
    }
}
