import Foundation
import UIKit
import SwiftUI

/// Bridges AudiPad to the user's Spotify session via the Spotify Web
/// API. Designed for AudiPad's primary use case: head-unit display +
/// controls while the actual audio plays on the user's phone (or any
/// other Spotify Connect device).
///
/// Architecture: Web API only — we do NOT use the iOS SDK's App
/// Remote. App Remote talks to the *local* Spotify app's IPC socket,
/// which closes the moment playback transfers to another device.
/// Web API works regardless of which device is currently playing.
///
/// Auth: manual PKCE OAuth in `SpotifyAuth` — the iOS SDK's
/// `SPTSessionManager.renewSession()` requires a server-side
/// token-swap endpoint with the client secret, which we don't want
/// to run for a single-user car install. PKCE lets us refresh the
/// access token in perpetuity from inside the app, so the user signs
/// in once (one-time Safari sheet) and never sees the auth screen
/// again unless they revoke AudiPad from spotify.com/account/apps.
///
/// State refresh: 3-second polling against GET /me/player. Web API
/// doesn't push, so the tradeoff is ~20 req/min while connected.
@MainActor
final class SpotifyService: ObservableObject {

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
    // dashboard; redirect URI must match CFBundleURLSchemes in
    // Info.plist exactly AND be registered in the Spotify dashboard.
    private let clientID = "73b7a8a632db456f826680d5bcbe9e9c"
    private let redirectURI = "audipad://spotify-auth-callback"

    private lazy var auth: SpotifyAuth = SpotifyAuth(
        clientID: clientID,
        redirectURI: redirectURI,
        scopes: [
            // Kept for forward compatibility with any future App-Remote
            // wiring. The Web API itself doesn't require it.
            "app-remote-control",
            "user-read-playback-state",
            "user-modify-playback-state",
            "user-read-currently-playing",
        ]
    )

    private var pollTask: Task<Void, Never>?
    private static let pollIntervalSeconds: Double = 3

    /// Track ID whose artwork we've already downloaded — avoids
    /// re-fetching the same image on every 3-second poll.
    private var lastArtworkTrackID: String?

    // MARK: - Public API

    /// Single-tap connect. Three paths:
    ///   1. Have stored refresh token AND a fresh access token → just
    ///      start polling.
    ///   2. Have a refresh token but the access token is stale → mint
    ///      a fresh one silently, start polling. No user interaction.
    ///   3. No refresh token (first launch or post-revoke) → kick the
    ///      one-time PKCE Safari sheet, then start polling.
    func connect() {
        Task { [weak self] in
            guard let self else { return }
            if self.auth.hasStoredCredentials {
                if await self.auth.validAccessToken() != nil {
                    self.isConnected = true
                    self.lastError = nil
                    self.startPolling()
                    return
                }
                // Refresh failed but credentials exist — surface error
                // and let the user tap Connect again to re-auth.
                self.lastError = "Spotify refresh failed. Tap Connect to sign in."
                self.auth.signOut()
                self.isConnected = false
                return
            }
            await self.runInteractiveSignIn()
        }
    }

    func disconnect() {
        stopPolling()
        isConnected = false
        auth.signOut()
    }

    /// Retained for backwards compatibility with the App's
    /// `.onOpenURL` plumbing. The PKCE flow uses
    /// `ASWebAuthenticationSession` which handles the callback
    /// internally — no URL needs to reach us here. But the SDK callers
    /// still call this on `audipad://spotify-auth-callback`, so we
    /// accept the URL and no-op.
    func handle(url: URL) {
        // No-op. ASWebAuthenticationSession captures the callback.
    }

    func togglePlayPause() {
        let wasPaused = nowPlaying?.isPaused ?? true
        // Optimistic UI flip so the icon updates instantly even before
        // the next 3-second poll lands.
        if var np = nowPlaying {
            np.isPaused = !wasPaused
            nowPlaying = np
        }
        Task { await self.transport(wasPaused ? .play : .pause) }
    }

    func next() {
        Task { await self.transport(.next) }
    }

    func previous() {
        Task { await self.transport(.previous) }
    }

    // MARK: - Interactive sign-in

    private func runInteractiveSignIn() async {
        do {
            _ = try await auth.signIn()
            isConnected = true
            lastError = nil
            startPolling()
        } catch SpotifyAuth.AuthError.userCancelled {
            // User dismissed the sheet — don't show this as an error.
            isConnected = false
        } catch {
            lastError = error.localizedDescription
            isConnected = false
        }
    }

