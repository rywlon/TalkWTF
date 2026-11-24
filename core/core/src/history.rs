use anyhow::{anyhow, Result};
use chrono::{DateTime, Local, Utc};
use log::{debug, error, info, warn};
use rusqlite::{params, Connection, OptionalExtension};
use rusqlite_migration::{Migrations, M};
use serde::{Deserialize, Serialize};
use specta::Type;
use std::fs;
use std::path::PathBuf;

/// Database migrations for transcription history.
/// Each migration is applied in order. The library tracks which migrations
/// have been applied using SQLite's user_version pragma.
///
/// Note: For users upgrading from tauri-plugin-sql, migrate_from_tauri_plugin_sql()
/// converts the old _sqlx_migrations table tracking to the user_version pragma,
/// ensuring migrations don't re-run on existing databases.
static MIGRATIONS: &[M] = &[
    M::up(
        "CREATE TABLE IF NOT EXISTS transcription_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_name TEXT NOT NULL,
            timestamp INTEGER NOT NULL,
            saved BOOLEAN NOT NULL DEFAULT 0,
            title TEXT NOT NULL,
            transcription_text TEXT NOT NULL
        );",
    ),
    M::up("ALTER TABLE transcription_history ADD COLUMN post_processed_text TEXT;"),
    M::up("ALTER TABLE transcription_history ADD COLUMN post_process_prompt TEXT;"),
    M::up("ALTER TABLE transcription_history ADD COLUMN post_process_requested BOOLEAN NOT NULL DEFAULT 0;"),
    // Dashboard metrics. `duration_ms`/`char_count` are captured at save time
    // (the WAV is 16 kHz mono, so duration is samples/16); `workflow` records
    // which pipeline produced the entry ("dictation" | "translate").
    M::up("ALTER TABLE transcription_history ADD COLUMN duration_ms INTEGER NOT NULL DEFAULT 0;"),
    M::up("ALTER TABLE transcription_history ADD COLUMN char_count INTEGER NOT NULL DEFAULT 0;"),
    M::up("ALTER TABLE transcription_history ADD COLUMN workflow TEXT NOT NULL DEFAULT 'dictation';"),
    // Per-request LLM token usage, for the dashboard's today / last-7-days view.
    M::up(
        "CREATE TABLE IF NOT EXISTS llm_usage (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp INTEGER NOT NULL,
            provider_id TEXT NOT NULL,
            model TEXT NOT NULL,
            workflow TEXT NOT NULL,
            prompt_tokens INTEGER NOT NULL DEFAULT 0,
            completion_tokens INTEGER NOT NULL DEFAULT 0,
            total_tokens INTEGER NOT NULL DEFAULT 0
        );",
    ),
    // Backfill character counts for entries written before the column existed.
    // `length()` on TEXT counts characters (not bytes), which is what 字数 means.
    //
    // NOTE: this is migration #9. An earlier build briefly inserted it before
    // the `llm_usage` migration, which advanced some databases' `user_version`
    // past this slot without running it. Those databases get the same backfill
    // from `HistoryManager::backfill_derived_columns`, which runs at startup and
    // is idempotent; this migration covers fresh installs. Never insert
    // migrations anywhere but the end.
    M::up("UPDATE transcription_history SET char_count = length(trim(transcription_text)) WHERE char_count = 0;"),
];

#[derive(Clone, Debug, Serialize, Deserialize, Type)]
pub struct PaginatedHistory {
    pub entries: Vec<HistoryEntry>,
    pub has_more: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, Type)]
#[serde(tag = "action")]
pub enum HistoryUpdatePayload {
    #[serde(rename = "added")]
    Added { entry: HistoryEntry },
    #[serde(rename = "updated")]
    Updated { entry: HistoryEntry },
    #[serde(rename = "deleted")]
    Deleted { id: i64 },
    #[serde(rename = "toggled")]
    Toggled { id: i64 },
}

#[derive(Clone, Debug, Serialize, Deserialize, Type)]
pub struct HistoryEntry {
    pub id: i64,
    pub file_name: String,
    pub timestamp: i64,
    pub saved: bool,
    pub title: String,
    pub transcription_text: String,
    pub post_processed_text: Option<String>,
    pub post_process_prompt: Option<String>,
    pub post_process_requested: bool,
    /// Recording length in milliseconds (WAV is 16 kHz mono).
    #[serde(default)]
    pub duration_ms: i64,
    /// Characters in the raw transcription, whitespace trimmed.
    #[serde(default)]
    pub char_count: i64,
    /// Which pipeline produced this entry: "dictation" or "translate".
    #[serde(default = "default_workflow")]
    pub workflow: String,
}

