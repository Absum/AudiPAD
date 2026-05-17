import SwiftUI

struct MapTabView: View {
    var body: some View {
        ZStack {
            SQ5Colors.background.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "map")
                    .font(.system(size: 72, weight: .light))
                    .foregroundStyle(SQ5Colors.textTertiary)
                Text("Map")
                    .font(SQ5Typography.title)
                    .foregroundStyle(SQ5Colors.textPrimary)
                Text("MapKit integration coming soon")
                    .font(SQ5Typography.subtitle)
                    .foregroundStyle(SQ5Colors.textSecondary)
            }
        }
    }
}

struct MapTabView_Previews: PreviewProvider {
    static var previews: some View {
        MapTabView().preferredColorScheme(.dark)
    }
}
