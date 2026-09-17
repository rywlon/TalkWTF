//! Dictionary CRUD plus JSON import/export.
//!
//! The commands take a path instead of opening a dialog themselves: the frontend
//! shows the native dialog (the JS API is promise-based, so nothing blocks the
//! main thread) and hands the chosen path down. That also means the file IO
//! happens in Rust, so the webview needs no filesystem write permission.

use crate::managers::dictionary::{
    CorrectionRule, DictionaryStore, DictionaryWord, RULE_PATTERN_MAX_CHARS,
    RULE_REPLACEMENT_MAX_CHARS, WORD_MAX_CHARS,
};
use serde::{Deserialize, Serialize};
use specta::Type;
use std::sync::Arc;
use tauri::{AppHandle, Manager, State};
use tauri_specta::Event;

pub const DICTIONARY_FORMAT: &str = "talkwtf_dictionary";
pub const DICTIONARY_FORMAT_VERSION: u32 = 1;

/// Emitted when the dictionary changed behind the settings page's back, so an
/// open page can refresh. The undo runs from the dictation overlay, which the
/// page cannot see; without this it keeps showing the row that was just removed.
#[derive(Debug, Clone, Serialize, Deserialize, Type, tauri_specta::Event)]
pub struct DictionaryChanged {}

/// Everything the dictionary settings page renders.
#[derive(Debug, Clone, Serialize, Deserialize, Type)]
pub struct DictionaryListing {
    pub words: Vec<DictionaryWord>,
    pub rules: Vec<CorrectionRule>,
}

/// What an import did, so the UI can report it instead of silently succeeding.
#[derive(Debug, Clone, Serialize, Deserialize, Type)]
pub struct DictionaryImportReport {
    pub accepted: u32,
    pub skipped_duplicates: u32,
    pub skipped_invalid: u32,
}

/// On-disk shape. `words` accepts plain strings; the import path also tolerates
/// `{ "word": ... }` objects so files exported by other tools still load.
#[derive(Debug, Serialize, Deserialize)]
struct DictionaryFile {
    format: Option<String>,
    version: Option<u32>,
    #[serde(default)]
    words: Vec<serde_json::Value>,
    #[serde(
        default,
        rename = "correctionRules",
        alias = "correction_rules",
        alias = "corrections"
    )]
    correction_rules: Vec<RuleFileEntry>,
}

#[derive(Debug, Serialize, Deserialize)]
struct RuleFileEntry {
    #[serde(alias = "wrong_phrase", alias = "wrongPhrase")]
    pattern: String,
    #[serde(
        alias = "corrected_phrase",
        alias = "correctedPhrase",
        alias = "correct_phrase"
    )]
    replacement: String,
    #[serde(default = "default_enabled")]
    enabled: bool,
}

fn default_enabled() -> bool {
    true
}

fn word_from_value(value: &serde_json::Value) -> Option<String> {
    match value {
        serde_json::Value::String(word) => Some(word.clone()),
        serde_json::Value::Object(map) => map
            .get("word")
            .and_then(|word| word.as_str())
            .map(str::to_string),
        _ => None,
    }
}

/// Merge a parsed file into the store. Duplicates and invalid rows are counted,
/// never fatal, so a partly-bad file still imports what it can.
fn merge_dictionary_file(
    store: &DictionaryStore,
    file: DictionaryFile,
) -> Result<DictionaryImportReport, String> {
    let mut report = DictionaryImportReport {
        accepted: 0,
        skipped_duplicates: 0,
        skipped_invalid: 0,
    };

    for value in &file.words {
        let Some(word) = word_from_value(value) else {
            report.skipped_invalid += 1;
            continue;
        };

        match store.add_word(&word) {
            Ok(_) => report.accepted += 1,
            Err(error) => {
                if error.to_string().contains("already in the dictionary") {
                    report.skipped_duplicates += 1;
                } else {
                    report.skipped_invalid += 1;
                }
            }
        }
    }

    for entry in &file.correction_rules {
        match store.add_rule(&entry.pattern, &entry.replacement) {
            Ok(rule) => {
                if !entry.enabled {
                    let _ = store.set_rule_enabled(rule.id, false);
                }
                report.accepted += 1;
            }
            Err(error) => {
                if error.to_string().contains("already exists") {
                    report.skipped_duplicates += 1;
                } else {
                    report.skipped_invalid += 1;
                }
            }
        }
    }

    Ok(report)
}