fn default_workflow() -> String {
    "dictation".to_string()
}

/// How many recent activities the dashboard lists.
const RECENT_ACTIVITY_LIMIT: i64 = 10;

/// A one-line preview of an entry for the activity list.
fn preview_of(text: &str) -> String {
    let collapsed = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut preview: String = collapsed.chars().take(80).collect();
    if collapsed.chars().count() > 80 {
        preview.push('…');
    }
    preview
}

/// Aggregated dashboard metrics. Plain Rust (the command maps it to the
/// serialized shape) so the SQL stays in one place.
#[derive(Debug, Default, Clone)]
pub struct HistoryStats {
    pub total_recordings: u64,
    pub total_dictation_ms: u64,
    pub total_chars: u64,
    pub translation_count: u64,
    pub today_recordings: u64,
    pub today_translations: u64,
    pub today_dictation_ms: u64,
    pub today_chars: u64,
    pub recent: Vec<RecentActivity>,
    /// Last 7 local days, oldest first.
    pub weekly: Vec<DailyCount>,
    pub tokens_today: TokenUsage,
    pub tokens_week: TokenUsage,
}

#[derive(Debug, Clone)]
pub struct RecentActivity {
    pub id: i64,
    pub timestamp: i64,
    pub workflow: String,
    pub char_count: i64,
    pub preview: String,
}

#[derive(Debug, Clone)]
pub struct DailyCount {
    pub day: String,
    pub count: u64,
}

#[derive(Debug, Default, Clone, Copy)]
pub struct TokenUsage {
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
    pub total_tokens: u64,
    pub requests: u64,
}

pub struct HistoryManager {
    recordings_dir: PathBuf,
    db_path: PathBuf,
}

impl HistoryManager {
    pub fn new() -> Result<Self> {
        // Create recordings directory in app data dir
        let app_data_dir = crate::settings::data_dir();
        let recordings_dir = app_data_dir.join("recordings");
        let db_path = app_data_dir.join("history.db");

        // Ensure recordings directory exists
        if !recordings_dir.exists() {
            fs::create_dir_all(&recordings_dir)?;
            debug!("Created recordings directory: {:?}", recordings_dir);
        }

        let manager = Self {
            recordings_dir,
            db_path,
        };

        // Initialize database and run migrations synchronously
        manager.init_database()?;

        // Best-effort backfill of the dashboard columns for rows written before
        // they existed. Idempotent: only rows still at zero are touched.
        if let Err(e) = manager.backfill_derived_columns() {
            warn!("Failed to backfill history metrics: {e}");
        }

        Ok(manager)
    }

    /// Fill `char_count` from the stored text and `duration_ms` from the WAV
    /// (16 kHz mono). Entries whose WAV is gone keep duration 0. Runs at startup;
    /// rows already populated are skipped.
    fn backfill_derived_columns(&self) -> Result<()> {
        let conn = self.get_connection()?;

        // `length()` on TEXT counts characters (not bytes), matching 字数.
        let chars_updated = conn.execute(
            "UPDATE transcription_history
             SET char_count = length(trim(transcription_text))
             WHERE char_count = 0 AND trim(transcription_text) != ''",
            [],
        )?;

        let rows: Vec<(i64, String)> = {
            let mut stmt = conn.prepare(
                "SELECT id, file_name FROM transcription_history
                 WHERE duration_ms = 0 AND file_name != ''",
            )?;
            let mapped = stmt
                .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            mapped
        };

        let mut durations_updated = 0;
        for (id, file_name) in rows {
            let path = self.recordings_dir.join(&file_name);
            if !path.exists() {
                continue;
            }
            let Ok(samples) = crate::wav::read_wav_samples(&path) else {
                continue;
            };
            if samples.is_empty() {
                continue;
            }
            let duration_ms = (samples.len() as i64) * 1000 / 16_000;
            conn.execute(
                "UPDATE transcription_history SET duration_ms = ?1 WHERE id = ?2",
                params![duration_ms, id],
            )?;
            durations_updated += 1;
        }

        if chars_updated > 0 || durations_updated > 0 {
            info!(
                "Backfilled history metrics: {chars_updated} char counts, {durations_updated} durations"
            );
        }
        Ok(())
    }

