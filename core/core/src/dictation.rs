//! One-shot dictation: record → transcribe → polish or translate.
//!
//! The shell owns the trigger (hotkey) and the delivery (paste); this module
//! owns the engine work in between, so every shell runs the same pipeline. It
//! also drives the overlay state machine, so the panel does not have to guess
//! where in the pipeline it is.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::OnceLock;

use log::debug;

use crate::audio_toolkit::VadPolicy;
use crate::pipeline::{
    process_transcription_output, store_failed_translation, workflow_id, FailedTranslation,
    ProcessingMode,
};
use crate::settings;

/// The binding id the recorder tracks this session under.
const BINDING_ID: &str = "dictation";

/// A dictation is recording or being transcribed. Commands that would fight it
/// (re-transcribing another entry, switching models, unloading) refuse to run.
static BUSY: AtomicBool = AtomicBool::new(false);

/// The error string shells match on to show their own localized message.
pub const BUSY_ERROR: &str = "busy: a dictation is already in progress";

/// Whether a dictation is in flight.
pub fn is_busy() -> bool {
    BUSY.load(Ordering::SeqCst)
}

/// `Err(BUSY_ERROR)` when a dictation is in flight, so a command can refuse.
pub fn ensure_idle() -> Result<(), String> {
    if is_busy() {
        return Err(BUSY_ERROR.to_string());
    }
    Ok(())
}

/// Overlay states, mirroring the Tauri overlay's state machine.
pub mod overlay {
    pub const RECORDING: &str = "recording";
    pub const STREAMING: &str = "streaming";
    pub const TRANSCRIBING: &str = "transcribing";
    pub const PROCESSING: &str = "processing";
    pub const TRANSLATING: &str = "translating";
    pub const TRANSLATION_FAILED: &str = "translation_failed";
    pub const NOTICE: &str = "notice";
}

/// Tell the shell which overlay to show. `label` is the translation target,
/// `kind` disambiguates notices.
pub fn emit_overlay_state(state: &str, label: Option<&str>, kind: Option<&str>) {
    crate::events::emit(
        "overlay-state",
        serde_json::json!({ "state": state, "label": label, "kind": kind }),
    );
}

/// Run a future to completion on a small blocking runtime (the FFI is sync).
pub fn block_on<F: std::future::Future>(future: F) -> F::Output {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    let runtime = RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("failed to build tokio runtime")
    });
    runtime.block_on(future)
}

/// The translation target's display label, or `None` when translate mode has no
/// target language configured.
fn translation_label(settings: &settings::AppSettings) -> Option<String> {
    settings
        .effective_translation_target()
        .and_then(settings::translation_language_label)
        .map(str::to_string)
}

/// Start recording for `mode`. Loads the model in the background.
pub fn start(mode: ProcessingMode) -> Result<(), String> {
    let settings = settings::current();

    // Translate needs a target before it can record anything. Without one, tell
    // the user where to configure it and abort: recording speech we could never
    // translate would just waste it. Checked before the audio manager so the
    // notice still shows when the engine is not fully up yet.
    if mode == ProcessingMode::Translate && translation_label(&settings).is_none() {
        debug!("Translate shortcut pressed but no target language is configured");
        emit_overlay_state(overlay::NOTICE, None, Some("no_target"));
        return Err("no translation target language is configured".to_string());
    }

    let audio = crate::state::audio_manager()
        .ok_or_else(|| "audio manager is not initialized".to_string())?;
    let transcription = crate::state::transcription_manager()
        .ok_or_else(|| "transcription manager is not initialized".to_string())?;

    transcription.initiate_model_load();

    let model_supports_streaming = crate::state::model_manager()
        .and_then(|manager| manager.get_model_info(&settings.selected_model))
        .map(|info| info.supports_streaming)
        .unwrap_or(false);

    let vad_policy = if !settings.vad_enabled {
        VadPolicy::Disabled
    } else if model_supports_streaming {
        VadPolicy::Streaming
    } else {
        VadPolicy::Offline
    };

    if model_supports_streaming {
        transcription.start_stream();
    }

    audio
        .try_start_recording(BINDING_ID, vad_policy)
        .map_err(|e| e.to_string())?;
    BUSY.store(true, Ordering::SeqCst);

    // The live overlay only exists for streaming models; everything else uses
    // the plain recording panel.
    let style = settings.overlay_style;
    let state = if model_supports_streaming && style == settings::OverlayStyle::Live {
        overlay::STREAMING
    } else {
        overlay::RECORDING
    };
    let label = if mode == ProcessingMode::Translate {
        translation_label(&settings)
    } else {
        None
    };
    emit_overlay_state(state, label.as_deref(), None);

    Ok(())
}

