//! Learn a dictionary entry from the edit the user makes right after dictating.
//!
//! Everything here is a no-op outside macOS: the whole mechanism depends on the
//! Accessibility API.

pub mod diff;

#[cfg(target_os = "macos")]
mod ax;
#[cfg(target_os = "macos")]
mod watcher;

#[cfg(target_os = "macos")]
pub use watcher::{watch_for_edit, LearnedCorrection, LearningState};

/// Report for the settings UI: the live accessibility state plus what the last
/// dictation's watch session actually saw. The live part alone is useless there —
/// by the time a button is clicked, focus is on our own window.
pub fn diagnose(app: &tauri::AppHandle) -> Vec<String> {
    #[cfg(target_os = "macos")]
    {
        use tauri::Manager;

        let mut lines = ax::diagnose();
        lines.push(String::new());
        lines.push("--- last dictation watch ---".to_string());

        match app
            .try_state::<LearningState>()
            .and_then(|state| state.report())
        {
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
        let _ = app;
        Vec::new()
    }
}

/// No-op stub so the rest of the crate can manage the state on every platform.
#[cfg(not(target_os = "macos"))]
#[derive(Default)]
pub struct LearningState;

#[cfg(not(target_os = "macos"))]
pub fn watch_for_edit(_app: &tauri::AppHandle, _pasted_text: &str) {}
