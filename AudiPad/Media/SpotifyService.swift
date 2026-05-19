import Foundation
import UIKit
import SwiftUI
import SpotifyiOS

/// Bridges AudiPad to the user's running Spotify app via Spotify's
/// official iOS App Remote SDK. Reads the current playback state and
/// sends transport commands.
///
/// Requirements:
///   • Spotify app installed on the device
///   • Spotify Premium account (free accounts can't be controlled by the SDK)
///   • Music actively playing (or recently played) when `connect()` is
///     called — otherwise Spotify is suspended and the IPC connection
///     can't be established. The SDK docs are explicit about this.
@MainActor
final class SpotifyService: NSObject, ObservableObject {

    struct NowPlaying: Equatable {
        var title: String
        var artist: String
        var album: String?
        var artwork: UIImage?
        var isPaused: Bool
    }

    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var lastError: String?

    // App credentials. Client ID provisioned in the Spotify Developer
    // dashboard; redirect URI must match the CFBundleURLSchemes entry in
    // Info.plist exactly.
    private let clientID = "73b7a8a632db456f826680d5bcbe9e9c"
    private let redirectURL = URL(string: "audipad://spotify-auth-callback")!

    private lazy var configuration = SPTConfiguration(clientID: clientID, redirectURL: redirectURL)
    private lazy var appRemote: SPTAppRemote = {
        let remote = SPTAppRemote(configuration: configuration, logLevel: .debug)
        remote.delegate = self
        return remote
    }()

    /// Persisted OAuth access token. Lets us reconnect on subsequent
    /// launches without re-prompting the user, until Spotify rotates it.
    private var accessToken: String? {
        get { UserDefaults.standard.string(forKey: Self.tokenKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.tokenKey) }
    }
    private static let tokenKey = "audipad.spotify.accessToken"

    // MARK: - Public API

    /// Try to connect to Spotify. If we have a cached token we connect
    /// immediately; otherwise we kick off the authorize flow which jumps
    /// to the Spotify app (must be installed). The user taps "Authorize"
    /// and Spotify returns to AudiPad via the `audipad://` URL scheme.
    func connect() {
        if let token = accessToken {
            appRemote.connectionParameters.accessToken = token
            appRemote.connect()
        } else {
            // Empty URI = "just authorize, don't start a specific track".
            appRemote.authorizeAndPlayURI("")
        }
    }

    func disconnect() {
        if appRemote.isConnected { appRemote.disconnect() }
    }

    /// Called by `AudiPadApp.onOpenURL` when the auth flow returns to us.
    /// Extracts the access token from the URL parameters and uses it to
    /// connect the App Remote.
    func handle(url: URL) {
        let params = appRemote.authorizationParameters(from: url)
        if let token = params?[SPTAppRemoteAccessTokenKey] {
            accessToken = token
            appRemote.connectionParameters.accessToken = token
            appRemote.connect()
        } else if let error = params?[SPTAppRemoteErrorDescriptionKey] {
            lastError = error
        }
    }

    func togglePlayPause() {
        guard isConnected else { return }
        if nowPlaying?.isPaused == true {
            appRemote.playerAPI?.resume(handlePlayerResult)
        } else {
            appRemote.playerAPI?.pause(handlePlayerResult)
        }
    }

    func next() {
        guard isConnected else { return }
        appRemote.playerAPI?.skip(toNext: handlePlayerResult)
    }

    func previous() {
        guard isConnected else { return }
        appRemote.playerAPI?.skip(toPrevious: handlePlayerResult)
    }

    private func handlePlayerResult(_ result: Any?, _ error: Error?) {
        if let error {
            Task { @MainActor in self.lastError = error.localizedDescription }
        }
    }

    // MARK: - Artwork

    private func fetchArtwork(for track: SPTAppRemoteTrack) {
        appRemote.imageAPI?.fetchImage(forItem: track,
                                       with: CGSize(width: 480, height: 480)) { [weak self] image, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let image = image as? UIImage, var np = self.nowPlaying {
                    np.artwork = image
                    self.nowPlaying = np
                } else if let error {
                    self.lastError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Connection state

extension SpotifyService: SPTAppRemoteDelegate {

    nonisolated func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        Task { @MainActor in
            self.isConnected = true
            self.lastError = nil
            appRemote.playerAPI?.delegate = self
            appRemote.playerAPI?.subscribe { [weak self] _, error in
                if let error {
                    Task { @MainActor in self?.lastError = error.localizedDescription }
                }
            }
        }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        Task { @MainActor in
            self.isConnected = false
            self.lastError = error?.localizedDescription ?? "Connection failed"
        }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        Task { @MainActor in
            self.isConnected = false
            if let error { self.lastError = error.localizedDescription }
        }
    }
}

// MARK: - Player state

extension SpotifyService: SPTAppRemotePlayerStateDelegate {
    nonisolated func playerStateDidChange(_ playerState: SPTAppRemotePlayerState) {
        let title = playerState.track.name
        let artist = playerState.track.artist.name
        let album = playerState.track.album.name
        let isPaused = playerState.isPaused
        let track = playerState.track

        Task { @MainActor in
            let prevArtwork = (self.nowPlaying?.title == title) ? self.nowPlaying?.artwork : nil
            self.nowPlaying = NowPlaying(
                title: title,
                artist: artist,
                album: album,
                artwork: prevArtwork,
                isPaused: isPaused
            )
            // Always request a fresh artwork fetch for the current track
            // (cheap if cached, ensures we replace stale art on song change).
            self.fetchArtwork(for: track)
        }
    }
}
