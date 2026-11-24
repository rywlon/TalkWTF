//! SQLite-backed dictionary: user terms plus deterministic correction rules.
//!
//! Lives in its own `dictionary.db` rather than in `history.db` so the two
//! migration chains stay independent and neither manager has to know about the
//! other's schema. The shape mirrors `HistoryManager`: no long-lived connection,
//! one `Connection::open` per call, `anyhow::Result` for errors.

use std::path::PathBuf;

use anyhow::{anyhow, Result};
use log::info;
use rusqlite::{params, Connection, OptionalExtension};
use rusqlite_migration::{Migrations, M};
use serde::{Deserialize, Serialize};
use specta::Type;

pub const WORD_MAX_CHARS: usize = 100;
pub const RULE_PATTERN_MAX_CHARS: usize = 120;
pub const RULE_REPLACEMENT_MAX_CHARS: usize = 120;

/// How many terms and rules reach the polish prompt. Beyond this the system
/// prompt keeps growing without improving the result. OpenTypeless caps rules
/// at 100 but leaves terms unbounded; we cap both.
pub const PROMPT_WORD_LIMIT: usize = 200;
pub const PROMPT_RULE_LIMIT: usize = 100;

const LEGACY_IMPORT_FLAG: &str = "legacy_custom_words_imported";
/// Corrections the user undid. Remembered so we do not propose them again.
const REJECTED_LEARNING_KEY: &str = "rejected_learning";
const REJECTED_LEARNING_LIMIT: usize = 50;

/// How many learning attempts are kept. The debug pane only ever shows the most
/// recent few, and this is diagnostics, not data worth growing without bound.
pub const LEARNING_ATTEMPT_LIMIT: usize = 200;

static MIGRATIONS: &[M] = &[
    M::up(
        "CREATE TABLE dictionary (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        word TEXT NOT NULL
    );
    CREATE TABLE correction_rules (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        pattern TEXT NOT NULL,
        replacement TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1
    );
    CREATE TABLE meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );",
    ),
    M::up(
        "CREATE TABLE learning_attempts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL,
            bundle_id TEXT,
            field_id TEXT,
            pasted TEXT NOT NULL,
            final_text TEXT NOT NULL,
            source TEXT NOT NULL,
            llm_raw TEXT,
            outcome TEXT NOT NULL,
            reason TEXT NOT NULL,
            learned_json TEXT
        );",
    ),
    M::up("ALTER TABLE learning_attempts ADD COLUMN strategy TEXT;"),
];

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
pub struct DictionaryWord {
    pub id: i64,
    pub word: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
pub struct CorrectionRule {
    pub id: i64,
    pub pattern: String,
    pub replacement: String,
    pub enabled: bool,
}

/// A learning attempt to record. Written once per settle, whether it learned
/// something or not, so a failed learn can be diagnosed after the fact.
#[derive(Debug, Clone, Serialize, Deserialize, Type)]
pub struct NewLearningAttempt {
    pub bundle_id: Option<String>,
    pub field_id: Option<String>,
    pub pasted: String,
    pub final_text: String,
    pub source: String,
    pub llm_raw: Option<String>,
    pub outcome: String,
    pub reason: String,
    pub learned_json: Option<String>,
    pub strategy: Option<String>,
}

/// A recorded learning attempt, as read back for the debug pane.
#[derive(Debug, Clone, Serialize, Deserialize, Type)]
pub struct LearningAttempt {
    pub id: i64,
    pub created_at: String,
    pub bundle_id: Option<String>,
    pub field_id: Option<String>,
    pub pasted: String,
    pub final_text: String,
    pub source: String,
    pub llm_raw: Option<String>,
    pub outcome: String,
    pub reason: String,
    pub learned_json: Option<String>,
    pub strategy: Option<String>,
}

/// Everything the transcription and polish paths need, read once per dictation
/// so a single run cannot observe a half-applied edit.
#[derive(Debug, Clone, Default)]
pub struct DictionarySnapshot {
    pub words: Vec<String>,
    pub rules: Vec<CorrectionRule>,
}

/// Duplicate detection identity. SQLite cannot express Unicode-aware case
/// folding, so dedupe happens in Rust (matching OpenTypeless). Note this does
/// not fold full-width Latin onto ASCII — NFKC would need another dependency.
fn word_identity(word: &str) -> String {
    word.trim().to_lowercase()
}

fn rule_identity(pattern: &str, replacement: &str) -> String {
    format!(
        "{}\u{1f}{}",
        pattern.trim().to_lowercase(),
        replacement.trim().to_lowercase()
    )
}

fn clean_text(value: &str) -> String {
    value.replace('\0', "").trim().to_string()
}

fn prepare_word(word: &str) -> Result<String> {
    let word = clean_text(word);
    if word.is_empty() {
        return Err(anyhow!("Word must not be empty"));
    }
    if word.chars().count() > WORD_MAX_CHARS {
        return Err(anyhow!("Word must be at most {WORD_MAX_CHARS} characters"));
    }
    Ok(word)
}

fn prepare_rule(pattern: &str, replacement: &str) -> Result<(String, String)> {
    let pattern = clean_text(pattern);
    let replacement = clean_text(replacement);

    if pattern.is_empty() {
        return Err(anyhow!("The wrong phrase must not be empty"));
    }
    if replacement.is_empty() {
        return Err(anyhow!("The corrected phrase must not be empty"));
    }
    if pattern.chars().count() > RULE_PATTERN_MAX_CHARS {
        return Err(anyhow!(
            "The wrong phrase must be at most {RULE_PATTERN_MAX_CHARS} characters"
        ));
    }
    if replacement.chars().count() > RULE_REPLACEMENT_MAX_CHARS {
        return Err(anyhow!(
            "The corrected phrase must be at most {RULE_REPLACEMENT_MAX_CHARS} characters"
        ));
    }

    Ok((pattern, replacement))
}

/// Apply the user's correction rules as literal, case-insensitive replacements,
/// in id order.
///
/// ASCII patterns match on word boundaries so a rule `not` → `note` cannot
/// rewrite "I am not sure" inside another word. Patterns containing non-ASCII
/// (CJK) fall back to plain substring matching, because `\b` has no meaning
/// between CJK characters. The pattern is always escaped, so user input can
/// never turn into a regex.
pub fn apply_correction_rules(text: &str, rules: &[CorrectionRule]) -> String {
    let mut result = text.to_string();

    for rule in rules.iter().filter(|rule| rule.enabled) {
        let pattern = rule.pattern.trim();
        if pattern.is_empty() {
            continue;
        }

        let escaped = regex::escape(pattern);
        let word_bounded = pattern
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || character == ' ');
        let expression = if word_bounded {
            format!(r"(?i)\b{escaped}\b")
        } else {
            format!(r"(?i){escaped}")
        };

        let Ok(regex) = regex::Regex::new(&expression) else {
            continue;
        };
        // `NoExpand` keeps a `$` in the replacement literal instead of treating
        // it as a capture-group reference.
        result = regex
            .replace_all(&result, regex::NoExpand(&rule.replacement))
            .into_owned();
    }

