import SwiftUI

struct MediaView: View {
    var body: some View {
        ZStack {
            SQ5Colors.background.ignoresSafeArea()

            HStack(spacing: 48) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(SQ5Colors.surfaceElevated)
                    .frame(width: 240, height: 240)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 84, weight: .light))
                            .foregroundStyle(SQ5Colors.textTertiary)
                    )

                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Nothing playing")
                            .font(SQ5Typography.title)
                            .foregroundStyle(SQ5Colors.textPrimary)
                        Text("Media controls placeholder")
                            .font(SQ5Typography.subtitle)
                            .foregroundStyle(SQ5Colors.textSecondary)
                    }

                    HStack(spacing: 36) {
                        TransportButton(symbol: "backward.fill", size: 26)
                        TransportButton(symbol: "play.fill", size: 40)
                        TransportButton(symbol: "forward.fill", size: 26)
                    }
                }
            }
        }
    }
}

private struct TransportButton: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(SQ5Colors.textPrimary)
            .frame(width: size + 32, height: size + 32)
            .background(
                Circle()
                    .fill(SQ5Colors.surface)
                    .overlay(Circle().stroke(SQ5Colors.border, lineWidth: 1))
            )
    }
}

#Preview("Media — landscape", traits: .landscapeLeft) {
    MediaView()
        .preferredColorScheme(.dark)
}