    // MARK: - Polling

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            // Immediate first poll for snappy initial UI.
            await self?.pollPlaybackState()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollIntervalSeconds))
                if Task.isCancelled { break }
                await self?.pollPlaybackState()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollPlaybackState() async {
        guard let token = await auth.validAccessToken() else {
            handleAuthLost()
            return
        }
        let url = URL(string: "https://api.spotify.com/v1/me/player")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return }
            switch http.statusCode {
            case 200:
                let parsed = try JSONDecoder().decode(WebAPIPlayback.self, from: data)
                self.isConnected = true
                self.lastError = nil
                await applyPlayback(parsed)
            case 204:
                // No active device anywhere — Spotify isn't playing.
                self.isConnected = true
                self.lastError = nil
                self.nowPlaying = nil
                self.lastArtworkTrackID = nil
            case 401:
                // Access token slipped past our slop window. Force a
                // refresh and try again next tick. If the refresh
                // itself fails, `validAccessToken()` returns nil at
                // the top of this method on the next call.
                _ = await auth.forceRefresh()
            case 403:
                // Scopes mismatch / app disabled. User must re-auth.
                handleAuthLost()
            case 429:
                self.lastError = "Spotify API rate-limited; backing off."
            default:
                self.lastError = "Spotify API HTTP \(http.statusCode)"
            }
        } catch {
            // Network blip — keep polling, just surface the error.
            self.lastError = error.localizedDescription
        }
    }

    private func handleAuthLost() {
        auth.signOut()
        isConnected = false
        nowPlaying = nil
        lastError = "Spotify session expired. Tap Connect."
        stopPolling()
    }

    private func applyPlayback(_ p: WebAPIPlayback) async {
        let title = p.item?.name ?? ""
        let artist = p.item?.artists.first?.name ?? ""
        let album = p.item?.album.name
        let trackID = p.item?.id
        let isPaused = !(p.is_playing ?? false)

        // Keep the prior artwork if the track ID matches — saves a
        // download per 3-second poll on the same track.
        let prevArtwork: UIImage? = (trackID == lastArtworkTrackID) ? nowPlaying?.artwork : nil
        let next = NowPlaying(title: title, artist: artist, album: album,
                              artwork: prevArtwork, isPaused: isPaused)
        if next != nowPlaying { nowPlaying = next }

        if let trackID, trackID != lastArtworkTrackID,
           let imageURL = p.item?.album.images.first.flatMap({ URL(string: $0.url) }) {
            lastArtworkTrackID = trackID
            await fetchArtwork(from: imageURL, expectedTrackID: trackID)
        }
    }

    private func fetchArtwork(from url: URL, expectedTrackID: String) async {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            // Bail if the track changed while we were fetching.
            guard lastArtworkTrackID == expectedTrackID,
                  let image = UIImage(data: data)
            else { return }
            if var np = nowPlaying {
                np.artwork = image
                nowPlaying = np
            }
        } catch {
            // Best-effort; missing artwork isn't fatal.
        }
    }

    // MARK: - Transport (Web API)

    private enum TransportAction {
        case play, pause, next, previous

        var method: String {
            switch self {
            case .play, .pause: return "PUT"
            case .next, .previous: return "POST"
            }
        }

        var path: String {
            switch self {
            case .play: return "play"
            case .pause: return "pause"
            case .next: return "next"
            case .previous: return "previous"
            }
        }
    }

    private func transport(_ action: TransportAction) async {
        guard let token = await auth.validAccessToken() else {
            handleAuthLost()
            return
        }
        let url = URL(string: "https://api.spotify.com/v1/me/player/\(action.path)")!
        var req = URLRequest(url: url)
        req.httpMethod = action.method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("0", forHTTPHeaderField: "Content-Length")
        req.timeoutInterval = 10
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return }
            switch http.statusCode {
            case 200, 202, 204:
                // Refresh playback state so the UI reflects the
                // command immediately rather than waiting for the
                // next polling tick.
                await pollPlaybackState()
            case 401:
                // Single retry after a forced refresh — handles the
                // race where the token expired between our slop
                // window and the server.
                if let refreshed = await auth.forceRefresh() {
                    await transportRetry(action, token: refreshed)
                } else {
                    handleAuthLost()
                }
            case 403:
                handleAuthLost()
            case 404:
                self.lastError = "No active Spotify device. Start playback first."
            case 429:
                self.lastError = "Spotify API rate-limited; try again shortly."
            default:
                self.lastError = "Spotify API HTTP \(http.statusCode)"
            }
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    /// One-shot retry after a forced refresh, with no further retry on
    /// 401 (avoids infinite loops if the refresh token is itself dead).
    private func transportRetry(_ action: TransportAction, token: String) async {
        let url = URL(string: "https://api.spotify.com/v1/me/player/\(action.path)")!
        var req = URLRequest(url: url)
        req.httpMethod = action.method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("0", forHTTPHeaderField: "Content-Length")
        req.timeoutInterval = 10
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return }
            switch http.statusCode {
            case 200, 202, 204: await pollPlaybackState()
            case 401, 403: handleAuthLost()
            default: self.lastError = "Spotify API HTTP \(http.statusCode)"
            }
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    // MARK: - Web API model

    private struct WebAPIPlayback: Codable {
        let is_playing: Bool?
        let item: Item?

        struct Item: Codable {
            let id: String
            let name: String
            let artists: [Artist]
            let album: Album
        }

        struct Artist: Codable {
            let name: String
        }

        struct Album: Codable {
            let name: String
            let images: [Image]
        }

        struct Image: Codable {
            let url: String
            let width: Int?
            let height: Int?
        }
    }
}