fn parse_dictionary_file(contents: &str) -> Result<DictionaryFile, String> {
    let file: DictionaryFile = serde_json::from_str(contents)
        .map_err(|error| format!("Not a valid dictionary file: {error}"))?;

    if let Some(format) = &file.format {
        if format != DICTIONARY_FORMAT {
            return Err(format!("Unsupported dictionary format '{format}'"));
        }
    }
    if let Some(version) = file.version {
        if version != DICTIONARY_FORMAT_VERSION {
            return Err(format!("Unsupported dictionary version {version}"));
        }
    }

    Ok(file)
}

#[tauri::command]
#[specta::specta]
pub fn get_dictionary(
    dictionary: State<'_, Arc<DictionaryStore>>,
) -> Result<DictionaryListing, String> {
    Ok(DictionaryListing {
        words: dictionary.list_words().map_err(|e| e.to_string())?,
        rules: dictionary.list_rules().map_err(|e| e.to_string())?,
    })
}

#[tauri::command]
#[specta::specta]
pub fn add_dictionary_word(
    dictionary: State<'_, Arc<DictionaryStore>>,
    word: String,
) -> Result<DictionaryWord, String> {
    dictionary.add_word(&word).map_err(|e| e.to_string())
}

#[tauri::command]
#[specta::specta]
pub fn update_dictionary_word(
    dictionary: State<'_, Arc<DictionaryStore>>,
    id: i64,
    word: String,
) -> Result<DictionaryWord, String> {
    dictionary.update_word(id, &word).map_err(|e| e.to_string())
}

#[tauri::command]
#[specta::specta]
pub fn delete_dictionary_word(
    dictionary: State<'_, Arc<DictionaryStore>>,
    id: i64,
) -> Result<(), String> {
    dictionary.delete_word(id).map_err(|e| e.to_string())
}

#[tauri::command]
#[specta::specta]
pub fn add_correction_rule(
    dictionary: State<'_, Arc<DictionaryStore>>,
    pattern: String,
    replacement: String,
) -> Result<CorrectionRule, String> {
    dictionary
        .add_rule(&pattern, &replacement)
        .map_err(|e| e.to_string())
}

#[tauri::command]
#[specta::specta]
pub fn update_correction_rule(
    dictionary: State<'_, Arc<DictionaryStore>>,
    id: i64,
    pattern: String,
    replacement: String,
) -> Result<CorrectionRule, String> {
    dictionary
        .update_rule(id, &pattern, &replacement)
        .map_err(|e| e.to_string())
}

#[tauri::command]
#[specta::specta]
pub fn set_correction_rule_enabled(
    dictionary: State<'_, Arc<DictionaryStore>>,
    id: i64,
    enabled: bool,
) -> Result<CorrectionRule, String> {
    dictionary
        .set_rule_enabled(id, enabled)
        .map_err(|e| e.to_string())
}

#[tauri::command]
#[specta::specta]
pub fn delete_correction_rule(
    dictionary: State<'_, Arc<DictionaryStore>>,
    id: i64,
) -> Result<(), String> {
    dictionary.delete_rule(id).map_err(|e| e.to_string())
}

