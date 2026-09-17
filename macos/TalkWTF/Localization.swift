import Foundation

/// Translations, loaded from `resources/locales/<lang>/translation.json`,
/// which the Xcode "Copy core resources" phase puts in the app bundle.
///
/// Falls back to English, then to the key itself, so a missing string never
/// blanks the UI.
final class Localization {
    static let shared = Localization()

    private var table: [String: Any] = [:]
    private var fallback: [String: Any] = [:]
    private(set) var language = "en"

    /// Load a locale tag (e.g. `zh-Hans-CN`), resolving it to a bundled folder.
    func load(language tag: String?) {
        let code = Languages.resolve(tag) ?? "en"
        self.language = code
        table = Self.read(code) ?? [:]
        fallback = Self.read("en") ?? [:]
    }

    /// Translate a dotted key, e.g. `settings.general.title`.
    func t(_ key: String, _ args: [String: Any] = [:]) -> String {
        let value = Self.lookup(key, in: table) ?? Self.lookup(key, in: fallback)
        guard var text = value as? String else { return key }
        for (name, replacement) in args {
            text = text.replacingOccurrences(of: "{{\(name)}}", with: "\(replacement)")
        }
        return text
    }

    private static func lookup(_ key: String, in table: [String: Any]) -> Any? {
        var current: Any? = table
        for component in key.split(separator: ".") {
            current = (current as? [String: Any])?[String(component)]
        }
        return current
    }

    private static func read(_ language: String) -> [String: Any]? {
        guard
            let url = Bundle.main.url(
                forResource: "translation",
                withExtension: "json",
                subdirectory: "resources/locales/\(language)"
            ),
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }
}

/// Shorthand for `Localization.shared.t`.
func L(_ key: String, _ args: [String: Any] = [:]) -> String {
    Localization.shared.t(key, args)
}
