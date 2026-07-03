import Foundation

/// A spoken language the user can force for transcription.
///
/// `code` is the Whisper language code (e.g. "en", "de", "el"). Forcing a language
/// is only meaningful for multilingual Whisper models — see
/// `TranscriptionModel.supportsLanguageSelection`.
struct TranscriptionLanguage: Identifiable, Hashable {
    /// Whisper language code, e.g. "en".
    let code: String
    /// English display name, e.g. "German".
    let name: String
    /// Native display name, e.g. "Deutsch". Helps non-English users find their language.
    let nativeName: String

    var id: String { code }

    /// Label for the picker, showing the native name when it differs from the English one.
    var pickerLabel: String {
        name == nativeName ? name : "\(name) — \(nativeName)"
    }
}

/// UserDefaults-backed preference for the forced transcription language.
/// An empty stored string means "auto-detect" (the default).
enum TranscriptionLanguagePreference {
    static let key = "transcriptionLanguageCode"

    /// The selected language code, or nil when set to auto-detect.
    static var savedCode: String? {
        let raw = (UserDefaults.standard.string(forKey: key) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    static func setSavedCode(_ code: String?) {
        UserDefaults.standard.set(code ?? "", forKey: key)
    }

    /// English display name for a code (used in prompts and UI); falls back to the code.
    static func name(forCode code: String) -> String {
        supported.first(where: { $0.code == code })?.name ?? code
    }

    /// Curated set of languages supported by multilingual Whisper models, sorted by
    /// English name. Broad enough that users can pick the specific languages they speak.
    static let supported: [TranscriptionLanguage] = [
        TranscriptionLanguage(code: "ar", name: "Arabic", nativeName: "العربية"),
        TranscriptionLanguage(code: "bg", name: "Bulgarian", nativeName: "Български"),
        TranscriptionLanguage(code: "ca", name: "Catalan", nativeName: "Català"),
        TranscriptionLanguage(code: "zh", name: "Chinese", nativeName: "中文"),
        TranscriptionLanguage(code: "hr", name: "Croatian", nativeName: "Hrvatski"),
        TranscriptionLanguage(code: "cs", name: "Czech", nativeName: "Čeština"),
        TranscriptionLanguage(code: "da", name: "Danish", nativeName: "Dansk"),
        TranscriptionLanguage(code: "nl", name: "Dutch", nativeName: "Nederlands"),
        TranscriptionLanguage(code: "en", name: "English", nativeName: "English"),
        TranscriptionLanguage(code: "fi", name: "Finnish", nativeName: "Suomi"),
        TranscriptionLanguage(code: "fr", name: "French", nativeName: "Français"),
        TranscriptionLanguage(code: "de", name: "German", nativeName: "Deutsch"),
        TranscriptionLanguage(code: "el", name: "Greek", nativeName: "Ελληνικά"),
        TranscriptionLanguage(code: "he", name: "Hebrew", nativeName: "עברית"),
        TranscriptionLanguage(code: "hi", name: "Hindi", nativeName: "हिन्दी"),
        TranscriptionLanguage(code: "hu", name: "Hungarian", nativeName: "Magyar"),
        TranscriptionLanguage(code: "id", name: "Indonesian", nativeName: "Bahasa Indonesia"),
        TranscriptionLanguage(code: "it", name: "Italian", nativeName: "Italiano"),
        TranscriptionLanguage(code: "ja", name: "Japanese", nativeName: "日本語"),
        TranscriptionLanguage(code: "ko", name: "Korean", nativeName: "한국어"),
        TranscriptionLanguage(code: "no", name: "Norwegian", nativeName: "Norsk"),
        TranscriptionLanguage(code: "fa", name: "Persian", nativeName: "فارسی"),
        TranscriptionLanguage(code: "pl", name: "Polish", nativeName: "Polski"),
        TranscriptionLanguage(code: "pt", name: "Portuguese", nativeName: "Português"),
        TranscriptionLanguage(code: "ro", name: "Romanian", nativeName: "Română"),
        TranscriptionLanguage(code: "ru", name: "Russian", nativeName: "Русский"),
        TranscriptionLanguage(code: "sr", name: "Serbian", nativeName: "Српски"),
        TranscriptionLanguage(code: "sk", name: "Slovak", nativeName: "Slovenčina"),
        TranscriptionLanguage(code: "es", name: "Spanish", nativeName: "Español"),
        TranscriptionLanguage(code: "sv", name: "Swedish", nativeName: "Svenska"),
        TranscriptionLanguage(code: "th", name: "Thai", nativeName: "ไทย"),
        TranscriptionLanguage(code: "tr", name: "Turkish", nativeName: "Türkçe"),
        TranscriptionLanguage(code: "uk", name: "Ukrainian", nativeName: "Українська"),
        TranscriptionLanguage(code: "vi", name: "Vietnamese", nativeName: "Tiếng Việt"),
    ]
}
