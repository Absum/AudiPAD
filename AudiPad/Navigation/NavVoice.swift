import Foundation
import AVFoundation
import CoreLocation

/// Speaks turn-by-turn maneuver prompts in response to `RouteFollower`
/// progress updates. Two prompts per step:
///
///   • **Prep** — fires once when distance crosses below `prepDistanceMeters`
///     ("In 300 m, turn right onto Mannerheimintie")
///   • **Final** — fires once when distance crosses below `finalDistanceMeters`
///     (just the bare instruction, e.g. "Turn right")
///
/// State is keyed by step index so changing steps resets the dedup
/// flags. Voice language follows `Locale.current` so it matches the
/// language `MKRoute.Step.instructions` is already localised in.
@MainActor
final class NavVoice: NSObject, ObservableObject {

    static let enabledDefaultsKey = "audipad.nav.voiceEnabled"

    /// Approximate distances at which each prompt fires. Real
    /// navigators tune this per road class (e.g. 1 km warning on
    /// highways); we use static values for v1.
    private let prepDistanceMeters: CLLocationDistance = 300
    private let finalDistanceMeters: CLLocationDistance = 50

    private let synthesizer = AVSpeechSynthesizer()
    private var configuredSession = false

    /// Last step index we processed. Whenever this changes, the prep
    /// and final dedup flags reset so the next step gets its own
    /// pair of prompts.
    private var lastStepIndex: Int = -1
    private var prepFiredForCurrentStep = false
    private var finalFiredForCurrentStep = false

    func configureAudioSessionIfNeeded() {
        guard !configuredSession else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .voicePrompt,
                                    options: [.duckOthers, .mixWithOthers])
            try session.setActive(true, options: [])
            configuredSession = true
        } catch {
            // Not fatal — prompts just won't duck other audio.
        }
    }

    /// Called whenever `RouteFollower.progress` publishes. A nil
    /// progress means no active route — reset state so the next route
    /// starts clean.
    func update(with progress: RouteFollower.Progress?) {
        guard let progress else {
            lastStepIndex = -1
            prepFiredForCurrentStep = false
            finalFiredForCurrentStep = false
            return
        }
        guard isEnabled else { return }

        // Step boundary: reset dedup flags so the new step's prompts
        // can fire.
        if progress.currentStepIndex != lastStepIndex {
            lastStepIndex = progress.currentStepIndex
            prepFiredForCurrentStep = false
            finalFiredForCurrentStep = false
        }

        let dist = progress.distanceToManeuverMeters

        if !prepFiredForCurrentStep
            && dist <= prepDistanceMeters
            && dist > finalDistanceMeters {
            prepFiredForCurrentStep = true
            configureAudioSessionIfNeeded()
            speak(prepLine(for: progress))
        }

        if !finalFiredForCurrentStep && dist <= finalDistanceMeters {
            finalFiredForCurrentStep = true
            configureAudioSessionIfNeeded()
            speak(finalLine(for: progress))
        }
    }

    // MARK: - Phrasing

    private func prepLine(for progress: RouteFollower.Progress) -> String {
        // Round to a nice spoken number (50 m granularity below 1 km).
        let m = Int((progress.distanceToManeuverMeters / 50).rounded()) * 50
        if isFinnish {
            return "\(m) metrin päästä, \(lowerInitial(progress.currentInstruction))"
        }
        return "In \(m) meters, \(lowerInitial(progress.currentInstruction))"
    }

    private func finalLine(for progress: RouteFollower.Progress) -> String {
        progress.currentInstruction
    }

    private var isFinnish: Bool {
        Locale.current.language.languageCode?.identifier == "fi"
    }

    /// Lowercase the first letter when chaining a sentence onto a
    /// prefix ("In 200 m, turn right" reads better than "In 200 m,
    /// Turn right").
    private func lowerInitial(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.lowercased() + s.dropFirst()
    }

    /// One-shot announcement for the off-route reroute path. Spoken
    /// in the active locale so the driver knows the silent moment
    /// before the new route lands isn't a glitch.
    func announceReroute() {
        guard isEnabled else { return }
        configureAudioSessionIfNeeded()
        speak(isFinnish ? "Lasketaan uutta reittiä." : "Rerouting.")
    }

    // MARK: - Speech

    private func speak(_ line: String) {
        let utterance = AVSpeechUtterance(string: line)
        utterance.voice = VoiceConfig.shared
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 1.0
        utterance.postUtteranceDelay = 0.1
        synthesizer.speak(utterance)
    }

    private var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
    }
}
