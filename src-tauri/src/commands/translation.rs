//! Translate-workflow commands. Currently just the retry the overlay's failure
//! card offers: the pipeline keeps the last failed transcript in a single slot
//! (see `actions::FailedTranslation`) so it can be re-run without the user
//! having to speak again.

use crate::actions::{self, ProcessingMode};
use crate::overlay;
use crate::tray::{set_tray_state, TrayIconState};
use crate::utils;
use log::error;
use tauri::AppHandle;

/// Re-run the most recent failed translation and paste the result. On failure
/// the slot is restored so the retry button keeps working.
#[tauri::command]
#[specta::specta]
pub async fn retry_last_translation(app: AppHandle) -> Result<(), String> {
    let Some(failure) = actions::take_failed_translation() else {
        return Err("No failed translation to retry".to_string());
    };

    overlay::show_translating_overlay(&app, &failure.label);

    let processed = actions::process_transcription_output(
        &app,
        &failure.transcription,
        ProcessingMode::Translate,
    )
    .await;

    if processed.translation_failed || processed.final_text.trim().is_empty() {
        error!(
            "Retried translation failed again (target: {})",
            failure.label
        );
        actions::store_failed_translation(failure.clone());
        overlay::show_translation_failed_overlay(&app, &failure.label);
        return Err("Translation failed again".to_string());
    }

    let final_text = processed.final_text;
    let ah = app.clone();
    app.run_on_main_thread(move || match utils::paste(final_text, ah.clone()) {
        Ok(()) => {
            utils::hide_recording_overlay(&ah);
            set_tray_state(&ah, TrayIconState::Idle);
        }
        Err(e) => error!("Failed to paste retried translation: {}", e),
    })
    .map_err(|e| format!("Failed to run paste on main thread: {e}"))?;

    Ok(())
}