    fn init_database(&self) -> Result<()> {
        info!("Initializing database at {:?}", self.db_path);

        let mut conn = Connection::open(&self.db_path)?;

        // Handle migration from tauri-plugin-sql to rusqlite_migration
        // tauri-plugin-sql used _sqlx_migrations table, rusqlite_migration uses user_version pragma
        self.migrate_from_tauri_plugin_sql(&conn)?;

        // Create migrations object and run to latest version
        let migrations = Migrations::new(MIGRATIONS.to_vec());

        // Validate migrations in debug builds
        #[cfg(debug_assertions)]
        migrations.validate().expect("Invalid migrations");

        // Get current version before migration
        let version_before: i32 =
            conn.pragma_query_value(None, "user_version", |row| row.get(0))?;
        debug!("Database version before migration: {}", version_before);

        // Apply any pending migrations
        migrations.to_latest(&mut conn)?;

        // Get version after migration
        let version_after: i32 = conn.pragma_query_value(None, "user_version", |row| row.get(0))?;

        if version_after > version_before {
            info!(
                "Database migrated from version {} to {}",
                version_before, version_after
            );
        } else {
            debug!("Database already at latest version {}", version_after);
        }

        Ok(())
    }

    /// Migrate from tauri-plugin-sql's migration tracking to rusqlite_migration's.
    /// tauri-plugin-sql used a _sqlx_migrations table, while rusqlite_migration uses
    /// SQLite's user_version pragma. This function checks if the old system was in use
    /// and sets the user_version accordingly so migrations don't re-run.
    fn migrate_from_tauri_plugin_sql(&self, conn: &Connection) -> Result<()> {
        // Check if the old _sqlx_migrations table exists
        let has_sqlx_migrations: bool = conn
            .query_row(
                "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='_sqlx_migrations'",
                [],
                |row| row.get(0),
            )
            .unwrap_or(false);

        if !has_sqlx_migrations {
            return Ok(());
        }

        // Check current user_version
        let current_version: i32 =
            conn.pragma_query_value(None, "user_version", |row| row.get(0))?;

        if current_version > 0 {
            // Already migrated to rusqlite_migration system
            return Ok(());
        }

        // Get the highest version from the old migrations table
        let old_version: i32 = conn
            .query_row(
                "SELECT COALESCE(MAX(version), 0) FROM _sqlx_migrations WHERE success = 1",
                [],
                |row| row.get(0),
            )
            .unwrap_or(0);

        if old_version > 0 {
            info!(
                "Migrating from tauri-plugin-sql (version {}) to rusqlite_migration",
                old_version
            );

            // Set user_version to match the old migration state
            conn.pragma_update(None, "user_version", old_version)?;

            // Optionally drop the old migrations table (keeping it doesn't hurt)
            // conn.execute("DROP TABLE IF EXISTS _sqlx_migrations", [])?;

            info!(
                "Migration tracking converted: user_version set to {}",
                old_version
            );
        }

        Ok(())
    }

    fn get_connection(&self) -> Result<Connection> {
        Ok(Connection::open(&self.db_path)?)
    }

    fn map_history_entry(row: &rusqlite::Row<'_>) -> rusqlite::Result<HistoryEntry> {
        Ok(HistoryEntry {
            id: row.get("id")?,
            file_name: row.get("file_name")?,
            timestamp: row.get("timestamp")?,
            saved: row.get("saved")?,
            title: row.get("title")?,
            transcription_text: row.get("transcription_text")?,
            post_processed_text: row.get("post_processed_text")?,
            post_process_prompt: row.get("post_process_prompt")?,
            post_process_requested: row.get("post_process_requested")?,
            duration_ms: row.get("duration_ms")?,
            char_count: row.get("char_count")?,
            workflow: row.get("workflow")?,
        })
    }

    pub fn recordings_dir(&self) -> &std::path::Path {
        &self.recordings_dir
    }

