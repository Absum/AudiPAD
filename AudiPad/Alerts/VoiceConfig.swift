import Foundation
import AVFoundation

/// Process-wide voice picker for spoken prompts. Both `AlertAudio`
/// (camera warnings) and `NavVoice` (turn-by-turn) read from here so
/// they always render through the same voice — without this, repeated
/// `AVSpeechSynthesisVoice(language:)` lookups can resolve to
/// different compact / enhanced / premium variants for the same
/// language tag, which the driver hears as "two different voices on
/// the same device".
///
/// On top of that, we explicitly prefer higher quality:
/// `.premium > .enhanced > .default` after the language filter.
/// Without that sort, `first(where:)` returns whatever iOS happens
/// to hand back first — typically the lowest-quality compact voice
/// even when an enhanced/premium variant is installed.
@MainActor
enum VoiceConfig {
    /// The single voice both services use. Computed lazily on first
    /// access and cached for the process lifetime, so every utterance
    /// renders with the same identity.
    static let shared: AVSpeechSynthesisVoice? = pickVoice()

    /// Friendly metadata for the Settings UI — display name (e.g.
    /// "Satu"), language tag, and quality tier so the user can see
    /// at a glance whether they're on the good voice.
    static var pickedVoiceName: String? { shared?.name }
    static var pickedVoiceLanguage: String? { shared?.language }
    static var pickedVoiceQuality: AVSpeechSynthesisVoiceQuality? { shared?.quality }

    /// Human-readable quality label for the Settings pill.
    static var pickedVoiceQualityLabel: String {
        switch pickedVoiceQuality {
        case .premium:  return "Premium"
        case .enhanced: return "Enhanced"
        case .default:  return "Default"
        case .none:     return "None"
        case .some:     return "Unknown"
        }
    }

    /// `true` when the picked voice is the lowest tier — the
    /// Settings UI surfaces an install hint in this case so the user
    /// knows they can fix it via iOS Settings.
    static var pickedVoiceIsDefaultQuality: Bool {
        pickedVoiceQuality == .default
    }

    private static func pickVoice() -> AVSpeechSynthesisVoice? {
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        let region = Locale.current.region?.identifier ?? "US"
        let exactTag = "\(lang)-\(region)"
        let allVoices = AVSpeechSynthesisVoice.speechVoices()

        // Debug log — useful for understanding why the picker landed
        // where it did. Lists each candidate's quality + identifier.
        let installed = allVoices
            .filter { $0.language.hasPrefix("\(lang)-") || $0.language == lang }
            .map { "\($0.name)/\($0.language)/\(qualityName($0.quality))" }
            .joined(separator: ", ")
        print("[AudiPad/Voice] locale=\(exactTag) lang-matched=[\(installed)]")

        let exact = allVoices.filter { $0.language == exactTag }
        let prefixed = allVoices.filter { $0.language.hasPrefix("\(lang)-") }

        // Picker: best quality wins. Use exact-tag matches first;
        // fall back to any same-language variant; fall back to a
        // bare-language lookup; final fallback en-US.
        let picked = bestByQuality(from: exact)
            ?? bestByQuality(from: prefixed)
            ?? AVSpeechSynthesisVoice(language: lang)
            ?? AVSpeechSynthesisVoice(language: "en-US")

        print("[AudiPad/Voice] picked=\(picked?.name ?? "?") lang=\(picked?.language ?? "?") quality=\(qualityName(picked?.quality))")
        return picked
    }

    /// Highest-quality voice from a set: premium > enhanced > default.
    private static func bestByQuality(from voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        voices.max { qualityRank($0.quality) < qualityRank($1.quality) }
    }

    private static func qualityRank(_ q: AVSpeechSynthesisVoiceQuality) -> Int {
        switch q {
        case .premium:  return 3
        case .enhanced: return 2
        case .default:  return 1
        @unknown default: return 0
        }
    }

    private static func qualityName(_ q: AVSpeechSynthesisVoiceQuality?) -> String {
        guard let q else { return "nil" }
        switch q {
        case .premium:    return "premium"
        case .enhanced:   return "enhanced"
        case .default:    return "default"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Voice test (Settings → Voice → Test)

    /// One-shot synthesiser kept on the type so a quick test press
    /// from Settings doesn't fight with NavVoice or AlertAudio for
    /// shared synthesiser state.
    private static let testSynthesizer = AVSpeechSynthesizer()

    /// Speak a sample line through the picked voice so the user can
    /// hear exactly what the road would sound like. Uses both a
    /// navigation-style and a camera-alert-style phrase so the test
    /// exercises the actual vocabulary the user will hear while
    /// driving.
    static func speakTestPhrase() {
        guard let voice = shared else { return }
        let text: String
        // Finnish if the picked voice is Finnish, English otherwise
        // — so a default-locale device doesn't speak Finnish prompts
        // through an English voice (would mispronounce badly).
        if voice.language.hasPrefix("fi") {
            text = "Kahdensadan metrin päästä käänny oikealle. Edessä nopeusvalvontakamera, kahdeksankymmentä kilometriä tunnissa."
        } else {
            text = "In two hundred meters, turn right. Speed camera ahead, eighty kilometers per hour."
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        // Stop any in-flight test so repeated taps don't queue up.
        if testSynthesizer.isSpeaking {
            testSynthesizer.stopSpeaking(at: .immediate)
        }
        testSynthesizer.speak(utterance)
    }
}
