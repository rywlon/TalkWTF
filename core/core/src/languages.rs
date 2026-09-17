//! Speech-recognition languages.
//!
//! Ported from the Tauri frontend's `src/lib/constants/languages.ts` so the
//! picker and the engine agree on one table. `effective_language` in
//! [`crate::model`] coerces a chosen intent to what the loaded model supports.

use serde::Serialize;

/// One entry in the transcription-language picker.
#[derive(Debug, Clone, Serialize, specta::Type)]
pub struct RecognitionLanguage {
    pub value: String,
    pub label: String,
}

/// The recognition intent for bare Chinese. All three Chinese codes recognize
/// identically; only the two script variants are offered in the picker.
pub const CHINESE_LANGUAGE_CODE: &str = "zh";

/// Every language the engine can be asked for, including `auto`.
const LANGUAGES: &[(&str, &str)] = &[
    ("auto", "Auto Detect"),
    ("en", "English"),
    ("zh", "Chinese"),
    ("zh-Hans", "Chinese (Simplified)"),
    ("zh-Hant", "Chinese (Traditional)"),
    ("yue", "Cantonese"),
    ("de", "German"),
    ("es", "Spanish"),
    ("ru", "Russian"),
    ("ko", "Korean"),
    ("fr", "French"),
    ("ja", "Japanese"),
    ("pt", "Portuguese"),
    ("tr", "Turkish"),
    ("pl", "Polish"),
    ("ca", "Catalan"),
    ("nl", "Dutch"),
    ("ar", "Arabic"),
    ("sv", "Swedish"),
    ("it", "Italian"),
    ("id", "Indonesian"),
    ("hi", "Hindi"),
    ("fi", "Finnish"),
    ("vi", "Vietnamese"),
    ("he", "Hebrew"),
    ("uk", "Ukrainian"),
    ("el", "Greek"),
    ("ms", "Malay"),
    ("cs", "Czech"),
    ("ro", "Romanian"),
    ("da", "Danish"),
    ("hu", "Hungarian"),
    ("ta", "Tamil"),
    ("no", "Norwegian"),
    ("th", "Thai"),
    ("ur", "Urdu"),
    ("hr", "Croatian"),
    ("bg", "Bulgarian"),
    ("lt", "Lithuanian"),
    ("la", "Latin"),
    ("mi", "Maori"),
    ("ml", "Malayalam"),
    ("cy", "Welsh"),
    ("sk", "Slovak"),
    ("te", "Telugu"),
    ("fa", "Persian"),
    ("lv", "Latvian"),
    ("bn", "Bengali"),
    ("sr", "Serbian"),
    ("az", "Azerbaijani"),
    ("sl", "Slovenian"),
    ("kn", "Kannada"),
    ("et", "Estonian"),
    ("mk", "Macedonian"),
    ("br", "Breton"),
    ("eu", "Basque"),
    ("is", "Icelandic"),
    ("ga", "Irish"),
    ("hy", "Armenian"),
    ("ne", "Nepali"),
    ("mn", "Mongolian"),
    ("bs", "Bosnian"),
    ("kk", "Kazakh"),
    ("sq", "Albanian"),
    ("sw", "Swahili"),
    ("gl", "Galician"),
    ("mr", "Marathi"),
    ("pa", "Punjabi"),
    ("si", "Sinhala"),
    ("km", "Khmer"),
    ("sn", "Shona"),
    ("yo", "Yoruba"),
    ("so", "Somali"),
    ("af", "Afrikaans"),
    ("oc", "Occitan"),
    ("ka", "Georgian"),
    ("be", "Belarusian"),
    ("tg", "Tajik"),
    ("sd", "Sindhi"),
    ("gu", "Gujarati"),
    ("am", "Amharic"),
    ("yi", "Yiddish"),
    ("lo", "Lao"),
    ("uz", "Uzbek"),
    ("fo", "Faroese"),
    ("ht", "Haitian Creole"),
    ("ps", "Pashto"),
    ("tk", "Turkmen"),
    ("nn", "Nynorsk"),
    ("mt", "Maltese"),
    ("sa", "Sanskrit"),
    ("lb", "Luxembourgish"),
    ("my", "Myanmar"),
    ("bo", "Tibetan"),
    ("tl", "Filipino (Tagalog)"),
    ("mg", "Malagasy"),
    ("as", "Assamese"),
    ("tt", "Tatar"),
    ("haw", "Hawaiian"),
    ("ln", "Lingala"),
    ("ha", "Hausa"),
    ("ba", "Bashkir"),
    ("jw", "Javanese"),
    ("su", "Sundanese"),
];

