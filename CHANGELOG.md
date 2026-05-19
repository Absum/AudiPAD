# Changelog

All notable changes to AudiPad are recorded here. Style: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
The build number on each release heading is the `CFBundleVersion` shipped in that build.

## Unreleased

## 0.2.0 — 2026-05-19 (build 3)

### Navigation
- Live turn-by-turn step tracking via `RouteFollower`: snaps the GPS fix onto the active route polyline, advances `currentStepIndex` as the user passes each maneuver waypoint, and publishes a `Progress` struct with current/next instruction, distance to maneuver, distance remaining, ETA, snapped coordinate, and lateral deviation.
- New `ManeuverBanner` at the top of the Map tab during active nav: SF-Symbol icon picked from the instruction text (EN + FI keyword matching since `MKRoute.Step` doesn't expose a structured maneuver enum), bold distance to next maneuver, instruction text, ETA in minutes + wall-clock arrival time (`5 min · 19:24`), total distance remaining, and a stop-X.
- `NavVoice` speaks each upcoming step at ~300 m (prep: "In X meters, …") and ~50 m (final: bare instruction), de-duplicated per step. Same audio session config as `AlertAudio` so it ducks Spotify cleanly. "Lasketaan uutta reittiä." / "Rerouting." cue on auto re-route.
- Re-route on deviation: 40 m lateral × 5 s sustained → `MapViewModel.reroute(from:)` recomputes against the stored destination without re-doing search. New routes preserve the in-flight `routeStarted` flag so the driver isn't bounced back to confirmation mid-drive.
- Pre-start confirmation card: when a route is calculated, the bottom shows a `RouteConfirmationCard` (destination · distance · ETA · X · accent "Start" capsule). Maneuver banner stays suppressed until Start is tapped.
- Stacked nav header: maneuver banner → speed-camera warning (when approaching) → now-playing strip. The camera banner is rendered inline inside MapTabView during nav so it slots between the maneuver banner and the strip; ContentView's overlay skips the map tab to avoid double-rendering.
- Route-aware Digiroad corridor prefetch: `RoadSpeedLimitService.setRoute(_:)` chops the polyline into ≤5 km tiles padded by 200 m and fetches each via WFS in parallel (`withThrowingTaskGroup`). Lets the camera same-road gate resolve cameras anywhere along the route, not just within the ~2 km user bbox. Alert radius dropped 1000 m → 800 m for earlier warning. Fingerprint of every route vertex used for dedup so alternate paths between the same endpoints refetch correctly; failed-tile aborts roll back the fingerprint so a retry can re-attempt.
- Map camera heading persisted across tab switches — parked + heading-up no longer resets to north when you visit another tab.

### Speedometer & boost gauge (Map tab)
- New stylised 270° dial speedometer at the bottom-left of the Map. White under-limit fill + red over-limit overshoot, accent capsule tick at the current road's speed limit position, white centre digits (no jitter — monospaced rounded font). Reads from the global `SpeedSource` preference so it agrees with the TopBar pill.
- Vertical bar boost gauge next to the speedometer with an accent arrow indicator tracking the top of the fill. Same `0–2.5 bar absolute` scale as Home's `SQ5Gauge`. White fill 0 → 2.0 bar (redline), red overshoot above 2.0. Same card chrome as the speedometer.
- Both gauges hide when their dedicated toggle in Settings → Navigator is off.

### Settings
- New "Navigator" section above Configuration. Show/hide toggles for the speedometer and boost gauge cards, persisted via `@AppStorage`. Section is designed as the home for future nav-specific prefs (route preferences, voice, lane guidance, …).
- App version row now reads `CFBundleShortVersionString (CFBundleVersion)` straight from Info.plist instead of a hardcoded string.

### Speed-camera alerts
- Banner now drops as soon as the camera is behind the user (bearing-to-camera > 90° off course). Was: stayed visible the full 1 km until distance exceeded the radius — "alert flashed for 4 m" complaint.
- Depleting distance progress bar inside the banner (full at the alert radius, empty at the camera).
- Over-limit state: red accent + "SLOW DOWN — CAMERA AHEAD" headline + one heavy haptic on the under-to-over transition.
- Spoken alert shortened to `"Nopeusvalvontakamera edessä."` when under the limit. When the driver is over: `"Hidasta, nopeusvalvontakamera edessä. Rajoitus N kilometriä tunnissa."`
- Digiroad bbox bumped (4 km × 4 km around the user, was ~1 km × 1 km) so an 800 m-ahead camera is reliably inside the cached segments — same-road gate now passes well before the user is on top of the pole.
- Outer-domain error detection broadened so the auto-retry loop correctly stops when the Spotify-app-style `Connection refused` chain bubbles up.

### Spotify
- **Replaced the iOS App Remote SDK path with a Web API client.** Was: SDK talks to the *local* Spotify app's IPC socket, which dies the moment playback transfers to another device. Now: 3-second polling against `GET /v1/me/player` (any device, any source) + `PUT /v1/me/player/play|pause` + `POST /v1/me/player/next|previous` for transport. Driver keeps the iPad as a display/controller even when the phone is the source.
- Auth swapped to `SPTSessionManager` so we can request the right scopes: `app-remote-control`, `user-read-playback-state`, `user-modify-playback-state`, `user-read-currently-playing`. One-tap connect; no more "tap twice to wake Spotify" dance.
- Optimistic UI flip on play/pause so the icon updates instantly even before the HTTP RTT lands.
- Album-art caching: only refetches the image when the track ID changes, not on every 3-second poll.

### Voice
- Shared `VoiceConfig.shared` picks one voice per app launch and both `AlertAudio` (camera) and `NavVoice` (turn-by-turn) use it. Fixes "two different voices on the same device" caused by repeated `AVSpeechSynthesisVoice(language:)` lookups resolving to different compact/default/enhanced voices.
- Voice selection follows `Locale.current` (`lang-region` → `lang` → `en-US`) so it matches the language `MKRoute.Step.instructions` is already localised in.
- Added `CFBundleLocalizations: [en, fi]` to Info.plist so MKDirections returns Finnish instructions on a Finnish-locale iPad.

### Map UI
- Search bar collapses to a 68×68 magnifying-glass button when not active (matching the map control button size + corner radius). Tapping expands the full search field in place; suggestions/recents below. Closes on submit, suggestion pick, or X-when-empty.
- Persisted user settings across launches: zoom level, center, follow-mode, heading-up toggle, camera pitch, **heading** (new).
- Custom compass control with red N-arrow that rotates with the map; tap toggles heading-up vs north-up.
- Heading-up mode uses GPS course (stable above ~5 km/h) — no compass jitter when stationary.
- Map matching: displayed position is projected onto the nearest Digiroad road centerline (edge-based + course-aligned, with raw-GPS fallback off-road).
- Camera offset in heading-up follow: user position sits at 1/3 from the bottom of the screen.
- Tilt buttons (chevron up/down) sit in a 2-column grid with the zoom +/-, compass, and follow controls. 0–60° in 10° steps.
- Smoother movement: CoreLocation streams every fix (`kCLDistanceFilterNone`, `kCLLocationAccuracyBestForNavigation`, `.automotiveNavigation` activity). Camera tweens linearly over 1 s with `.beginFromCurrentState` so each fix glides into the next.
- Zoom + pitch are driven by authoritative `desiredAltitude` / `desiredPitch` rather than the in-flight camera values, fixing the bug where +/- presses got overridden by the next location update.
- Pinch gesture captures new zoom on end so location updates respect it.
- `LocationService.augment(...)` synthesizes `speed` + `course` from consecutive coordinate deltas when CoreLocation reports `-1` (e.g. `xcrun simctl location set` injection). Lets simulator-driven test routes exercise the heading-up, speedometer, and camera-facing gate.

### User marker
- Replaced the procedural SceneKit car with a USDZ Audi SQ5 model (11.5 MB). Auto-scaled to ~5.6 m (1.2× real-world length for readability), hood-forward orientation correction (the model loads +X-forward but the gauge camera expects +Z-forward).
- Window materials tinted to privacy-glass dark gray (was light gray, read as plastic against the black body).
- Procedural model retained as a fallback if the USDZ ever fails to load.
- Real-3D parallax: the model leans into a 3/4 view as the map pitches.
- Marker position is the same map-matched coord the camera follows, so it rides the road centerline.
- Annotation coord + body yaw animate in sync with the map camera (no more hopping between fixes).

### Speed-limit display
- Edge-based + course-aligned snap applied to all three data sources (Digiroad, OSM, VMS), replacing vertex-only nearest-match. Fixes "limit from the parallel highway shows up while driving the local road".
- VMS variable-sign lookup now tiers candidates: same-Digiroad-link first, falls back to closest by raw distance otherwise.

### Sign rendering
- Speed-limit sign font sized by digit count so 100/110/120 fit inside the red ring at the same legibility as 30/50.
- Road number shields rendered in Finnish road colors: E-routes green, Valtatie 1–39 red, Kantatie 40–99 yellow, Seututie 100–999 white. Supports multi-ref `E18;1` style strings.

### Misc
- Bigger road-name + speed-sign in the bottom-left map panel; "source · X" attribution removed.
- Bigger nav-rail menu icons.
- Map control buttons resized + repositioned for in-car touch targets; active states shown by accent-colored card border instead of icon tint.
- New `AudiPad/Navigation/` source group: `RouteFollower.swift`, `NavVoice.swift`, `NavigatorSettings.swift`.
- New `AudiPad/Alerts/VoiceConfig.swift` shared between alerts and nav.