#[tauri::command]
#[specta::specta]
pub fn export_dictionary(
    dictionary: State<'_, Arc<DictionaryStore>>,
    path: String,
) -> Result<(), String> {
    let listing = get_dictionary(dictionary)?;

    let file = serde_json::json!({
        "format": DICTIONARY_FORMAT,
        "version": DICTIONARY_FORMAT_VERSION,
        "words": listing.words.iter().map(|entry| entry.word.clone()).collect::<Vec<_>>(),
        "correctionRules": listing.rules.iter().map(|rule| serde_json::json!({
            "pattern": rule.pattern,
            "replacement": rule.replacement,
            "enabled": rule.enabled,
        })).collect::<Vec<_>>(),
    });

    let contents = serde_json::to_string_pretty(&file)
        .map_err(|error| format!("Failed to serialize the dictionary: {error}"))?;
    std::fs::write(&path, contents).map_err(|error| format!("Failed to write {path}: {error}"))
}

#[tauri::command]
#[specta::specta]
pub fn import_dictionary(
    dictionary: State<'_, Arc<DictionaryStore>>,
    path: String,
) -> Result<DictionaryImportReport, String> {
    let contents = std::fs::read_to_string(&path)
        .map_err(|error| format!("Failed to read {path}: {error}"))?;
    let file = parse_dictionary_file(&contents)?;

    merge_dictionary_file(&dictionary, file)
}

/// The misheard texts the user undid. Learning skips these, so the settings page
/// has to show them — otherwise the feature silently stops learning a word.
#[tauri::command]
#[specta::specta]
pub fn list_learning_rejections(
    dictionary: State<'_, Arc<DictionaryStore>>,
) -> Result<Vec<String>, String> {
    dictionary
        .list_learning_rejections()
        .map_err(|e| e.to_string())
}

/// Allow this mishearing to be learned again.
#[tauri::command]
#[specta::specta]
pub fn forget_learning_rejection(
    dictionary: State<'_, Arc<DictionaryStore>>,
    pattern: String,
) -> Result<(), String> {
    dictionary
        .forget_learning_rejection(&pattern)
        .map_err(|e| e.to_string())
}

#[tauri::command]
#[specta::specta]
pub fn clear_learning_rejections(
    dictionary: State<'_, Arc<DictionaryStore>>,
) -> Result<(), String> {
    dictionary
        .clear_learning_rejections()
        .map_err(|e| e.to_string())
}

/// Limits exposed to the UI so its inline validation matches the backend.
/// Take back what we just learned: remove the word and remember that the user
/// rejected it, so the same edit does not teach it again.
#[tauri::command]
#[specta::specta]
pub fn undo_last_dictionary_learning(
    app: AppHandle,
    dictionary: State<'_, Arc<DictionaryStore>>,
) -> Result<(), String> {
    let state = app
        .try_state::<crate::learning::LearningState>()
        .ok_or_else(|| "Nothing to undo".to_string())?;
    let applied = state.take();
    if applied.is_empty() {
        return Err("Nothing to undo".to_string());
    }

    for (word, pattern) in applied {
        dictionary
            .undo_learned_word(&word)
            .map_err(|e| e.to_string())?;
        dictionary
            .remember_learning_rejection(&pattern)
            .map_err(|e| e.to_string())?;
    }

    let _ = DictionaryChanged {}.emit(&app);
    crate::overlay::hide_recording_overlay(&app);
    Ok(())
}

/// Report what the accessibility layer can see, so "learn from edits" can be
/// diagnosed from the settings page instead of a log file.
#[tauri::command]
#[specta::specta]
pub fn diagnose_edit_learning(app: AppHandle) -> Vec<String> {
    crate::learning::diagnose()
}

/// Hide the overlay window. Used by the overlay's own buttons so the Rust side
/// does not need a timer.
#[tauri::command]
#[specta::specta]
pub fn hide_overlay(app: AppHandle) {
    crate::overlay::hide_recording_overlay(&app);
}

#[tauri::command]
#[specta::specta]
pub fn get_dictionary_limits() -> DictionaryLimits {
    DictionaryLimits {
        word_max_chars: WORD_MAX_CHARS as u32,
        rule_pattern_max_chars: RULE_PATTERN_MAX_CHARS as u32,
        rule_replacement_max_chars: RULE_REPLACEMENT_MAX_CHARS as u32,
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Type)]
pub struct DictionaryLimits {
    pub word_max_chars: u32,
    pub rule_pattern_max_chars: u32,
    pub rule_replacement_max_chars: u32,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::managers::dictionary::DictionaryStore;
    use tempfile::TempDir;