    result
}

/// Quotes and newlines would break out of the `- "term"` list item, so they are
/// stripped before the text reaches the model. Same treatment OpenTypeless uses.
fn sanitize_prompt_list_item(value: &str) -> String {
    value
        .replace('"', "")
        .replace(['\n', '\r'], " ")
        .replace('\0', "")
        .trim()
        .chars()
        .take(WORD_MAX_CHARS)
        .collect()
}

fn append_dictionary_prompt(prompt: &mut String, words: &[String]) {
    let mut appended = 0usize;

    for word in words {
        let sanitized = sanitize_prompt_list_item(word);
        if sanitized.is_empty() {
            continue;
        }
        if appended == 0 {
            prompt.push_str(
                "\n\nIMPORTANT: The following are the user's custom terms, listed only to fix the \
                 SPELLING of a term the transcript already contains — including a phonetic or \
                 near-miss rendering of it. Never replace a different word the user said with one \
                 of these terms, and never insert a term the user did not say. If nothing in the \
                 transcript sounds like a term, leave the transcript alone:",
            );
        }
        prompt.push_str(&format!("\n- \"{sanitized}\""));
        appended += 1;
    }
}

fn append_correction_rules_prompt(prompt: &mut String, rules: &[CorrectionRule]) {
    let mut appended = 0usize;

    for rule in rules.iter().filter(|rule| rule.enabled) {
        let pattern = sanitize_prompt_list_item(&rule.pattern);
        let replacement = sanitize_prompt_list_item(&rule.replacement);
        if pattern.is_empty() || replacement.is_empty() {
            continue;
        }
        if appended == 0 {
            prompt.push_str(
                "\n\nUSER CORRECTION RULES: When the transcript likely contains the left phrase, \
                 output the right phrase. Use context; do not apply blindly if it would change the \
                 intended meaning.",
            );
        }
        prompt.push_str(&format!("\n- \"{pattern}\" -> \"{replacement}\""));
        appended += 1;
    }
}

