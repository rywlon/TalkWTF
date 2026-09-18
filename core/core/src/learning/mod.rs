//! Learn a dictionary entry from the edit the user makes right after dictating.
//!
//! Everything here is a no-op outside macOS: the whole mechanism depends on the
//! Accessibility API.

pub mod diff;

#[cfg(target_os = "macos")]
mod ax;
#[cfg(target_os = "macos")]
mod llm;
#[cfg(target_os = "macos")]
mod watcher;

#[cfg(target_os = "macos")]
pub use watcher::{watch_for_edit, LearnedCorrection, LearningState};

/// The process-wide learning state (the shell used to hold it in Tauri state).
#[cfg(target_os = "macos")]
static LEARNING_STATE: std::sync::OnceLock<LearningState> = std::sync::OnceLock::new();

/// Create the learning state. Call once at startup on macOS.
#[cfg(target_os = "macos")]
pub fn init_learning_state() {
    let _ = LEARNING_STATE.set(LearningState::default());
}

#[cfg(target_os = "macos")]
pub(crate) fn learning_state() -> Option<&'static LearningState> {
    LEARNING_STATE.get()
}

/// Report for the settings UI: the live accessibility state plus what the last
/// dictation's watch session actually saw. The live part alone is useless there —
/// by the time a button is clicked, focus is on our own window.
pub fn diagnose() -> Vec<String> {
    #[cfg(target_os = "macos")]
    {
        let mut lines = ax::diagnose();
        lines.push(String::new());
        lines.push("--- last dictation watch ---".to_string());

        match learning_state().and_then(|state| state.report()) {
            Some(report) => {
                lines.push(format!("outcome: {}", report.outcome));
                lines.push(format!("pasted: {} chars", report.pasted_chars));
                lines.push(format!(
                    "polls: {} ({} readable)",
                    report.polls, report.readable_polls
                ));
                lines.push(format!("bundle id at paste time: {:?}", report.bundle_id));
                if let Some(chars) = report.last_field_chars {
                    lines.push(format!("last readable field: {chars} chars"));
                }
                if let Some(preview) = report.last_field_preview {
                    lines.push(format!("last field text: {preview}"));
                }
                if let Some(candidate) = report.candidate {
                    lines.push(format!("candidate: {candidate}"));
                }
            }
            None => lines.push("no watch has run yet".to_string()),
        }

        lines
    }
    #[cfg(not(target_os = "macos"))]
    {
        Vec::new()
    }
}

/// No-op stub so the rest of the crate can manage the state on every platform.
#[cfg(not(target_os = "macos"))]
#[derive(Default)]
pub struct LearningState;

#[cfg(not(target_os = "macos"))]
pub fn watch_for_edit(_pasted_text: &str) {}

/// Consume the last applied learning so undo knows exactly what to take back.
#[cfg(target_os = "macos")]
pub fn take_applied_learning() -> Vec<(String, String)> {
    learning_state()
        .map(|state| state.take())
        .unwrap_or_default()
}

#[cfg(not(target_os = "macos"))]
pub fn take_applied_learning() -> Vec<(String, String)> {
    Vec::new()
}

/// Undo the last auto-learned correction: delete the word it added and remember
/// the misheard pattern so it is not learned again. Emits `dictionary-changed`.
pub fn undo_last_learning() -> Result<(), String> {
    let applied = take_applied_learning();
    if applied.is_empty() {
        return Err("Nothing to undo".to_string());
    }

    let store = crate::state::dictionary_store()
        .ok_or_else(|| "dictionary store is not initialized".to_string())?;
    for (word, pattern) in applied {
        store.undo_learned_word(&word).map_err(|e| e.to_string())?;
        store
            .remember_learning_rejection(&pattern)
            .map_err(|e| e.to_string())?;
    }

    crate::events::emit("dictionary-changed", serde_json::json!({}));
    Ok(())
}

/// Whether the process may use the Accessibility API (macOS). The shell uses
/// this to gate the permission prompt and the auto-learn toggle.
#[cfg(target_os = "macos")]
pub fn is_accessibility_trusted() -> bool {
    ax::is_trusted()
}

#[cfg(not(target_os = "macos"))]
pub fn is_accessibility_trusted() -> bool {
    false
}
