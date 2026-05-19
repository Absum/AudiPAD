# Changelog

All notable changes to AudiPad are recorded here. Style: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
The build number on each release heading is the `CFBundleVersion` shipped in that build.

## Unreleased

### Media
- New `SpotifyService` integrating Spotify's official iOS App Remote SDK (v5.0.1, SPM binary target). Reads now-playing state (title, artist, album, artwork, paused/playing) from the user's running Spotify app and controls playback (play/pause, next, previous).
- `MediaView` rebuilt to display live Spotify metadata + working transport buttons. Empty state offers a "Connect Spotify" button that kicks off the OAuth handshake.
- OAuth callback handled at `AudiPadApp` level via `.onOpenURL` against the `audipad://spotify-auth-callback` redirect URI. Access token cached to `UserDefaults` so subsequent launches reconnect silently.
- Info.plist: custom URL scheme `audipad` + `LSApplicationQueriesSchemes` entry for `spotify`.
- Requires Spotify **Premium** + Spotify app installed; Spotify must be playing (or recently played) when first connecting.

### Map
- Persisted user settings across launches: zoom level, center, follow-mode, heading-up toggle, camera pitch.
- Custom compass control with red N-arrow that rotates with the map; tap toggles heading-up vs north-up.
- Heading-up mode uses GPS course (stable above ~5 km/h) — no compass jitter when stationary.
- Map matching: displayed position is projected onto the nearest Digiroad road centerline (edge-based + course-aligned, with raw-GPS fallback off-road).
- Camera offset in heading-up follow: user position sits at 1/3 from the bottom of the screen.
- New tilt buttons (chevron up/down) left of the zoom +/- column. 0–60° in 10° steps.
- Smoother movement: CoreLocation streams every fix (`kCLDistanceFilterNone`, `kCLLocationAccuracyBestForNavigation`, `.automotiveNavigation` activity). Camera tweens linearly over 1 s with `.beginFromCurrentState` so each fix glides into the next.
- Zoom + pitch are now driven by authoritative `desiredAltitude` / `desiredPitch` rather than the in-flight camera values, fixing the bug where +/- presses got overridden by the next location update.
- Pinch gesture captures new zoom on end so location updates respect it.

### User marker
- Replaced the system blue dot with a custom 3D SceneKit Audi-SQ5-shaped car annotation. Q5 SUV proportions, tilted windshield + rear hatch, rounded nose, roof rails, 21" S-line wheels, LED DRL headlight slits, continuous LED taillight bar.
- Real-3D parallax: the model leans into a 3/4 view as the map pitches.
- Marker position is the same map-matched coord the camera follows, so it rides the road centerline.
- Annotation coord + body yaw animate in sync with the map camera (no more hopping between fixes).

### Speed-limit display
- Edge-based + course-aligned snap applied to all three data sources (Digiroad, OSM, VMS), replacing vertex-only nearest-match. Fixes "limit from the parallel highway shows up while driving the local road".
- VMS variable-sign lookup now tiers candidates: same-Digiroad-link first, falls back to closest by raw distance otherwise.

### Speed-camera alerts
- Same-road gate is strict: when the user resolves to a Digiroad link, the camera must also resolve and match. Cameras that don't snap are treated as "different road".
- Sticky alert re-validates same-road on every tick — turning off the road drops the alert immediately instead of riding along for the full 1 km radius.
- User's link resolution is edge-based + course-aligned (matches the road of travel, not whichever vertex is physically nearest).

### Sign rendering
- Speed-limit sign font sized by digit count so 100/110/120 fit inside the red ring at the same legibility as 30/50.
- Road number shields rendered in Finnish road colors: E-routes green, Valtatie 1–39 red, Kantatie 40–99 yellow, Seututie 100–999 white. Supports multi-ref `E18;1` style strings.

### Misc
- Bigger road-name + speed-sign in the bottom-left map panel; "source · X" attribution removed.
- Bigger nav-rail menu icons.
- Map control buttons resized + repositioned for in-car touch targets; active states shown by accent-colored card border instead of icon tint.
