import Foundation
import AVFoundation

/// Process-wide voice picker for spoken prompts. Both `AlertAudio`
/// (camera warnings) and `NavVoice` (turn-by-turn) read from here so
/// they always render through the same voice — without this, repeated
/// `AVSpeechSynthesisVoice(language:)` lookups can resolve to
/// different compact/default/enhanced voices for the same language
/// tag, which the driver hears as "two different voices on the same
/// device".
@MainActor
enum VoiceConfig {
    /// The single voice both services use. Computed lazily on first
    /// access and cached for the process lifetime, so every utterance
    /// renders with the same identity.
    static let shared: AVSpeechSynthesisVoice? = pickVoice()

    private static func pickVoice() -> AVSpeechSynthesisVoice? {
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        let region = Locale.current.region?.identifier ?? "US"
        let exactTag = "\(lang)-\(region)"
        let allVoices = AVSpeechSynthesisVoice.speechVoices()

        // Debug: log what we have to work with so we can tell whether
        // the device is missing a Finnish voice altogether (then no
        // matter what we pick, fallback English will speak).
        let installed = allVoices.map { $0.language }.joined(separator: ",")
        print("[AudiPad/Voice] locale=\(exactTag) installed=\(installed)")

        let picked: AVSpeechSynthesisVoice?
        if let v = allVoices.first(where: { $0.language == exactTag }) {
            picked = v
        } else if let v = allVoices.first(where: { $0.language.hasPrefix("\(lang)-") }) {
            // Any voice whose language starts with the same language
            // code (covers fi-FI when the user is in fi-SE, etc.).
            picked = v
        } else if let v = AVSpeechSynthesisVoice(language: lang) {
            // Bare-language lookup as a final attempt before falling
            // back to English.
            picked = v
        } else {
            picked = AVSpeechSynthesisVoice(language: "en-US")
        }

        print("[AudiPad/Voice] picked=\(picked?.language ?? "nil") name=\(picked?.name ?? "?") identifier=\(picked?.identifier ?? "?")")
        return picked
    }
}
