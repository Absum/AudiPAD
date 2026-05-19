import Foundation
import UIKit
import SwiftUI
import SpotifyiOS

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
/// Auth: `SPTSessionManager` (still part of the iOS SDK) for the
/// auth bounce — same Spotify app, same URL callback — but it lets
/// us explicitly request the Web API scopes we need:
///   • app-remote-control (kept for forward compatibility)
///   • user-read-playback-state — required for GET /me/player
///   • user-modify-playback-state — required for play/pause/skip
///   • user-read-currently-playing — required for currently-playing
///
/// State refresh: 3-second polling against GET /me/player. Web API
/// doesn't push, so the tradeoff is ~20 req/min while connected.
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
    // dashboard; redirect URI must match CFBundleURLSchemes in
    // Info.plist exactly.
    private let clientID = "73b7a8a632db456f826680d5bcbe9e9c"
    private let redirectURL = URL(string: "audipad://spotify-auth-callback")!

    private lazy var configuration = SPTConfiguration(clientID: clientID, redirectURL: redirectURL)
    private lazy var sessionManager: SPTSessionManager = {
        SPTSessionManager(configuration: configuration, delegate: self)
    }()

    /// Scopes we ask the user to grant during the OAuth bounce. They
    /// stick to the token; subsequent silent renewals inherit them.
    private static let requiredScopes: SPTScope = [
        .appRemoteControl,
        .userReadPlaybackState,
        .userModifyPlaybackState,
        .userReadCurrentlyPlaying,
    ]

    /// Cached OAuth access token from the last successful auth.
    /// Persists across launches so users don't have to re-auth.
    private var accessToken: String? {
        get { UserDefaults.standard.string(forKey: Self.tokenKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.tokenKey) }
    }
    private static let tokenKey = "audipad.spotify.accessToken"

    private var pollTask: Task<Void, Never>?
    private static let pollIntervalSeconds: Double = 3

    /// Track ID whose artwork we've already downloaded — avoids
    /// re-fetching the same image on every 3-second poll.
    private var lastArtworkTrackID: String?

    // MARK: - Public API

    /// Single-tap connect. If we already have a token, start polling
    /// the Web API immediately; otherwise bounce to Spotify for OAuth
    /// (which returns via `audipad://spotify-auth-callback` and lands
    /// in `handle(url:)`).
    func connect() {
        if accessToken != nil {
            startPolling()
        } else {
            sessionManager.initiateSession(with: Self.requiredScopes, options: .default, campaign: "")
        }
    }

    func disconnect() {
        stopPolling()
        isConnected = false
    }

    /// Called by `AudiPadApp.onOpenURL` when the auth flow returns to
    /// us. Delegates to `SPTSessionManager` which fires
    /// `sessionManager(_:didInitiate:)` on success.
    func handle(url: URL) {
        _ = sessionManager.application(UIApplication.shared, open: url, options: [:])
    }

    func togglePlayPause() {
        guard accessToken != nil else { return }
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
        guard accessToken != nil else { return }
        Task { await self.transport(.next) }
    }

    func previous() {
        guard accessToken != nil else { return }
        Task { await self.transport(.previous) }
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
        guard let token = accessToken else { return }
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
            case 401, 403:
                // Token expired or missing scopes — invalidate and
                // wait for the user to tap Connect to re-auth.
                self.accessToken = nil
                self.isConnected = false
                self.nowPlaying = nil
                self.lastError = "Spotify session expired. Tap Connect."
                self.stopPolling()
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
        guard let token = accessToken else { return }
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
            case 401, 403:
                self.accessToken = nil
                self.isConnected = false
                self.lastError = "Spotify session expired. Tap Connect."
                self.stopPolling()
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

// MARK: - SPTSessionManagerDelegate

extension SpotifyService: SPTSessionManagerDelegate {

    nonisolated func sessionManager(manager: SPTSessionManager, didInitiate session: SPTSession) {
        Task { @MainActor in
            self.accessToken = session.accessToken
            self.isConnected = true
            self.lastError = nil
            self.startPolling()
        }
    }

    nonisolated func sessionManager(manager: SPTSessionManager, didFailWith error: Error) {
        Task { @MainActor in
            self.lastError = error.localizedDescription
            self.isConnected = false
        }
    }

    nonisolated func sessionManager(manager: SPTSessionManager, didRenew session: SPTSession) {
        Task { @MainActor in
            self.accessToken = session.accessToken
        }
    }
}
