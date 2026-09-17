import Foundation

/// One selectable UI language. Keep in sync with `resources/locales/`.
struct Language: Identifiable, Hashable {
    let code: String
    let name: String
    let nativeName: String
    let rtl: Bool

    var id: String { code }
}

/// Supported languages, in the same priority order as the Tauri app.
enum Languages {
    static let all: [Language] = [
    Language(code: "en", name: "English", nativeName: "English", rtl: false),
    Language(code: "zh", name: "Simplified Chinese", nativeName: "简体中文", rtl: false),
    Language(code: "zh-TW", name: "Traditional Chinese", nativeName: "繁體中文", rtl: false),
    Language(code: "es", name: "Spanish", nativeName: "Español", rtl: false),
    Language(code: "fr", name: "French", nativeName: "Français", rtl: false),
    Language(code: "de", name: "German", nativeName: "Deutsch", rtl: false),
    Language(code: "ja", name: "Japanese", nativeName: "日本語", rtl: false),
    Language(code: "ko", name: "Korean", nativeName: "한국어", rtl: false),
    Language(code: "vi", name: "Vietnamese", nativeName: "Tiếng Việt", rtl: false),
    Language(code: "pl", name: "Polish", nativeName: "Polski", rtl: false),
    Language(code: "it", name: "Italian", nativeName: "Italiano", rtl: false),
    Language(code: "ru", name: "Russian", nativeName: "Русский", rtl: false),
    Language(code: "uk", name: "Ukrainian", nativeName: "Українська", rtl: false),
    Language(code: "pt", name: "Portuguese", nativeName: "Português", rtl: false),
    Language(code: "cs", name: "Czech", nativeName: "Čeština", rtl: false),
    Language(code: "tr", name: "Turkish", nativeName: "Türkçe", rtl: false),
    Language(code: "ar", name: "Arabic", nativeName: "العربية", rtl: true),
    Language(code: "he", name: "Hebrew", nativeName: "עברית", rtl: true),
    Language(code: "sv", name: "Swedish", nativeName: "Svenska", rtl: false),
    Language(code: "bg", name: "Bulgarian", nativeName: "Български", rtl: false),
    Language(code: "nl", name: "Dutch", nativeName: "Nederlands", rtl: false),
    Language(code: "ne", name: "Nepali", nativeName: "नेपाली", rtl: false),
    Language(code: "hi", name: "Hindi", nativeName: "हिन्दी", rtl: false),
    Language(code: "da", name: "Danish", nativeName: "Dansk", rtl: false),
    Language(code: "ca", name: "Catalan", nativeName: "Català", rtl: false),
    Language(code: "id", name: "Indonesian", nativeName: "Bahasa Indonesia", rtl: false),
    ]

    /// Resolve a stored/system locale tag to a bundled language code, following
    /// the same rules as the Tauri app (exact → language → zh-Hant handling).
    static func resolve(_ tag: String?) -> String? {
        guard let tag else { return nil }
        let normalized = tag.lowercased().replacingOccurrences(of: "_", with: "-")
        let subtags = normalized.split(separator: "-").map(String.init)
        guard let language = subtags.first else { return nil }
        let isHant = subtags.contains("hant")
        let isHans = subtags.contains("hans")
        let isTraditionalRegion = ["tw", "hk", "mo"].contains { subtags.contains($0) }

        if let exact = all.first(where: { $0.code.lowercased() == normalized }) {
            return exact.code
        }
        var fallback = language
        if language == "zh", isHant || (!isHans && isTraditionalRegion) {
            fallback = "zh-tw"
        } else if language == "yue" {
            fallback = isHans ? "zh" : "zh-tw"
        }
        return all.first { $0.code.lowercased() == fallback }?.code
    }

    static func display(_ code: String) -> String {
        guard let language = all.first(where: { $0.code == code }) else { return code }
        return language.nativeName
    }
}