    /// Save a new history entry to the database.
    /// The WAV file should already have been written to the recordings directory.
    #[allow(clippy::too_many_arguments)]
    pub fn save_entry(
        &self,
        file_name: String,
        transcription_text: String,
        post_process_requested: bool,
        post_processed_text: Option<String>,
        post_process_prompt: Option<String>,
        duration_ms: i64,
        char_count: i64,
        workflow: &str,
    ) -> Result<HistoryEntry> {
        let timestamp = Utc::now().timestamp();
        let title = self.format_timestamp_title(timestamp);

        let conn = self.get_connection()?;
        conn.execute(
            "INSERT INTO transcription_history (
                file_name,
                timestamp,
                saved,
                title,
                transcription_text,
                post_processed_text,
                post_process_prompt,
                post_process_requested,
                duration_ms,
                char_count,
                workflow
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
            params![
                &file_name,
                timestamp,
                false,
                &title,
                &transcription_text,
                &post_processed_text,
                &post_process_prompt,
                post_process_requested,
                duration_ms,
                char_count,
                workflow,
            ],
        )?;

        let entry = HistoryEntry {
            id: conn.last_insert_rowid(),
            file_name,
            timestamp,
            saved: false,
            title,
            transcription_text,
            post_processed_text,
            post_process_prompt,
            post_process_requested,
            duration_ms,
            char_count,
            workflow: workflow.to_string(),
        };

        debug!("Saved history entry with id {}", entry.id);

        self.cleanup_old_entries()?;

        // Emit typed event for real-time frontend updates
        if let Ok(payload) = serde_json::to_value(HistoryUpdatePayload::Added {
            entry: entry.clone(),
        }) {
            crate::events::emit("history-update-payload", payload);
        }

        Ok(entry)
    }