/// Stop recording, transcribe, and return the final text (polished or
/// translated). `Err` when there was no audio, transcription failed, or a
/// translation could not be produced.
pub fn stop(mode: ProcessingMode) -> Result<String, String> {
    // Every return below has to release the slot, so the whole body runs inside
    // a guard rather than repeating the reset.
    let _guard = BusyGuard;

    let audio = crate::state::audio_manager()
        .ok_or_else(|| "audio manager is not initialized".to_string())?;
    let transcription = crate::state::transcription_manager()
        .ok_or_else(|| "transcription manager is not initialized".to_string())?;

    // A short recording can stop before the background load finished, and a
    // failed load would never retry: make sure one is in flight (or done) first.
    transcription.initiate_model_load();

    let cancel_generation = audio.cancel_generation();
    let samples = audio
        .stop_recording(BINDING_ID, cancel_generation)
        .ok_or_else(|| "no audio samples were captured".to_string())?;

    emit_overlay_state(overlay::TRANSCRIBING, None, None);

    // Persist the audio alongside the transcript so the entry can be played back
    // and re-transcribed later. A failure here must not lose the dictation.
    let sample_count = samples.len();
    let saved = save_recording(&samples);

    let transcription_text = match transcription.finalize_stream() {
        Ok(Some(text)) if !text.trim().is_empty() => text,
        Ok(_) => transcription
            .transcribe(samples)
            .map_err(|e| e.to_string())?,
        Err(error) => return Err(error.to_string()),
    };

    if transcription_text.trim().is_empty() {
        return Err("the recording contained no speech".to_string());
    }

    let settings = settings::current();
    let label = if mode == ProcessingMode::Translate {
        translation_label(&settings)
    } else {
        None
    };

    // Translate mode with no target: surface the notice instead of a silent
    // fallback to the raw transcript.
    if mode == ProcessingMode::Translate && label.is_none() {
        emit_overlay_state(overlay::NOTICE, None, Some("no_target"));
        return Err("no translation target language is configured".to_string());
    }

    emit_overlay_state(
        if mode == ProcessingMode::Translate {
            overlay::TRANSLATING
        } else {
            overlay::PROCESSING
        },
        label.as_deref(),
        None,
    );

    let processed = block_on(process_transcription_output(&transcription_text, mode));

    if let Some(file_name) = &saved {
        save_history_entry(
            file_name,
            &transcription_text,
            &processed,
            sample_count,
            mode,
        );
    }

    if processed.translation_failed {
        // Keep the transcript so the overlay's retry button can re-run it.
        store_failed_translation(FailedTranslation {
            transcription: transcription_text,
            label: label.clone().unwrap_or_default(),
        });
        emit_overlay_state(overlay::TRANSLATION_FAILED, label.as_deref(), None);
        return Err("translation failed".to_string());
    }
    Ok(processed.final_text)
}

/// Re-run the most recent failed translation and return the translated text.
/// The caller pastes it. On another failure the slot is restored so retry keeps
/// working.
pub fn retry_last_translation() -> Result<String, String> {
    ensure_idle()?;

    let failure = crate::pipeline::take_failed_translation()
        .ok_or_else(|| "there is no failed translation to retry".to_string())?;

    emit_overlay_state(overlay::TRANSLATING, Some(&failure.label), None);

    let processed = block_on(process_transcription_output(
        &failure.transcription,
        ProcessingMode::Translate,
    ));

    if processed.translation_failed || processed.final_text.trim().is_empty() {
        store_failed_translation(failure.clone());
        emit_overlay_state(overlay::TRANSLATION_FAILED, Some(&failure.label), None);
        return Err("translation failed again".to_string());
    }

    Ok(processed.final_text)
}