/// Script intents that are valid *outputs* but not model capabilities.
const CHINESE_OUTPUT_INTENTS: &[&str] = &["zh-Hans", "zh-Hant"];

/// Collapse a language tag to the canonical recognition intent the UI exposes.
/// Region and script subtags are dropped (`en-US` → `en`, `zh-Hant` → `zh`).
///
/// Delegates to [`crate::model::canonical_language_code`] so the picker and the
/// engine cannot disagree about what a code means.
pub fn recognition_language(language_code: &str) -> String {
    crate::model::canonical_language_code(language_code).to_string()
}

/// Whether `language_code` is covered by a model advertising `supported`.
pub fn supports_language_code(supported: &[String], language_code: &str) -> bool {
    let wanted = recognition_language(language_code);
    supported
        .iter()
        .any(|code| recognition_language(code) == wanted)
}

/// The label for a code, or `None` when it is not in the table. Falls back to
/// the canonical intent, so `en-US` and `nb` resolve.
pub fn language_label(language_code: &str) -> Option<&'static str> {
    let canonical = recognition_language(language_code);
    LANGUAGES
        .iter()
        .find(|(value, _)| *value == language_code || *value == canonical)
        .map(|(_, label)| *label)
}

/// The picker entries: every language except the bare `zh` recognition code,
/// which is indistinguishable from the two script variants.
pub fn selectable_languages() -> Vec<RecognitionLanguage> {
    LANGUAGES
        .iter()
        .filter(|(value, _)| *value != CHINESE_LANGUAGE_CODE)
        .map(|(value, label)| RecognitionLanguage {
            value: (*value).to_string(),
            label: (*label).to_string(),
        })
        .collect()
}

/// Languages a model can actually transcribe (used to gate the picker).
pub fn capability_languages() -> Vec<RecognitionLanguage> {
    LANGUAGES
        .iter()
        .filter(|(value, _)| *value != "auto" && !CHINESE_OUTPUT_INTENTS.contains(value))
        .map(|(value, label)| RecognitionLanguage {
            value: (*value).to_string(),
            label: (*label).to_string(),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aliases_collapse_to_the_ui_intent() {
        assert_eq!(recognition_language("en-US"), "en");
        assert_eq!(recognition_language("zh-Hant"), "zh");
        assert_eq!(recognition_language("nb"), "no");
        assert_eq!(recognition_language("fil"), "tl");
        assert_eq!(recognition_language("nn"), "nn");
    }

    #[test]
    fn matching_uses_the_canonical_intent() {
        let supported = vec!["en".to_string(), "no".to_string()];
        assert!(supports_language_code(&supported, "en-US"));
        assert!(supports_language_code(&supported, "nb"));
        assert!(!supports_language_code(&supported, "ja"));
    }

    #[test]
    fn the_picker_hides_bare_chinese_but_keeps_the_script_variants() {
        let values: Vec<String> = selectable_languages()
            .into_iter()
            .map(|language| language.value)
            .collect();
        assert!(!values.contains(&CHINESE_LANGUAGE_CODE.to_string()));
        assert!(values.contains(&"zh-Hans".to_string()));
        assert!(values.contains(&"zh-Hant".to_string()));
        assert!(values.contains(&"auto".to_string()));
    }

    #[test]
    fn labels_resolve_through_aliases() {
        assert_eq!(language_label("en-US"), Some("English"));
        assert_eq!(language_label("nb"), Some("Norwegian"));
        assert_eq!(language_label("nope"), None);
    }
}
