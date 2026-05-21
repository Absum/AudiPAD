import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

/// PKCE-based OAuth for Spotify. Replaces the SDK's `SPTSessionManager`
/// so we can refresh the access token in perpetuity without running a
/// backend token-swap service — refresh under PKCE doesn't need the
/// client secret, which means everything fits inside the app.
///
/// One-shot interactive sign-in via `ASWebAuthenticationSession`, then
/// silent refresh on every expiry. The user only sees the auth sheet
/// the first time (or after a revoke from `spotify.com/account/apps`).
@MainActor
final class SpotifyAuth: NSObject {

    /// Client ID provisioned in the Spotify Developer dashboard for
    /// AudiPad. Public — fine to ship in the binary (PKCE is designed
    /// for clients that cannot keep secrets).
    private let clientID: String
    private let redirectURI: String
    private let scopes: [String]

    /// In-memory cache populated from Keychain on first read. Avoids
    /// hitting Keychain on every `validAccessToken()` call.
    private var cachedRefreshToken: String?
    private var cachedAccessToken: String?
    private var accessTokenExpiry: Date?

    /// Stores the verifier for an in-flight authorize request so we
    /// can hand it to the token-exchange POST when the callback fires.
    private var pendingVerifier: String?

    /// The auth session is held strongly while open — releasing it
    /// dismisses the sheet.
    private var webAuthSession: ASWebAuthenticationSession?

    /// Single in-flight refresh task so concurrent transport calls
    /// don't race and burn through the refresh-token's rate limit.
    private var refreshTask: Task<String?, Never>?