/// Re-transcribe an existing history entry from its saved audio, then re-run
/// the dictation pipeline and store the result back on the same row.
pub fn retry_history_transcription(id: i64) -> Result<(), String> {
    ensure_idle()?;

    let history = crate::state::history_manager()
        .ok_or_else(|| "history manager is not initialized".to_string())?;
    let transcription = crate::state::transcription_manager()
        .ok_or_else(|| "transcription manager is not initialized".to_string())?;

    let entry = block_on(history.get_entry_by_id(id))
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("history entry {id} not found"))?;

    let audio_path = history.get_audio_file_path(&entry.file_name);
    let samples = crate::wav::read_wav_samples(&audio_path)
        .map_err(|e| format!("failed to load audio: {e}"))?;
    if samples.is_empty() {
        return Err("the recording has no audio samples".to_string());
    }

    emit_overlay_state(overlay::TRANSCRIBING, None, None);
    transcription.initiate_model_load();

    let text = transcription
        .transcribe(samples)
        .map_err(|e| e.to_string())?;
    if text.trim().is_empty() {
        return Err("the recording contains no speech".to_string());
    }

    // Retries always re-run the full dictation pipeline: there is no
    // plain-transcribe mode any more.
    emit_overlay_state(overlay::PROCESSING, None, None);
    let processed = block_on(process_transcription_output(&text, ProcessingMode::Polish));

    history
        .update_transcription(
            id,
            text,
            processed.post_processed_text,
            processed.post_process_prompt,
        )
        .map_err(|e| e.to_string())?;

    crate::events::emit("history-update-payload", ());
    Ok(())
}

/// Write the recording to the history folder, returning its file name. `None`
/// when there is no history manager yet or the write failed.
fn save_recording(samples: &[f32]) -> Option<String> {
    let history = crate::state::history_manager()?;
    let file_name = format!("handy-{}.wav", chrono::Utc::now().timestamp());
    let path = history.recordings_dir().join(&file_name);

    if let Err(error) = crate::wav::save_wav_file(&path, samples) {
        log::error!("failed to save recording {}: {error}", path.display());
        return None;
    }
    if let Err(error) = crate::wav::verify_wav_file(&path, samples.len()) {
        log::error!("recording {} did not verify: {error}", path.display());
        return None;
    }
    Some(file_name)
}

/// Store the run in history so the library and the dashboard see it.
fn save_history_entry(
    file_name: &str,
    transcription_text: &str,
    processed: &crate::pipeline::ProcessedTranscription,
    sample_count: usize,
    mode: ProcessingMode,
) {
    let Some(history) = crate::state::history_manager() else {
        return;
    };

    let duration_ms = (sample_count as f64 / 16_000.0 * 1000.0).round() as i64;
    let char_count = transcription_text.trim().chars().count() as i64;

    match history.save_entry(
        file_name.to_string(),
        transcription_text.to_string(),
        true,
        processed.post_processed_text.clone(),
        processed.post_process_prompt.clone(),
        duration_ms,
        char_count,
        workflow_id(mode),
    ) {
        Ok(_) => crate::events::emit("history-update-payload", ()),
        Err(error) => log::error!("failed to save history entry: {error}"),
    }
}

/// Releases the busy slot however `stop` exits.
struct BusyGuard;

impl Drop for BusyGuard {
    fn drop(&mut self) {
        BUSY.store(false, Ordering::SeqCst);
    }
}

