import SwiftUI

struct MediaView: View {
    @EnvironmentObject private var vehicle: VehicleViewModel
    @EnvironmentObject private var spotify: SpotifyService

    var body: some View {
        ZStack {
            SQ5Colors.background.ignoresSafeArea()

            VStack(spacing: 0) {
                TopBar(fuelPercent: vehicle.snapshot.fuelPercent, showSpeed: true)
                Spacer()
                content
                Spacer()
            }
        }
    }

    private var content: some View {
        HStack(spacing: 48) {
            artwork
            VStack(alignment: .leading, spacing: 24) {
                trackInfo
                transport
            }
            .frame(maxWidth: 420, alignment: .leading)
        }
    }

    private var artwork: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(SQ5Colors.surfaceElevated)
            .frame(width: 240, height: 240)
            .overlay {
                if let art = spotify.nowPlaying?.artwork {
                    Image(uiImage: art)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 240, height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 84, weight: .light))
                        .foregroundStyle(SQ5Colors.textTertiary)
                }
            }
    }

    @ViewBuilder
    private var trackInfo: some View {
        if let np = spotify.nowPlaying {
            VStack(alignment: .leading, spacing: 8) {
                Text(np.title)
                    .font(SQ5Typography.title)
                    .foregroundStyle(SQ5Colors.textPrimary)
                    .lineLimit(2)
                Text(np.artist)
                    .font(SQ5Typography.subtitle)
                    .foregroundStyle(SQ5Colors.textSecondary)
                    .lineLimit(1)
                if let album = np.album, !album.isEmpty {
                    Text(album)
                        .font(SQ5Typography.body)
                        .foregroundStyle(SQ5Colors.textTertiary)
                        .lineLimit(1)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text(spotify.isConnected ? "Connected" : "Spotify")
                    .font(SQ5Typography.title)
                    .foregroundStyle(SQ5Colors.textPrimary)
                Text(spotify.isConnected
                     ? "Start playback in Spotify."
                     : "Play music in Spotify on this iPad, then tap Connect.")
                    .font(SQ5Typography.subtitle)
                    .foregroundStyle(SQ5Colors.textSecondary)
                    .lineLimit(3)
                if !spotify.isConnected {
                    Button(action: { spotify.connect() }) {
                        Text("Connect Spotify")
                            .font(SQ5Typography.subtitle)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(
                                Capsule().fill(Color(red: 0.11, green: 0.73, blue: 0.33))
                            )
                    }
                    .buttonStyle(.plain)
                }
                if let err = spotify.lastError {
                    Text(err)
                        .font(SQ5Typography.caption)
                        .foregroundStyle(SQ5Colors.danger)
                        .lineLimit(2)
                }
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 36) {
            TransportButton(symbol: "backward.fill", size: 26, enabled: spotify.isConnected) {
                spotify.previous()
            }
            TransportButton(
                symbol: (spotify.nowPlaying?.isPaused ?? true) ? "play.fill" : "pause.fill",
                size: 40,
                enabled: spotify.isConnected
            ) {
                spotify.togglePlayPause()
            }
            TransportButton(symbol: "forward.fill", size: 26, enabled: spotify.isConnected) {
                spotify.next()
            }
        }
    }
}

private struct TransportButton: View {
    let symbol: String
    let size: CGFloat
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(enabled ? SQ5Colors.textPrimary : SQ5Colors.textTertiary)
                .frame(width: size + 32, height: size + 32)
                .background(
                    Circle()
                        .fill(SQ5Colors.surface)
                        .overlay(Circle().stroke(SQ5Colors.border, lineWidth: 1))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

struct MediaView_Previews: PreviewProvider {
    static var previews: some View {
        MediaView()
            .preferredColorScheme(.dark)
            .previewInterfaceOrientation(.landscapeLeft)
            .environmentObject(VehicleViewModel())
            .environmentObject(LocationService())
            .environmentObject(SpotifyService())
    }
}
