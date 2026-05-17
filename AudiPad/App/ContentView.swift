import SwiftUI

struct ContentView: View {
    @State private var selectedTab: AppTab = .home

    var body: some View {
        HStack(spacing: 0) {
            NavRail(selection: $selectedTab)

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
        }
        .background(SQ5Colors.background.ignoresSafeArea())
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .preferredColorScheme(.dark)
            .previewInterfaceOrientation(.landscapeLeft)
    }
}
