//! Dictionary JSON import/export.
//!
//! Path-based, like the Tauri command: the shell shows the native file dialog
//! and hands the chosen path down, so the file IO stays in Rust.

use serde::{Deserialize, Serialize};

use crate::dictionary::DictionaryStore;

pub const DICTIONARY_FORMAT: &str = "talkwtf_dictionary";
pub const DICTIONARY_FORMAT_VERSION: u32 = 1;

/// What an import did, so the UI can report it instead of silently succeeding.
#[derive(Debug, Clone, Serialize, Deserialize, specta::Type)]
pub struct DictionaryImportReport {
    pub accepted: u32,
    pub skipped_duplicates: u32,
    pub skipped_invalid: u32,
}

/// On-disk shape. `words` accepts plain strings; the import path also tolerates
/// `{ "word": ... }` objects so files exported by other tools still load.
#[derive(Debug, Deserialize)]
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

#[derive(Debug, Deserialize)]
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

/// Write the whole dictionary to `path` as pretty JSON.
pub fn export_dictionary(store: &DictionaryStore, path: &str) -> Result<(), String> {
    let words = store.list_words().map_err(|error| error.to_string())?;
    let rules = store.list_rules().map_err(|error| error.to_string())?;

    let file = serde_json::json!({
        "format": DICTIONARY_FORMAT,
        "version": DICTIONARY_FORMAT_VERSION,
        "words": words.iter().map(|entry| entry.word.clone()).collect::<Vec<_>>(),
        "correctionRules": rules.iter().map(|rule| serde_json::json!({
            "pattern": rule.pattern,
            "replacement": rule.replacement,
            "enabled": rule.enabled,
        })).collect::<Vec<_>>(),
    });

    let contents = serde_json::to_string_pretty(&file)
        .map_err(|error| format!("Failed to serialize the dictionary: {error}"))?;
    std::fs::write(path, contents).map_err(|error| format!("Failed to write {path}: {error}"))
}

/// Merge a JSON file into the store, reporting what was accepted and skipped.
pub fn import_dictionary(
    store: &DictionaryStore,
    path: &str,
) -> Result<DictionaryImportReport, String> {
    let contents =
        std::fs::read_to_string(path).map_err(|error| format!("Failed to read {path}: {error}"))?;
    let file = parse_dictionary_file(&contents)?;
    merge_dictionary_file(store, file)
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dictionary::DictionaryStore;
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
        store.add_word("TalkWTF").unwrap();

        let parsed = file(
            r#"{
                "format": "talkwtf_dictionary",
                "version": 1,
                "words": ["TalkWTF", "OpenTypeless", {"word": "Whisper"}, 42, ""],
                "correctionRules": [
                    { "pattern": "open type place", "replacement": "OpenTypeless", "enabled": true },
                    { "pattern": "talkwtf", "replacement": "TalkWTF", "enabled": false }
                ]
            }"#,
        );

        let report = merge_dictionary_file(&store, parsed).unwrap();
        assert_eq!(report.accepted, 4); // OpenTypeless, Whisper, 2 rules
        assert_eq!(report.skipped_duplicates, 1); // TalkWTF
        assert_eq!(report.skipped_invalid, 2); // 42, ""

        let words: Vec<String> = store
            .list_words()
            .unwrap()
            .into_iter()
            .map(|entry| entry.word)
            .collect();
        assert_eq!(words, vec!["TalkWTF", "OpenTypeless", "Whisper"]);

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
                "words": ["TalkWTF"],
                "correction_rules": [
                    { "wrong_phrase": "talkwtf", "corrected_phrase": "TalkWTF" }
                ]
            }"#,
        );

        assert_eq!(parsed.words.len(), 1);
        assert_eq!(parsed.correction_rules.len(), 1);
        assert_eq!(parsed.correction_rules[0].pattern, "talkwtf");
        assert!(parsed.correction_rules[0].enabled);
    }

    #[test]
    fn export_round_trips_through_import() {
        let (store, dir) = fresh_store();
        store.add_word("OpenTypeless").unwrap();
        store.add_rule("open type place", "OpenTypeless").unwrap();

        let path = dir.path().join("export.json");
        export_dictionary(&store, path.to_str().unwrap()).unwrap();

        let (fresh, _dir2) = fresh_store();
        let report = import_dictionary(&fresh, path.to_str().unwrap()).unwrap();

        assert_eq!(report.accepted, 2);
        assert_eq!(report.skipped_duplicates, 0);
        assert_eq!(report.skipped_invalid, 0);
        assert_eq!(fresh.list_words().unwrap().len(), 1);
        assert_eq!(fresh.list_rules().unwrap().len(), 1);
    }
}
