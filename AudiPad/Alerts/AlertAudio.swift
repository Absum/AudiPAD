import Foundation
import AVFoundation
import AudioToolbox
import CoreLocation

/// Audible + spoken alerts for safety-relevant events (currently:
/// approaching a speed camera). Configures the shared
/// `AVAudioSession` to duck other audio while we play, and uses
/// `AVSpeechSynthesizer` for the localized voice line. One-shot per
/// camera ID so re-entering the alert radius doesn't re-trigger.
@MainActor
final class AlertAudio: NSObject, ObservableObject {

    /// User-toggleable master switch. Mirrors `@AppStorage` value in
    /// Settings; we read it on every fire so changes take effect
    /// immediately without restarting the app.
    static let enabledDefaultsKey = "audipad.alerts.audioEnabled"

    private let synthesizer = AVSpeechSynthesizer()
    private var lastAnnouncedCameraID: UUID?
    private var configuredSession = false

    func configureAudioSessionIfNeeded() {
        guard !configuredSession else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback,
                mode: .voicePrompt,
                options: [.duckOthers, .mixWithOthers]
            )
            try session.setActive(true, options: [])
            configuredSession = true
        } catch {
            // Not fatal — alerts just won't duck other audio.
        }
    }

    /// Called when the speed-camera monitor publishes a new
    /// `nearestApproaching`. Internally deduplicates by camera ID.
    func onSpeedCameraApproach(_ approach: SpeedCameraMonitor.Approaching?) {
        // Reset dedup state when the approach clears (left the camera's
        // alert radius). Next time we enter someone's radius — including
        // the same camera — we'll announce again.
        guard let approach else {
            lastAnnouncedCameraID = nil
            return
        }
        guard approach.camera.id != lastAnnouncedCameraID else { return }
        lastAnnouncedCameraID = approach.camera.id

        guard isEnabled else { return }
        configureAudioSessionIfNeeded()

        // Short attention-getting chime, then voice line.
        AudioServicesPlaySystemSound(1057) // standard system "Tink"-style tone
        speak(line: announcement(for: approach))
    }

    // MARK: - Internals

    private var isEnabled: Bool {
        // Default to ON if the key has never been set (UserDefaults.bool
        // returns false in that case, so we wrap with `object(forKey:)`).
        if UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
    }

    private func announcement(for approach: SpeedCameraMonitor.Approaching) -> String {
        let limit = approach.camera.speedLimit
        // Finnish first because the driver is Finnish; AVSpeechSynthesisVoice
        // falls back to English at runtime if no FI voice is installed.
        //
        // Distance is intentionally omitted from the spoken line — the
        // banner shows it and the depleting bar tracks it live, while
        // saying e.g. "kahdeksansataa metrin päässä" eats ~2 seconds of
        // air time and dates the announcement the moment it's spoken.
        // When the driver is over the limit at trigger time we lead with
        // "Hidasta," (slow down) and also speak the limit — they need
        // to know what to slow *to*. When already at/under, the short
        // form is enough; the visual banner shows the limit.
        if approach.isOverLimit {
            return "Hidasta, nopeusvalvontakamera edessä. Rajoitus \(limit) kilometriä tunnissa."
        }
        return "Nopeusvalvontakamera edessä."
    }

    private func speak(line: String) {
        let utterance = AVSpeechUtterance(string: line)
        utterance.voice = VoiceConfig.shared
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.postUtteranceDelay = 0.1
        synthesizer.speak(utterance)
    }
}