/// Cancel an in-flight recording.
pub fn cancel() {
    if let Some(audio) = crate::state::audio_manager() {
        audio.cancel_recording();
    }
    BUSY.store(false, Ordering::SeqCst);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    /// Collects the events a test triggers.
    struct RecordingSink(Arc<Mutex<Vec<(String, serde_json::Value)>>>);

    impl crate::events::EventSink for RecordingSink {
        fn emit(&self, event: &str, payload: serde_json::Value) {
            self.0.lock().unwrap().push((event.to_string(), payload));
        }
    }

    fn overlay_states(events: &[(String, serde_json::Value)]) -> Vec<String> {
        events
            .iter()
            .filter(|(name, _)| name == "overlay-state")
            .map(|(_, payload)| payload["state"].as_str().unwrap_or_default().to_string())
            .collect()
    }

    /// A completed run must leave a playable recording plus a history row, so
    /// the library and the dashboard see it. This is the regression that made
    /// both look frozen.
    #[test]
    fn a_completed_run_is_saved_to_history() {
        use crate::history::HistoryManager;
        use std::sync::Arc;

        let dir = tempfile::tempdir().unwrap();
        settings::init(dir.path().to_path_buf());

        // The settings dir is process-wide and set once, and every test shares one
        // process. If another test initialized it first, its temp dir is the one
        // in use — and it may already be deleted by the time we get here, so
        // creating a manager would fail for reasons that have nothing to do with
        // this test. Nothing meaningful to assert in that case.
        if settings::data_dir() != dir.path() {
            return;
        }

        let manager = Arc::new(HistoryManager::new().expect("history manager"));
        crate::state::set_history_manager(manager.clone());
        let Some(manager) = crate::state::history_manager() else {
            return;
        };

        let samples = vec![0.0f32; 16_000]; // one second at 16 kHz
        let file_name = save_recording(&samples).expect("recording saved");
        let processed = crate::pipeline::ProcessedTranscription {
            final_text: "你好世界".to_string(),
            post_processed_text: Some("你好，世界。".to_string()),
            post_process_prompt: Some("prompt".to_string()),
            translation_failed: false,
        };
        save_history_entry(
            &file_name,
            "你好世界",
            &processed,
            samples.len(),
            ProcessingMode::Polish,
        );

        let entry = block_on(manager.get_history_entries(None, Some(1)))
            .expect("entries")
            .entries
            .into_iter()
            .next()
            .expect("one entry");
        assert_eq!(entry.transcription_text, "你好世界");
        assert_eq!(entry.post_processed_text.as_deref(), Some("你好，世界。"));
        assert_eq!(entry.workflow, "dictation");
        assert_eq!(entry.duration_ms, 1000);
        assert_eq!(entry.char_count, 4);
        assert!(entry.file_name.ends_with(".wav"));
        assert!(
            manager.get_audio_file_path(&entry.file_name).exists(),
            "the recording must be on disk so it can be played back"
        );
    }

    /// Translate with no target must refuse to record and say why, rather than
    /// recording speech it could never translate.
    #[test]
    fn translate_without_a_target_emits_the_no_target_notice() {
        // The sink is process-wide and set once; other tests may win the race,
        // so only assert when ours is installed.
        let events = Arc::new(Mutex::new(Vec::new()));
        crate::events::set_sink(Box::new(RecordingSink(events.clone())));

        let dir = tempfile::tempdir().unwrap();
        settings::init(dir.path().to_path_buf());
        let mut current = settings::current();
        current.translation_targets = Vec::new();
        current.translation_active_target = None;
        settings::store(current);

        let result = start(ProcessingMode::Translate);
        assert!(result.is_err(), "translate without a target must not start");

        let recorded = events.lock().unwrap().clone();
        let states = overlay_states(&recorded);
        if states.is_empty() {
            // Another test installed its sink first; nothing to assert.
            return;
        }
        assert_eq!(states, vec!["notice"]);
        let notice = recorded
            .iter()
            .find(|(name, _)| name == "overlay-state")
            .map(|(_, payload)| payload.clone())
            .unwrap();
        assert_eq!(notice["kind"], "no_target");
    }
}