    fn fresh_store() -> (DictionaryStore, TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let store = DictionaryStore::at_for_tests(dir.path().join("dictionary.db")).unwrap();
        (store, dir)
    }

    fn file(contents: &str) -> DictionaryFile {
        parse_dictionary_file(contents).expect("parse")
    }

    #[test]
    fn import_merges_and_counts_duplicates_and_invalid_rows() {
        let (store, _dir) = fresh_store();
        store.add_word("Tauri").unwrap();

        let parsed = file(
            r#"{
                "format": "talkwtf_dictionary",
                "version": 1,
                "words": ["Tauri", "OpenTypeless", {"word": "Whisper"}, 42, ""],
                "correctionRules": [
                    { "pattern": "open type place", "replacement": "OpenTypeless", "enabled": true },
                    { "pattern": "tauri", "replacement": "Tauri", "enabled": false }
                ]
            }"#,
        );

        let report = merge_dictionary_file(&store, parsed).unwrap();
        assert_eq!(report.accepted, 4); // OpenTypeless, Whisper, 2 rules
        assert_eq!(report.skipped_duplicates, 1); // Tauri
        assert_eq!(report.skipped_invalid, 2); // 42, ""

        let words: Vec<String> = store
            .list_words()
            .unwrap()
            .into_iter()
            .map(|entry| entry.word)
            .collect();
        assert_eq!(words, vec!["Tauri", "OpenTypeless", "Whisper"]);

        // The disabled rule is stored but not active.
        assert_eq!(store.list_rules().unwrap().len(), 2);
        assert_eq!(store.snapshot().unwrap().rules.len(), 1);
    }

    #[test]
    fn import_rejects_foreign_format_and_version() {
        assert!(parse_dictionary_file(r#"{"format":"something_else","words":[]}"#).is_err());
        assert!(parse_dictionary_file(r#"{"version":99,"words":[]}"#).is_err());
        assert!(parse_dictionary_file("not json").is_err());
    }

    #[test]
    fn import_accepts_bare_arrays_and_alias_keys() {
        let parsed = file(
            r#"{
                "words": ["Tauri"],
                "correction_rules": [
                    { "wrong_phrase": "tauri", "corrected_phrase": "Tauri" }
                ]
            }"#,
        );

        assert_eq!(parsed.words.len(), 1);
        assert_eq!(parsed.correction_rules.len(), 1);
        assert_eq!(parsed.correction_rules[0].pattern, "tauri");
        assert!(parsed.correction_rules[0].enabled);
    }

    #[test]
    fn export_round_trips_through_import() {
        let (store, _dir) = fresh_store();
        store.add_word("OpenTypeless").unwrap();
        store.add_rule("open type place", "OpenTypeless").unwrap();

        let listing = DictionaryListing {
            words: store.list_words().unwrap(),
            rules: store.list_rules().unwrap(),
        };
        let exported = serde_json::json!({
            "format": DICTIONARY_FORMAT,
            "version": DICTIONARY_FORMAT_VERSION,
            "words": listing.words.iter().map(|entry| entry.word.clone()).collect::<Vec<_>>(),
            "correctionRules": listing.rules.iter().map(|rule| serde_json::json!({
                "pattern": rule.pattern,
                "replacement": rule.replacement,
                "enabled": rule.enabled,
            })).collect::<Vec<_>>(),
        })
        .to_string();

        let (fresh, _dir2) = fresh_store();
        let report = merge_dictionary_file(&fresh, file(&exported)).unwrap();

        assert_eq!(report.accepted, 2);
        assert_eq!(report.skipped_duplicates, 0);
        assert_eq!(report.skipped_invalid, 0);
        assert_eq!(fresh.list_words().unwrap().len(), 1);
        assert_eq!(fresh.list_rules().unwrap().len(), 1);
    }
}