/// Append the dictionary sections to a system prompt. Kept here so the wording
/// lives next to the data it describes.
pub fn append_dictionary_sections(prompt: &mut String, snapshot: &DictionarySnapshot) {
    append_dictionary_prompt(prompt, &snapshot.words);
    append_correction_rules_prompt(prompt, &snapshot.rules);
}

pub struct DictionaryStore {
    db_path: PathBuf,
}

impl DictionaryStore {
    /// Opens (and migrates) the dictionary database, then performs the one-time
    /// import of the retired `custom_words` setting.
    pub fn new() -> Result<Self> {
        let db_path = crate::settings::data_dir().join("dictionary.db");
        let store = Self { db_path };
        store.init_database()?;
        store.import_legacy_custom_words()?;
        Ok(store)
    }

    /// Test-only constructor. Public (doc-hidden) so the Tauri shell's tests can
    /// build a store against a temp path too.
    #[doc(hidden)]
    pub fn at_for_tests(db_path: PathBuf) -> Result<Self> {
        let store = Self { db_path };
        store.init_database()?;
        Ok(store)
    }

    fn get_connection(&self) -> Result<Connection> {
        Ok(Connection::open(&self.db_path)?)
    }

    fn init_database(&self) -> Result<()> {
        let mut conn = Connection::open(&self.db_path)?;
        let migrations = Migrations::new(MIGRATIONS.to_vec());
        #[cfg(debug_assertions)]
        migrations
            .validate()
            .expect("Invalid dictionary migrations");
        migrations.to_latest(&mut conn)?;
        Ok(())
    }

    /// Move the words that used to live in `settings_store.json` into the
    /// database, exactly once. Guarded by a `meta` flag rather than "is the
    /// table empty" so deleting every word does not resurrect them on restart.
    fn import_legacy_custom_words(&self) -> Result<()> {
        let conn = self.get_connection()?;

        let already_imported = conn
            .query_row(
                "SELECT value FROM meta WHERE key = ?1",
                params![LEGACY_IMPORT_FLAG],
                |row| row.get::<_, String>(0),
            )
            .optional()?
            .is_some();
        if already_imported {
            return Ok(());
        }

        let legacy = crate::settings::legacy_custom_words();

        let mut imported = 0usize;
        for word in legacy {
            let Ok(word) = prepare_word(&word) else {
                continue;
            };
            if self.insert_word_if_new(&conn, &word)? {
                imported += 1;
            }
        }

        conn.execute(
            "INSERT OR REPLACE INTO meta (key, value) VALUES (?1, '1')",
            params![LEGACY_IMPORT_FLAG],
        )?;

        if imported > 0 {
            info!("Imported {imported} legacy custom word(s) into the dictionary");
        }
        Ok(())
    }

    // ---- reads -----------------------------------------------------------

