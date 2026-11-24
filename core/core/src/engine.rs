//! Builds the core engine: the managers the app needs, constructed without any
//! shell. Used by the FFI host (the SwiftUI app); the Tauri shell constructs
//! its own and registers them in [`crate::state`] instead.

use std::sync::Arc;

use crate::audio::AudioRecordingManager;
use crate::dictionary::DictionaryStore;
use crate::history::HistoryManager;
use crate::model::ModelManager;
use crate::transcription::TranscriptionManager;

/// Construct and register every manager. Idempotent enough for a single call at
/// startup: later calls reuse whatever is already registered.
pub fn init() -> anyhow::Result<()> {
    let model_manager = match crate::state::model_manager() {
        Some(manager) => manager,
        None => {
            let manager = Arc::new(ModelManager::new()?);
            crate::state::set_model_manager(manager.clone());
            manager
        }
    };

    let transcription_manager = match crate::state::transcription_manager() {
        Some(manager) => manager,
        None => {
            let manager = Arc::new(TranscriptionManager::new(model_manager.clone())?);
            crate::state::set_transcription_manager(manager.clone());
            manager
        }
    };

    let audio_manager = match crate::state::audio_manager() {
        Some(manager) => manager,
        None => {
            let manager = Arc::new(AudioRecordingManager::new(
                transcription_manager.stream_router(),
            )?);
            crate::state::set_audio_manager(manager.clone());
            manager
        }
    };
    let _ = audio_manager;

    let history_manager = match crate::state::history_manager() {
        Some(manager) => manager,
        None => {
            let manager = Arc::new(HistoryManager::new()?);
            crate::state::set_history_manager(manager.clone());
            manager
        }
    };
    let _ = history_manager;

    if crate::state::dictionary_store().is_none() {
        let store = Arc::new(DictionaryStore::new()?);
        crate::state::set_dictionary_store(store);
    }

    // The edit watcher and the dictionary undo both hang off this state; without
    // it a learned correction can neither be remembered nor undone.
    crate::learning::init_learning_state();

    crate::transcription::apply_accelerator_settings();
    crate::transcription::init_transcribe_backend();

    Ok(())
}