    init(clientID: String,
         redirectURI: String,
         scopes: [String]) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
        super.init()
        // Hydrate the in-memory cache from Keychain on init so we don't
        // pay the OS roundtrip on every call.
        self.cachedRefreshToken = KeychainStore.getString(forKey: Self.refreshTokenKey)
        self.cachedAccessToken = KeychainStore.getString(forKey: Self.accessTokenKey)
        if let raw = KeychainStore.getString(forKey: Self.accessExpiryKey),
           let secs = TimeInterval(raw) {
            self.accessTokenExpiry = Date(timeIntervalSince1970: secs)
        }
    }

    /// `true` if we have a refresh token — i.e. the user has signed in
    /// at least once and we can mint a new access token silently.
    var hasStoredCredentials: Bool { cachedRefreshToken != nil }

    /// Returns a fresh access token (refreshing if needed) or nil if
    /// we've never signed in / the refresh has been revoked. Caller is
    /// expected to handle the nil case by surfacing a Connect button
    /// that calls `signIn()`.
    func validAccessToken() async -> String? {
        if let token = cachedAccessToken,
           let exp = accessTokenExpiry,
           // 60-second slop so we don't return a token that expires
           // mid-request.
           exp.timeIntervalSinceNow > 60 {
            return token
        }
        guard cachedRefreshToken != nil else { return nil }
        return await refreshAccessToken()
    }

    /// Force a refresh — call after a 401 in case the token expired
    /// between our slop window and the server's clock.
    func forceRefresh() async -> String? {
        await refreshAccessToken()
    }

    /// Clear stored credentials. Next call to `validAccessToken()`
    /// returns nil and the UI should prompt `signIn()`.
    func signOut() {
        cachedAccessToken = nil
        cachedRefreshToken = nil
        accessTokenExpiry = nil
        KeychainStore.delete(key: Self.accessTokenKey)
        KeychainStore.delete(key: Self.refreshTokenKey)
        KeychainStore.delete(key: Self.accessExpiryKey)
    }

    // MARK: - Interactive sign-in

    /// Drives the one-time PKCE flow:
    ///   1. Generate a verifier + S256 challenge.
    ///   2. Open accounts.spotify.com/authorize in
    ///      `ASWebAuthenticationSession` (Safari-backed; reuses the
    ///      user's existing Spotify cookies, so they typically just
    ///      tap "Agree" once).
    ///   3. Receive `audipad://spotify-auth-callback?code=...&state=...`.
    ///   4. POST to /api/token to exchange the code for both
    ///      access + refresh tokens, persist in Keychain.
    func signIn() async throws -> String {
        let verifier = Self.makeCodeVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let state = Self.makeState()
        pendingVerifier = verifier

        let url = try authorizeURL(challenge: challenge, state: state)
        let callback = try await presentWebAuth(url: url)
        guard let code = Self.queryItem(from: callback, name: "code") else {
            if let err = Self.queryItem(from: callback, name: "error") {
                throw AuthError.providerError(err)
            }
            throw AuthError.missingCode
        }
        // Verify state to defend against cross-session callback mix-ups.
        guard Self.queryItem(from: callback, name: "state") == state else {
            throw AuthError.stateMismatch
        }
        return try await exchangeCodeForTokens(code: code, verifier: verifier)
    }

    private func authorizeURL(challenge: String, state: String) throws -> URL {
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state),
            // Force the consent screen — without this Spotify may
            // skip the agree step and immediately redirect, which is
            // fine but makes the one-shot flow feel jarringly fast.
            // Trade-off: user always taps Agree once. Acceptable.
            URLQueryItem(name: "show_dialog", value: "true"),
        ]
        guard let url = c.url else { throw AuthError.badAuthorizeURL }
        return url
    }

    private func presentWebAuth(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            // `callbackURLScheme` is the host-less prefix the system
            // matches against — for `audipad://spotify-auth-callback`
            // we pass just "audipad".
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: "audipad"
            ) { callbackURL, error in
                if let error {
                    if let asError = error as? ASWebAuthenticationSessionError,
                       asError.code == .canceledLogin {
                        cont.resume(throwing: AuthError.userCancelled)
                    } else {
                        cont.resume(throwing: error)
                    }
                    return
                }
                guard let callbackURL else {
                    cont.resume(throwing: AuthError.missingCallback)
                    return
                }
                cont.resume(returning: callbackURL)
            }
            session.presentationContextProvider = self
            // `prefersEphemeralWebBrowserSession = false` is the
            // default and what we want — it shares Safari cookies so
            // an already-logged-in user just taps Agree, no password.
            session.prefersEphemeralWebBrowserSession = false
            self.webAuthSession = session
            if !session.start() {
                cont.resume(throwing: AuthError.failedToStart)
                self.webAuthSession = nil
            }
        }
    }

    // MARK: - Token endpoint

    private func exchangeCodeForTokens(code: String, verifier: String) async throws -> String {
        let body: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", clientID),
            ("code_verifier", verifier),
        ]
        let response = try await postTokenForm(body: body)
        persist(response: response)
        guard let token = response.accessToken else { throw AuthError.missingAccessToken }
        return token
    }

    private func refreshAccessToken() async -> String? {
        if let existing = refreshTask {
            return await existing.value
        }
        let task = Task<String?, Never> { [weak self] in
            guard let self,
                  let refresh = self.cachedRefreshToken else { return nil }
            let body: [(String, String)] = [
                ("grant_type", "refresh_token"),
                ("refresh_token", refresh),
                ("client_id", self.clientID),
            ]
            do {
                let response = try await self.postTokenForm(body: body)
                self.persist(response: response)
                return response.accessToken
            } catch AuthError.providerError(let kind) where kind == "invalid_grant" {
                // Refresh token was revoked (user removed AudiPad in
                // their Spotify account settings) — clear so the UI
                // surfaces Connect.
                self.signOut()
                return nil
            } catch {
                // Transient (network blip, 5xx). Keep the cached
                // tokens — the next caller will try again.
                return nil
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        return await task.value
    }

    private struct TokenResponse: Decodable {
        let access_token: String?
        let token_type: String?
        let expires_in: Int?
        let refresh_token: String?
        let scope: String?
        let error: String?
        let error_description: String?

        var accessToken: String? { access_token }
    }

    private func postTokenForm(body: [(String, String)]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded",
                     forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formURLEncode(body).data(using: .utf8)
        req.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.networkError(URLError(.badServerResponse))
        }
        let parsed = (try? JSONDecoder().decode(TokenResponse.self, from: data))
            ?? TokenResponse(access_token: nil, token_type: nil,
                             expires_in: nil, refresh_token: nil,
                             scope: nil, error: nil, error_description: nil)
        if http.statusCode != 200 {
            if let err = parsed.error { throw AuthError.providerError(err) }
            throw AuthError.httpStatus(http.statusCode)
        }
        return parsed
    }

    private func persist(response: TokenResponse) {
        if let access = response.access_token {
            cachedAccessToken = access
            KeychainStore.setString(access, forKey: Self.accessTokenKey)
        }
        // Spotify rotates the refresh_token sometimes. Always keep
        // whichever we just received; if the response omits it, keep
        // the one we had.
        if let refresh = response.refresh_token {
            cachedRefreshToken = refresh
            KeychainStore.setString(refresh, forKey: Self.refreshTokenKey)
        }
        if let expiresIn = response.expires_in {
            let exp = Date().addingTimeInterval(TimeInterval(expiresIn))
            accessTokenExpiry = exp
            KeychainStore.setString(String(exp.timeIntervalSince1970),
                                    forKey: Self.accessExpiryKey)
        }
    }

    // MARK: - PKCE helpers

    private static func makeCodeVerifier() -> String {
        // RFC 7636 says 43-128 chars, URL-safe alphabet only. 48
        // bytes of randomness → 64 base64url chars, well within the
        // allowed range and gives 384 bits of entropy.
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncode(Data(bytes))
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    private static func makeState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncode(Data(bytes))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formURLEncode(_ pairs: [(String, String)]) -> String {
        pairs.map {
            "\(percent($0.0))=\(percent($0.1))"
        }.joined(separator: "&")
    }

    private static func percent(_ s: String) -> String {
        // application/x-www-form-urlencoded: standard URL encoding but
        // space becomes '+'. Apple's default urlQueryAllowed set keeps
        // spaces, so we percent-encode manually.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func queryItem(from url: URL, name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    // MARK: - Errors + storage keys

    enum AuthError: Error, LocalizedError {
        case badAuthorizeURL
        case failedToStart
        case userCancelled
        case missingCallback
        case missingCode
        case stateMismatch
        case missingAccessToken
        case providerError(String)
        case httpStatus(Int)
        case networkError(Error)

        var errorDescription: String? {
            switch self {
            case .badAuthorizeURL: return "Couldn't build Spotify authorize URL."
            case .failedToStart: return "Couldn't start Spotify sign-in sheet."
            case .userCancelled: return "Sign-in cancelled."
            case .missingCallback: return "Spotify didn't return a callback URL."
            case .missingCode: return "Spotify didn't return an auth code."
            case .stateMismatch: return "Spotify sign-in state mismatch."
            case .missingAccessToken: return "Spotify token response had no access_token."
            case .providerError(let s): return "Spotify auth error: \(s)"
            case .httpStatus(let c): return "Spotify auth HTTP \(c)"
            case .networkError(let e): return e.localizedDescription
            }
        }
    }

    private static let accessTokenKey = "audipad.spotify.accessToken"
    private static let refreshTokenKey = "audipad.spotify.refreshToken"
    private static let accessExpiryKey = "audipad.spotify.accessExpiry"
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension SpotifyAuth: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Find the active foreground window. For an iPad app with a
        // single scene this is unambiguous. Falls back to a placeholder
        // ASPresentationAnchor() if the runtime is somehow racing us,
        // which the system gracefully resolves.
        let scenes = UIApplication.shared.connectedScenes
        let active = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
            ?? scenes.first as? UIWindowScene
        return active?.windows.first(where: { $0.isKeyWindow })
            ?? active?.windows.first
            ?? ASPresentationAnchor()
    }
}