    /// Record the token spend of one LLM request, for the dashboard.
    pub fn record_llm_usage(
        &self,
        provider_id: &str,
        model: &str,
        workflow: &str,
        usage: crate::llm_client::Usage,
    ) -> Result<()> {
        let conn = self.get_connection()?;
        conn.execute(
            "INSERT INTO llm_usage (
                timestamp, provider_id, model, workflow,
                prompt_tokens, completion_tokens, total_tokens
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                Utc::now().timestamp(),
                provider_id,
                model,
                workflow,
                usage.prompt_tokens,
                usage.completion_tokens,
                usage.total_tokens,
            ],
        )?;
        Ok(())
    }

    /// All aggregates the dashboard needs, in a few queries. Day boundaries use
    /// the machine's local timezone (via SQLite's `localtime`).
    pub fn stats_snapshot(&self) -> Result<HistoryStats> {
        let conn = self.get_connection()?;
        let mut stats = HistoryStats::default();

        let (total_recordings, total_dictation_ms, total_chars, translation_count): (
            i64,
            i64,
            i64,
            i64,
        ) = conn.query_row(
            "SELECT COUNT(*),
                    COALESCE(SUM(duration_ms), 0),
                    COALESCE(SUM(char_count), 0),
                    COALESCE(SUM(CASE WHEN workflow = 'translate' THEN 1 ELSE 0 END), 0)
             FROM transcription_history",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )?;
        stats.total_recordings = total_recordings.max(0) as u64;
        stats.total_dictation_ms = total_dictation_ms.max(0) as u64;
        stats.total_chars = total_chars.max(0) as u64;
        stats.translation_count = translation_count.max(0) as u64;

        let today_start: i64 = conn.query_row(
            "SELECT CAST(strftime('%s', 'now', 'localtime', 'start of day') AS INTEGER)",
            [],
            |row| row.get(0),
        )?;

        let (today_recordings, today_dictation_ms, today_chars, today_translations): (
            i64,
            i64,
            i64,
            i64,
        ) = conn.query_row(
            "SELECT COUNT(*),
                    COALESCE(SUM(duration_ms), 0),
                    COALESCE(SUM(char_count), 0),
                    COALESCE(SUM(CASE WHEN workflow = 'translate' THEN 1 ELSE 0 END), 0)
             FROM transcription_history
             WHERE timestamp >= ?1",
            params![today_start],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )?;
        stats.today_recordings = today_recordings.max(0) as u64;
        stats.today_dictation_ms = today_dictation_ms.max(0) as u64;
        stats.today_chars = today_chars.max(0) as u64;
        stats.today_translations = today_translations.max(0) as u64;

        // Last 7 local days (including empty ones), oldest first.
        let week_start = today_start - 6 * 86_400;
        let mut weekly_stmt = conn.prepare(
            "WITH RECURSIVE days(d) AS (
                 SELECT date(?1, 'unixepoch', 'localtime')
                 UNION ALL
                 SELECT date(d, '+1 day') FROM days WHERE d < date('now', 'localtime')
             )
             SELECT strftime('%m-%d', days.d), COALESCE(counts.cnt, 0)
             FROM days
             LEFT JOIN (
                 SELECT date(timestamp, 'unixepoch', 'localtime') AS day, COUNT(*) AS cnt
                 FROM transcription_history GROUP BY day
             ) AS counts ON counts.day = days.d
             ORDER BY days.d",
        )?;
        stats.weekly = weekly_stmt
            .query_map(params![week_start], |row| {
                Ok(DailyCount {
                    day: row.get(0)?,
                    count: row.get::<_, i64>(1)?.max(0) as u64,
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;

        let mut recent_stmt = conn.prepare(
            "SELECT id, timestamp, workflow, char_count,
                    CASE WHEN post_processed_text IS NOT NULL AND post_processed_text != ''
                         THEN post_processed_text ELSE transcription_text END
             FROM transcription_history
             WHERE transcription_text != ''
             ORDER BY timestamp DESC
             LIMIT ?1",
        )?;
        stats.recent = recent_stmt
            .query_map(params![RECENT_ACTIVITY_LIMIT], |row| {
                let text: String = row.get(4)?;
                Ok(RecentActivity {
                    id: row.get(0)?,
                    timestamp: row.get(1)?,
                    workflow: row.get(2)?,
                    char_count: row.get(3)?,
                    preview: preview_of(&text),
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;

        stats.tokens_today = Self::token_usage_since(&conn, today_start)?;
        stats.tokens_week = Self::token_usage_since(&conn, week_start)?;

        Ok(stats)
    }

    fn token_usage_since(conn: &Connection, since: i64) -> Result<TokenUsage> {
        let usage = conn.query_row(
            "SELECT COALESCE(SUM(prompt_tokens), 0),
                    COALESCE(SUM(completion_tokens), 0),
                    COALESCE(SUM(total_tokens), 0),
                    COUNT(*)
             FROM llm_usage WHERE timestamp >= ?1",
            params![since],
            |row| {
                Ok(TokenUsage {
                    prompt_tokens: row.get::<_, i64>(0)?.max(0) as u64,
                    completion_tokens: row.get::<_, i64>(1)?.max(0) as u64,
                    total_tokens: row.get::<_, i64>(2)?.max(0) as u64,
                    requests: row.get::<_, i64>(3)?.max(0) as u64,
                })
            },
        )?;
        Ok(usage)
    }

    /// Update an existing history entry with new transcription results (used by retry).
    pub fn update_transcription(
        &self,
        id: i64,
        transcription_text: String,
        post_processed_text: Option<String>,
        post_process_prompt: Option<String>,
    ) -> Result<HistoryEntry> {
        let conn = self.get_connection()?;
        let updated = conn.execute(
            "UPDATE transcription_history
             SET transcription_text = ?1,
                 post_processed_text = ?2,
                 post_process_prompt = ?3
             WHERE id = ?4",
            params![
                transcription_text,
                post_processed_text,
                post_process_prompt,
                id
            ],
        )?;

        if updated == 0 {
            return Err(anyhow!("History entry {} not found", id));
        }

        let entry = conn
            .query_row(
                "SELECT id, file_name, timestamp, saved, title, transcription_text, post_processed_text, post_process_prompt, post_process_requested, duration_ms, char_count, workflow
                 FROM transcription_history WHERE id = ?1",
                params![id],
                Self::map_history_entry,
            )?;

        debug!("Updated transcription for history entry {}", id);

        if let Ok(payload) = serde_json::to_value(HistoryUpdatePayload::Updated {
            entry: entry.clone(),
        }) {
            crate::events::emit("history-update-payload", payload);
        }

        Ok(entry)
    }

    pub fn cleanup_old_entries(&self) -> Result<()> {
        let retention_period = crate::settings::recording_retention_period();

        match retention_period {
            crate::settings::RecordingRetentionPeriod::Never => {
                // Don't delete anything
                Ok(())
            }
            crate::settings::RecordingRetentionPeriod::PreserveLimit => {
                // Use the old count-based logic with history_limit
                let limit = crate::settings::history_limit();
                self.cleanup_by_count(limit)
            }
            _ => {
                // Use time-based logic
                self.cleanup_by_time(retention_period)
            }
        }
    }

    fn delete_entries_and_files(&self, entries: &[(i64, String)]) -> Result<usize> {
        if entries.is_empty() {
            return Ok(0);
        }

        let conn = self.get_connection()?;
        let mut deleted_count = 0;

        for (id, file_name) in entries {
            // Delete database entry
            conn.execute(
                "DELETE FROM transcription_history WHERE id = ?1",
                params![id],
            )?;

            // Delete WAV file
            let file_path = self.recordings_dir.join(file_name);
            if file_path.exists() {
                if let Err(e) = fs::remove_file(&file_path) {
                    error!("Failed to delete WAV file {}: {}", file_name, e);
                } else {
                    debug!("Deleted old WAV file: {}", file_name);
                    deleted_count += 1;
                }
            }
        }

        Ok(deleted_count)
    }

    fn cleanup_by_count(&self, limit: usize) -> Result<()> {
        let conn = self.get_connection()?;

        // Get all entries that are not saved, ordered by timestamp desc
        let mut stmt = conn.prepare(
            "SELECT id, file_name FROM transcription_history WHERE saved = 0 ORDER BY timestamp DESC"
        )?;

        let rows = stmt.query_map([], |row| {
            Ok((row.get::<_, i64>("id")?, row.get::<_, String>("file_name")?))
        })?;

        let mut entries: Vec<(i64, String)> = Vec::new();
        for row in rows {
            entries.push(row?);
        }

        if entries.len() > limit {
            let entries_to_delete = &entries[limit..];
            let deleted_count = self.delete_entries_and_files(entries_to_delete)?;

            if deleted_count > 0 {
                debug!("Cleaned up {} old history entries by count", deleted_count);
            }
        }

        Ok(())
    }

    fn cleanup_by_time(
        &self,
        retention_period: crate::settings::RecordingRetentionPeriod,
    ) -> Result<()> {
        let conn = self.get_connection()?;

        // Calculate cutoff timestamp (current time minus retention period)
        let now = Utc::now().timestamp();
        let cutoff_timestamp = match retention_period {
            crate::settings::RecordingRetentionPeriod::Days3 => now - (3 * 24 * 60 * 60), // 3 days in seconds
            crate::settings::RecordingRetentionPeriod::Weeks2 => now - (2 * 7 * 24 * 60 * 60), // 2 weeks in seconds
            crate::settings::RecordingRetentionPeriod::Month1 => now - (30 * 24 * 60 * 60), // 1 month in seconds (approximate)
            crate::settings::RecordingRetentionPeriod::Months3 => now - (3 * 30 * 24 * 60 * 60), // 3 months in seconds (approximate)
            _ => unreachable!("Should not reach here"),
        };

        // Get all unsaved entries older than the cutoff timestamp
        let mut stmt = conn.prepare(
            "SELECT id, file_name FROM transcription_history WHERE saved = 0 AND timestamp < ?1",
        )?;

        let rows = stmt.query_map(params![cutoff_timestamp], |row| {
            Ok((row.get::<_, i64>("id")?, row.get::<_, String>("file_name")?))
        })?;

        let mut entries_to_delete: Vec<(i64, String)> = Vec::new();
        for row in rows {
            entries_to_delete.push(row?);
        }

        let deleted_count = self.delete_entries_and_files(&entries_to_delete)?;

        if deleted_count > 0 {
            debug!(
                "Cleaned up {} old history entries based on retention period",
                deleted_count
            );
        }

        Ok(())
    }

    pub async fn get_history_entries(
        &self,
        cursor: Option<i64>,
        limit: Option<usize>,
    ) -> Result<PaginatedHistory> {
        let conn = self.get_connection()?;
        let limit = limit.map(|l| l.min(100));

        let mut entries: Vec<HistoryEntry> = match (cursor, limit) {
            (Some(cursor_id), Some(lim)) => {
                let fetch_count = (lim + 1) as i64;
                let mut stmt = conn.prepare(
                    "SELECT id, file_name, timestamp, saved, title, transcription_text, post_processed_text, post_process_prompt, post_process_requested, duration_ms, char_count, workflow
                     FROM transcription_history
                     WHERE id < ?1
                     ORDER BY id DESC
                     LIMIT ?2",
                )?;
                let result = stmt
                    .query_map(params![cursor_id, fetch_count], Self::map_history_entry)?
                    .collect::<std::result::Result<Vec<_>, _>>()?;
                result
            }
            (None, Some(lim)) => {
                let fetch_count = (lim + 1) as i64;
                let mut stmt = conn.prepare(
                    "SELECT id, file_name, timestamp, saved, title, transcription_text, post_processed_text, post_process_prompt, post_process_requested, duration_ms, char_count, workflow
                     FROM transcription_history
                     ORDER BY id DESC
                     LIMIT ?1",
                )?;
                let result = stmt
                    .query_map(params![fetch_count], Self::map_history_entry)?
                    .collect::<std::result::Result<Vec<_>, _>>()?;
                result
            }
            (_, None) => {
                let mut stmt = conn.prepare(
                    "SELECT id, file_name, timestamp, saved, title, transcription_text, post_processed_text, post_process_prompt, post_process_requested, duration_ms, char_count, workflow
                     FROM transcription_history
                     ORDER BY id DESC",
                )?;
                let result = stmt
                    .query_map([], Self::map_history_entry)?
                    .collect::<std::result::Result<Vec<_>, _>>()?;
                result
            }
        };

        let has_more = limit.is_some_and(|lim| entries.len() > lim);
        if has_more {
            entries.pop();
        }

        Ok(PaginatedHistory { entries, has_more })
    }

    #[cfg(test)]
    fn get_latest_entry_with_conn(conn: &Connection) -> Result<Option<HistoryEntry>> {
        let mut stmt = conn.prepare(
            "SELECT
                id,
                file_name,
                timestamp,
                saved,
                title,
                transcription_text,
                post_processed_text,
                post_process_prompt,
                post_process_requested, duration_ms, char_count, workflow
             FROM transcription_history
             ORDER BY timestamp DESC
             LIMIT 1",
        )?;

        let entry = stmt.query_row([], Self::map_history_entry).optional()?;
        Ok(entry)
    }

    /// Get the latest entry with non-empty transcription text.
    pub fn get_latest_completed_entry(&self) -> Result<Option<HistoryEntry>> {
        let conn = self.get_connection()?;
        Self::get_latest_completed_entry_with_conn(&conn)
    }

    fn get_latest_completed_entry_with_conn(conn: &Connection) -> Result<Option<HistoryEntry>> {
        let mut stmt = conn.prepare(
            "SELECT
                id,
                file_name,
                timestamp,
                saved,
                title,
                transcription_text,
                post_processed_text,
                post_process_prompt,
                post_process_requested, duration_ms, char_count, workflow
             FROM transcription_history
             WHERE transcription_text != ''
             ORDER BY timestamp DESC
             LIMIT 1",
        )?;

        let entry = stmt.query_row([], Self::map_history_entry).optional()?;
        Ok(entry)
    }

    pub async fn toggle_saved_status(&self, id: i64) -> Result<()> {
        let conn = self.get_connection()?;

        // Get current saved status
        let current_saved: bool = conn.query_row(
            "SELECT saved FROM transcription_history WHERE id = ?1",
            params![id],
            |row| row.get("saved"),
        )?;

        let new_saved = !current_saved;

        conn.execute(
            "UPDATE transcription_history SET saved = ?1 WHERE id = ?2",
            params![new_saved, id],
        )?;

        debug!("Toggled saved status for entry {}: {}", id, new_saved);

        // Emit history updated event
        if let Ok(payload) = serde_json::to_value(HistoryUpdatePayload::Toggled { id }) {
            crate::events::emit("history-update-payload", payload);
        }

        Ok(())
    }

    pub fn get_audio_file_path(&self, file_name: &str) -> PathBuf {
        self.recordings_dir.join(file_name)
    }

    pub async fn get_entry_by_id(&self, id: i64) -> Result<Option<HistoryEntry>> {
        let conn = self.get_connection()?;
        let mut stmt = conn.prepare(
            "SELECT
                id,
                file_name,
                timestamp,
                saved,
                title,
                transcription_text,
                post_processed_text,
                post_process_prompt,
                post_process_requested, duration_ms, char_count, workflow
             FROM transcription_history
             WHERE id = ?1",
        )?;

        let entry = stmt.query_row([id], Self::map_history_entry).optional()?;

        Ok(entry)
    }

    pub async fn delete_entry(&self, id: i64) -> Result<()> {
        let conn = self.get_connection()?;

        // Get the entry to find the file name
        if let Some(entry) = self.get_entry_by_id(id).await? {
            // Delete the audio file first
            let file_path = self.get_audio_file_path(&entry.file_name);
            if file_path.exists() {
                if let Err(e) = fs::remove_file(&file_path) {
                    error!("Failed to delete audio file {}: {}", entry.file_name, e);
                    // Continue with database deletion even if file deletion fails
                }
            }
        }

        // Delete from database
        conn.execute(
            "DELETE FROM transcription_history WHERE id = ?1",
            params![id],
        )?;

        debug!("Deleted history entry with id: {}", id);

        // Emit history updated event
        if let Ok(payload) = serde_json::to_value(HistoryUpdatePayload::Deleted { id }) {
            crate::events::emit("history-update-payload", payload);
        }

        Ok(())
    }

    fn format_timestamp_title(&self, timestamp: i64) -> String {
        if let Some(utc_datetime) = DateTime::from_timestamp(timestamp, 0) {
            // Convert UTC to local timezone
            let local_datetime = utc_datetime.with_timezone(&Local);
            local_datetime.format("%B %e, %Y - %l:%M%p").to_string()
        } else {
            format!("Recording {}", timestamp)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::{params, Connection};

    fn setup_conn() -> Connection {
        let conn = Connection::open_in_memory().expect("open in-memory db");
        conn.execute_batch(
            "CREATE TABLE transcription_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                file_name TEXT NOT NULL,
                timestamp INTEGER NOT NULL,
                saved BOOLEAN NOT NULL DEFAULT 0,
                title TEXT NOT NULL,
                transcription_text TEXT NOT NULL,
                post_processed_text TEXT,
                post_process_prompt TEXT,
                post_process_requested BOOLEAN NOT NULL DEFAULT 0,
                duration_ms INTEGER NOT NULL DEFAULT 0,
                char_count INTEGER NOT NULL DEFAULT 0,
                workflow TEXT NOT NULL DEFAULT 'dictation'
            );
            CREATE TABLE llm_usage (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp INTEGER NOT NULL,
                provider_id TEXT NOT NULL,
                model TEXT NOT NULL,
                workflow TEXT NOT NULL,
                prompt_tokens INTEGER NOT NULL DEFAULT 0,
                completion_tokens INTEGER NOT NULL DEFAULT 0,
                total_tokens INTEGER NOT NULL DEFAULT 0
            );",
        )
        .expect("create transcription_history table");
        conn
    }

    fn insert_entry(conn: &Connection, timestamp: i64, text: &str, post_processed: Option<&str>) {
        conn.execute(
            "INSERT INTO transcription_history (
                file_name,
                timestamp,
                saved,
                title,
                transcription_text,
                post_processed_text,
                post_process_prompt,
                post_process_requested
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                format!("handy-{}.wav", timestamp),
                timestamp,
                false,
                format!("Recording {}", timestamp),
                text,
                post_processed,
                Option::<String>::None,
                false,
            ],
        )
        .expect("insert history entry");
    }

    #[test]
    fn get_latest_entry_returns_none_when_empty() {
        let conn = setup_conn();
        let entry = HistoryManager::get_latest_entry_with_conn(&conn).expect("fetch latest entry");
        assert!(entry.is_none());
    }

    #[test]
    fn get_latest_entry_returns_newest_entry() {
        let conn = setup_conn();
        insert_entry(&conn, 100, "first", None);
        insert_entry(&conn, 200, "second", Some("processed"));

        let entry = HistoryManager::get_latest_entry_with_conn(&conn)
            .expect("fetch latest entry")
            .expect("entry exists");

        assert_eq!(entry.timestamp, 200);
        assert_eq!(entry.transcription_text, "second");
        assert_eq!(entry.post_processed_text.as_deref(), Some("processed"));
    }

    #[test]
    fn get_latest_completed_entry_skips_empty_entries() {
        let conn = setup_conn();
        insert_entry(&conn, 100, "completed", None);
        insert_entry(&conn, 200, "", None);

        let entry = HistoryManager::get_latest_completed_entry_with_conn(&conn)
            .expect("fetch latest completed entry")
            .expect("completed entry exists");

        assert_eq!(entry.timestamp, 100);
        assert_eq!(entry.transcription_text, "completed");
    }
}