    pub fn list_words(&self) -> Result<Vec<DictionaryWord>> {
        let conn = self.get_connection()?;
        let mut statement = conn.prepare("SELECT id, word FROM dictionary ORDER BY id ASC")?;
        let rows = statement.query_map([], |row| {
            Ok(DictionaryWord {
                id: row.get(0)?,
                word: row.get(1)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn list_rules(&self) -> Result<Vec<CorrectionRule>> {
        let conn = self.get_connection()?;
        let mut statement = conn.prepare(
            "SELECT id, pattern, replacement, enabled FROM correction_rules ORDER BY id ASC",
        )?;
        let rows = statement.query_map([], |row| {
            Ok(CorrectionRule {
                id: row.get(0)?,
                pattern: row.get(1)?,
                replacement: row.get(2)?,
                enabled: row.get::<_, i64>(3)? != 0,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    /// Words and enabled rules for one dictation. `words` is capped at
    /// [`PROMPT_WORD_LIMIT`] and `rules` at [`PROMPT_RULE_LIMIT`]; both limits
    /// exist for the prompt path, and applying fewer rules than stored is only
    /// a problem for someone with a very large dictionary.
    pub fn snapshot(&self) -> Result<DictionarySnapshot> {
        let mut words: Vec<String> = self
            .list_words()?
            .into_iter()
            .map(|entry| entry.word)
            .collect();
        words.truncate(PROMPT_WORD_LIMIT);

        let mut rules = self.enabled_rules()?;
        rules.truncate(PROMPT_RULE_LIMIT);

        Ok(DictionarySnapshot { words, rules })
    }

    fn enabled_rules(&self) -> Result<Vec<CorrectionRule>> {
        Ok(self
            .list_rules()?
            .into_iter()
            .filter(|rule| rule.enabled)
            .collect())
    }

    // ---- word writes -----------------------------------------------------

    fn existing_words(&self, conn: &Connection) -> Result<Vec<String>> {
        let mut statement = conn.prepare("SELECT word FROM dictionary")?;
        let rows = statement.query_map([], |row| row.get::<_, String>(0))?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    fn insert_word_if_new(&self, conn: &Connection, word: &str) -> Result<bool> {
        let identity = word_identity(word);
        if self
            .existing_words(conn)?
            .iter()
            .any(|existing| word_identity(existing) == identity)
        {
            return Ok(false);
        }

        conn.execute("INSERT INTO dictionary (word) VALUES (?1)", params![word])?;
        Ok(true)
    }

    pub fn add_word(&self, word: &str) -> Result<DictionaryWord> {
        let word = prepare_word(word)?;
        let conn = self.get_connection()?;

        if !self.insert_word_if_new(&conn, &word)? {
            return Err(anyhow!("\"{word}\" is already in the dictionary"));
        }

        Ok(DictionaryWord {
            id: conn.last_insert_rowid(),
            word,
        })
    }

    pub fn update_word(&self, id: i64, word: &str) -> Result<DictionaryWord> {
        let word = prepare_word(word)?;
        let conn = self.get_connection()?;

        let identity = word_identity(&word);
        let clashes = self
            .list_words()?
            .into_iter()
            .any(|entry| entry.id != id && word_identity(&entry.word) == identity);
        if clashes {
            return Err(anyhow!("\"{word}\" is already in the dictionary"));
        }

        let updated = conn.execute(
            "UPDATE dictionary SET word = ?1 WHERE id = ?2",
            params![word, id],
        )?;
        if updated == 0 {
            return Err(anyhow!("Word {id} was not found"));
        }

        Ok(DictionaryWord { id, word })
    }

    pub fn delete_word(&self, id: i64) -> Result<()> {
        let conn = self.get_connection()?;
        let deleted = conn.execute("DELETE FROM dictionary WHERE id = ?1", params![id])?;
        if deleted == 0 {
            return Err(anyhow!("Word {id} was not found"));
        }
        Ok(())
    }

    // ---- rule writes -----------------------------------------------------

    fn rule_clashes(
        &self,
        conn: &Connection,
        id: Option<i64>,
        pattern: &str,
        replacement: &str,
    ) -> Result<bool> {
        let identity = rule_identity(pattern, replacement);
        let mut statement =
            conn.prepare("SELECT id, pattern, replacement FROM correction_rules")?;
        let rows = statement.query_map([], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
            ))
        })?;

        for row in rows {
            let (row_id, row_pattern, row_replacement) = row?;
            if Some(row_id) == id {
                continue;
            }
            if rule_identity(&row_pattern, &row_replacement) == identity {
                return Ok(true);
            }
        }
        Ok(false)
    }

    pub fn add_rule(&self, pattern: &str, replacement: &str) -> Result<CorrectionRule> {
        let (pattern, replacement) = prepare_rule(pattern, replacement)?;
        let conn = self.get_connection()?;

        if self.rule_clashes(&conn, None, &pattern, &replacement)? {
            return Err(anyhow!("That correction rule already exists"));
        }

        conn.execute(
            "INSERT INTO correction_rules (pattern, replacement, enabled) VALUES (?1, ?2, 1)",
            params![pattern, replacement],
        )?;

        Ok(CorrectionRule {
            id: conn.last_insert_rowid(),
            pattern,
            replacement,
            enabled: true,
        })
    }

    pub fn update_rule(&self, id: i64, pattern: &str, replacement: &str) -> Result<CorrectionRule> {
        let (pattern, replacement) = prepare_rule(pattern, replacement)?;
        let conn = self.get_connection()?;

        if self.rule_clashes(&conn, Some(id), &pattern, &replacement)? {
            return Err(anyhow!("That correction rule already exists"));
        }

        let updated = conn.execute(
            "UPDATE correction_rules SET pattern = ?1, replacement = ?2 WHERE id = ?3",
            params![pattern, replacement, id],
        )?;
        if updated == 0 {
            return Err(anyhow!("Correction rule {id} was not found"));
        }

        let enabled = conn.query_row(
            "SELECT enabled FROM correction_rules WHERE id = ?1",
            params![id],
            |row| row.get::<_, i64>(0),
        )?;

        Ok(CorrectionRule {
            id,
            pattern,
            replacement,
            enabled: enabled != 0,
        })
    }

    pub fn set_rule_enabled(&self, id: i64, enabled: bool) -> Result<CorrectionRule> {
        let conn = self.get_connection()?;

        let updated = conn.execute(
            "UPDATE correction_rules SET enabled = ?1 WHERE id = ?2",
            params![i64::from(enabled), id],
        )?;
        if updated == 0 {
            return Err(anyhow!("Correction rule {id} was not found"));
        }

        let (pattern, replacement) = conn.query_row(
            "SELECT pattern, replacement FROM correction_rules WHERE id = ?1",
            params![id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        )?;

        Ok(CorrectionRule {
            id,
            pattern,
            replacement,
            enabled,
        })
    }

    pub fn delete_rule(&self, id: i64) -> Result<()> {
        let conn = self.get_connection()?;
        let deleted = conn.execute("DELETE FROM correction_rules WHERE id = ?1", params![id])?;
        if deleted == 0 {
            return Err(anyhow!("Correction rule {id} was not found"));
        }
        Ok(())
    }

    // ---- learning from edits --------------------------------------------

    /// Whether this word is already in the dictionary.
    pub fn has_word(&self, word: &str) -> Result<bool> {
        let identity = word_identity(word);
        Ok(self
            .list_words()?
            .iter()
            .any(|entry| word_identity(&entry.word) == identity))
    }

    /// The misheard texts that will not be learned again, oldest first. Stored as
    /// the text the user typed (not lowercased) so the settings page can show it;
    /// matching is case-insensitive.
    pub fn list_learning_rejections(&self) -> Result<Vec<String>> {
        let conn = self.get_connection()?;
        self.read_rejected_learning(&conn)
    }

    /// Whether the user already undid (rejected) this misheard text. Kept so the
    /// same mistake is not learned again — keyed on the wrong text, not on the
    /// word: undoing "OpenType 设置" must not block learning "OpenTypeless" from
    /// some other mishearing later.
    pub fn is_learning_rejected(&self, pattern: &str) -> Result<bool> {
        let identity = word_identity(pattern);
        let conn = self.get_connection()?;
        Ok(self
            .read_rejected_learning(&conn)?
            .iter()
            .any(|entry| word_identity(entry) == identity))
    }

    pub fn remember_learning_rejection(&self, pattern: &str) -> Result<()> {
        let pattern = pattern.trim();
        if pattern.is_empty() || self.is_learning_rejected(pattern)? {
            return Ok(());
        }

        let conn = self.get_connection()?;
        let mut rejected = self.read_rejected_learning(&conn)?;
        rejected.push(pattern.to_string());
        if rejected.len() > REJECTED_LEARNING_LIMIT {
            let excess = rejected.len() - REJECTED_LEARNING_LIMIT;
            rejected.drain(0..excess);
        }

        self.write_rejected_learning(&conn, &rejected)
    }

    /// Allow this mishearing to be learned again.
    pub fn forget_learning_rejection(&self, pattern: &str) -> Result<()> {
        let identity = word_identity(pattern);
        let conn = self.get_connection()?;
        let rejected: Vec<String> = self
            .read_rejected_learning(&conn)?
            .into_iter()
            .filter(|entry| word_identity(entry) != identity)
            .collect();

        self.write_rejected_learning(&conn, &rejected)
    }

    pub fn clear_learning_rejections(&self) -> Result<()> {
        let conn = self.get_connection()?;
        self.write_rejected_learning(&conn, &[])
    }

    fn write_rejected_learning(&self, conn: &Connection, rejected: &[String]) -> Result<()> {
        if rejected.is_empty() {
            conn.execute(
                "DELETE FROM meta WHERE key = ?1",
                params![REJECTED_LEARNING_KEY],
            )?;
            return Ok(());
        }

        conn.execute(
            "INSERT OR REPLACE INTO meta (key, value) VALUES (?1, ?2)",
            params![REJECTED_LEARNING_KEY, serde_json::to_string(rejected)?],
        )?;
        Ok(())
    }

    fn read_rejected_learning(&self, conn: &Connection) -> Result<Vec<String>> {
        let stored = conn
            .query_row(
                "SELECT value FROM meta WHERE key = ?1",
                params![REJECTED_LEARNING_KEY],
                |row| row.get::<_, String>(0),
            )
            .optional()?;

        Ok(stored
            .and_then(|json| serde_json::from_str(&json).ok())
            .unwrap_or_default())
    }

    /// Undo a learned word. Exact rollback — never "delete anything with this
    /// name"; only the entry we added comes back out.
    pub fn undo_learned_word(&self, word: &str) -> Result<()> {
        let identity = word_identity(word);
        let word_id = self
            .list_words()?
            .into_iter()
            .find(|entry| word_identity(&entry.word) == identity)
            .map(|entry| entry.id);

        if let Some(id) = word_id {
            let conn = self.get_connection()?;
            conn.execute("DELETE FROM dictionary WHERE id = ?1", params![id])?;
        }

        Ok(())
    }

    // ---- learning attempts (diagnostics) --------------------------------

    /// Record one learning attempt and trim the table to the newest
    /// [`LEARNING_ATTEMPT_LIMIT`] rows.
    pub fn add_learning_attempt(&self, attempt: &NewLearningAttempt) -> Result<()> {
        let conn = self.get_connection()?;
        let created_at = chrono::Utc::now().to_rfc3339();
        conn.execute(
            "INSERT INTO learning_attempts
                (created_at, bundle_id, field_id, pasted, final_text, source, llm_raw, outcome, reason, learned_json, strategy)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
            params![
                created_at,
                attempt.bundle_id,
                attempt.field_id,
                attempt.pasted,
                attempt.final_text,
                attempt.source,
                attempt.llm_raw,
                attempt.outcome,
                attempt.reason,
                attempt.learned_json,
                attempt.strategy,
            ],
        )?;
        conn.execute(
            "DELETE FROM learning_attempts WHERE id NOT IN (
                SELECT id FROM learning_attempts ORDER BY id DESC LIMIT ?1
             )",
            params![LEARNING_ATTEMPT_LIMIT as i64],
        )?;
        Ok(())
    }

    /// The newest `limit` attempts, newest first.
    pub fn list_learning_attempts(&self, limit: usize) -> Result<Vec<LearningAttempt>> {
        let conn = self.get_connection()?;
        let mut stmt = conn.prepare(
            "SELECT id, created_at, bundle_id, field_id, pasted, final_text, source,
                    llm_raw, outcome, reason, learned_json, strategy
             FROM learning_attempts ORDER BY id DESC LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![limit as i64], |row| {
            Ok(LearningAttempt {
                id: row.get(0)?,
                created_at: row.get(1)?,
                bundle_id: row.get(2)?,
                field_id: row.get(3)?,
                pasted: row.get(4)?,
                final_text: row.get(5)?,
                source: row.get(6)?,
                llm_raw: row.get(7)?,
                outcome: row.get(8)?,
                reason: row.get(9)?,
                learned_json: row.get(10)?,
                strategy: row.get(11)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn clear_learning_attempts(&self) -> Result<()> {
        let conn = self.get_connection()?;
        conn.execute("DELETE FROM learning_attempts", [])?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> (DictionaryStore, tempfile::TempDir) {
        let dir = tempfile::tempdir().expect("temp dir");
        let store =
            DictionaryStore::at_for_tests(dir.path().join("dictionary.db")).expect("open store");
        (store, dir)
    }

    #[test]
    fn learning_attempts_round_trip_and_trim() {
        let (store, _dir) = store();
        for index in 0..205 {
            store
                .add_learning_attempt(&NewLearningAttempt {
                    bundle_id: Some("com.test".into()),
                    field_id: Some("field-1".into()),
                    pasted: format!("wrong {index}"),
                    final_text: format!("right {index}"),
                    source: "local".into(),
                    llm_raw: None,
                    outcome: "learned".into(),
                    reason: "learned from the local gate".into(),
                    learned_json: Some("[]".into()),
                    strategy: Some("focused element, AXValue".into()),
                })
                .unwrap();
        }
        let attempts = store.list_learning_attempts(500).unwrap();
        assert_eq!(attempts.len(), 200);
        // Newest first; the five oldest were trimmed away, so "wrong 5" is the
        // oldest surviving row.
        assert_eq!(attempts[0].pasted, "wrong 204");
        assert_eq!(attempts.last().unwrap().pasted, "wrong 5");

        store.clear_learning_attempts().unwrap();
        assert!(store.list_learning_attempts(10).unwrap().is_empty());
    }

    #[test]
    fn rejections_are_listed_forgotten_and_cleared() {
        let (store, _dir) = store();
        store.remember_learning_rejection("浏览器").unwrap();
        store.remember_learning_rejection("OpenType 设置").unwrap();

        // The text is shown as typed, not lowercased.
        assert_eq!(
            store.list_learning_rejections().unwrap(),
            vec!["浏览器".to_string(), "OpenType 设置".to_string()]
        );

        store.forget_learning_rejection("OPENTYPE 设置").unwrap();
        assert_eq!(
            store.list_learning_rejections().unwrap(),
            vec!["浏览器".to_string()]
        );
        assert!(!store.is_learning_rejected("OpenType 设置").unwrap());

        store.clear_learning_rejections().unwrap();
        assert!(store.list_learning_rejections().unwrap().is_empty());
        assert!(!store.is_learning_rejected("浏览器").unwrap());
    }

    #[test]
    fn has_word_ignores_case_and_padding() {
        let (store, _dir) = store();
        store.add_word("OpenTypeless").unwrap();

        assert!(store.has_word("OpenTypeless").unwrap());
        assert!(store.has_word(" opentypeless ").unwrap());
        assert!(!store.has_word("Open Typeface").unwrap());
    }

    #[test]
    fn undo_learned_word_removes_only_that_word() {
        let (store, _dir) = store();
        store.add_word("Hydra Facial").unwrap();
        store.add_word("Cica Exo").unwrap();

        store.undo_learned_word("hydra facial").unwrap();

        let words = store.list_words().unwrap();
        assert_eq!(words.len(), 1);
        assert_eq!(words[0].word, "Cica Exo");
        // Undoing twice is a no-op, not an error: the row is simply gone.
        store.undo_learned_word("Hydra Facial").unwrap();
        assert_eq!(store.list_words().unwrap().len(), 1);
    }

    #[test]
    fn words_round_trip_and_reject_duplicates() {
        let (store, _dir) = store();

        let added = store.add_word("OpenTypeless").unwrap();
        assert_eq!(added.word, "OpenTypeless");

        // Case-insensitive and whitespace-insensitive duplicates are rejected.
        assert!(store.add_word("opentypeless").is_err());
        assert!(store.add_word("  OPENTYPELESS  ").is_err());

        store.add_word("Tauri").unwrap();
        assert_eq!(
            store
                .list_words()
                .unwrap()
                .into_iter()
                .map(|entry| entry.word)
                .collect::<Vec<_>>(),
            vec!["OpenTypeless", "Tauri"]
        );
    }

    #[test]
    fn words_are_trimmed_and_bounded() {
        let (store, _dir) = store();

        assert_eq!(store.add_word("  Tauri  ").unwrap().word, "Tauri");
        assert!(store.add_word("   ").is_err());
        assert!(store.add_word(&"x".repeat(WORD_MAX_CHARS + 1)).is_err());
        assert_eq!(
            store
                .add_word(&"x".repeat(WORD_MAX_CHARS))
                .unwrap()
                .word
                .len(),
            WORD_MAX_CHARS
        );
    }

    #[test]
    fn word_update_and_delete_report_missing_rows() {
        let (store, _dir) = store();
        let word = store.add_word("Tauri").unwrap();

        let updated = store.update_word(word.id, "tauri v2").unwrap();
        assert_eq!(updated.word, "tauri v2");
        assert_eq!(store.list_words().unwrap().len(), 1);

        store.delete_word(word.id).unwrap();
        assert!(store.list_words().unwrap().is_empty());
        assert!(store.delete_word(word.id).is_err());
        assert!(store.update_word(word.id, "nope").is_err());
    }

    #[test]
    fn rules_round_trip_and_respect_enabled() {
        let (store, _dir) = store();

        let rule = store.add_rule("open type place", "OpenTypeless").unwrap();
        assert!(rule.enabled);

        let snapshot = store.snapshot().unwrap();
        assert_eq!(snapshot.rules.len(), 1);
        assert_eq!(snapshot.rules[0].pattern, "open type place");

        store.set_rule_enabled(rule.id, false).unwrap();
        assert!(store.snapshot().unwrap().rules.is_empty());
        assert_eq!(store.list_rules().unwrap().len(), 1);

        store.set_rule_enabled(rule.id, true).unwrap();
        assert_eq!(store.snapshot().unwrap().rules.len(), 1);
    }

    #[test]
    fn rules_reject_duplicates_and_are_bounded() {
        let (store, _dir) = store();
        store.add_rule("open type place", "OpenTypeless").unwrap();

        assert!(store.add_rule("Open Type Place", "opentypeless").is_err());
        assert!(store.add_rule("", "x").is_err());
        assert!(store.add_rule("x", "  ").is_err());
        assert!(store
            .add_rule(&"p".repeat(RULE_PATTERN_MAX_CHARS + 1), "x")
            .is_err());
        assert!(store
            .add_rule("x", &"r".repeat(RULE_REPLACEMENT_MAX_CHARS + 1))
            .is_err());
    }

    #[test]
    fn snapshot_caps_prompt_payload() {
        let (store, _dir) = store();

        for index in 0..(PROMPT_WORD_LIMIT + 5) {
            store.add_word(&format!("word{index}")).unwrap();
        }
        for index in 0..(PROMPT_RULE_LIMIT + 5) {
            store
                .add_rule(&format!("pattern{index}"), &format!("replacement{index}"))
                .unwrap();
        }

        let snapshot = store.snapshot().unwrap();
        assert_eq!(snapshot.words.len(), PROMPT_WORD_LIMIT);
        assert_eq!(snapshot.rules.len(), PROMPT_RULE_LIMIT);
    }

    #[test]
    fn migrations_are_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("dictionary.db");

        let first = DictionaryStore::at_for_tests(path.clone()).unwrap();
        first.add_word("Tauri").unwrap();

        // Re-opening must not wipe or duplicate anything.
        let second = DictionaryStore::at_for_tests(path).unwrap();
        assert_eq!(second.list_words().unwrap().len(), 1);
    }

    fn rule(id: i64, pattern: &str, replacement: &str, enabled: bool) -> CorrectionRule {
        CorrectionRule {
            id,
            pattern: pattern.to_string(),
            replacement: replacement.to_string(),
            enabled,
        }
    }

    #[test]
    fn correction_rules_replace_literally_and_ignore_case() {
        let rules = vec![rule(1, "open type place", "OpenTypeless", true)];

        assert_eq!(
            apply_correction_rules("我用 open type place", &rules),
            "我用 OpenTypeless"
        );
        assert_eq!(
            apply_correction_rules("OPEN TYPE PLACE is open source", &rules),
            "OpenTypeless is open source"
        );
    }

    #[test]
    fn correction_rules_respect_word_boundaries_for_ascii() {
        let rules = vec![rule(1, "not", "note", true)];

        assert_eq!(
            apply_correction_rules("I am not sure", &rules),
            "I am note sure"
        );
        // Inside a longer word the boundary guard must hold.
        assert_eq!(
            apply_correction_rules("nothing else", &rules),
            "nothing else"
        );
    }

    #[test]
    fn correction_rules_match_cjk_substrings() {
        let rules = vec![rule(1, "大语言模型", "LLM", true)];

        assert_eq!(
            apply_correction_rules("我们用的是大语言模型来处理", &rules),
            "我们用的是LLM来处理"
        );
    }

    #[test]
    fn disabled_rules_are_skipped() {
        let rules = vec![rule(1, "open type place", "OpenTypeless", false)];

        assert_eq!(
            apply_correction_rules("open type place", &rules),
            "open type place"
        );
    }

    #[test]
    fn correction_rules_escape_user_input() {
        // A pattern with regex metacharacters must be treated literally, and a
        // `$` in the replacement must not be read as a capture reference.
        let rules = vec![rule(1, "a+b (test)", "$1 done", true)];

        assert_eq!(
            apply_correction_rules("please a+b (test) now", &rules),
            "please $1 done now"
        );
        assert_eq!(apply_correction_rules("aaab test", &rules), "aaab test");
    }

    #[test]
    fn correction_rules_apply_in_order() {
        let rules = vec![rule(1, "abc", "def", true), rule(2, "def", "ghi", true)];

        // The second rule sees the first rule's output.
        assert_eq!(apply_correction_rules("abc", &rules), "ghi");
    }

    #[test]
    fn prompt_sections_are_added_only_when_there_is_content() {
        let mut prompt = String::from("BASE");

        append_dictionary_sections(&mut prompt, &DictionarySnapshot::default());
        assert_eq!(prompt, "BASE");

        let snapshot = DictionarySnapshot {
            words: vec!["OpenTypeless".to_string()],
            rules: vec![rule(1, "open type place", "OpenTypeless", true)],
        };
        append_dictionary_sections(&mut prompt, &snapshot);

        assert!(prompt.contains("Never replace a different word the user said"));
        assert!(prompt.contains("- \"OpenTypeless\""));
        assert!(prompt.contains("USER CORRECTION RULES"));
        assert!(prompt.contains("- \"open type place\" -> \"OpenTypeless\""));
    }

    #[test]
    fn prompt_section_strips_quotes_and_newlines() {
        let mut prompt = String::new();
        let snapshot = DictionarySnapshot {
            words: vec!["bad\"word\nnext".to_string()],
            rules: Vec::new(),
        };

        append_dictionary_sections(&mut prompt, &snapshot);

        assert!(prompt.contains("- \"badword next\""));
        assert!(!prompt.contains("bad\"word"));
    }
}
