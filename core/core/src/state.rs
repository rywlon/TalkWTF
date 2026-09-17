//! Shared core state.
//!
//! The Tauri shell keeps its managers in Tauri-managed state; the core has no
//! such container, so the few singletons the core modules need (the dictionary
//! store, the edit-learning state) live here and are registered by whichever
//! shell boots the core.

use std::sync::{Arc, OnceLock};

use crate::audio::AudioRecordingManager;
use crate::dictionary::DictionaryStore;
use crate::history::HistoryManager;
use crate::model::ModelManager;
use crate::transcription::TranscriptionManager;

static DICTIONARY_STORE: OnceLock<Arc<DictionaryStore>> = OnceLock::new();

/// Register the process-wide dictionary store. Call once at startup.
pub fn set_dictionary_store(store: Arc<DictionaryStore>) {
    let _ = DICTIONARY_STORE.set(store);
}

/// The dictionary store, if the shell registered one.
pub fn dictionary_store() -> Option<Arc<DictionaryStore>> {
    DICTIONARY_STORE.get().cloned()
}

static AUDIO_MANAGER: OnceLock<std::sync::Weak<AudioRecordingManager>> = OnceLock::new();

/// Register a weak handle to the audio manager (the shell owns the strong one).
pub fn set_audio_manager(manager: &Arc<AudioRecordingManager>) {
    let _ = AUDIO_MANAGER.set(Arc::downgrade(manager));
}

/// The audio manager, if it is still alive.
pub fn audio_manager() -> Option<Arc<AudioRecordingManager>> {
    AUDIO_MANAGER.get().and_then(|weak| weak.upgrade())
}

static MODEL_MANAGER: OnceLock<Arc<ModelManager>> = OnceLock::new();
static TRANSCRIPTION_MANAGER: OnceLock<Arc<TranscriptionManager>> = OnceLock::new();
static HISTORY_MANAGER: OnceLock<Arc<HistoryManager>> = OnceLock::new();

/// Register the model manager. Call once at startup.
pub fn set_model_manager(manager: Arc<ModelManager>) {
    let _ = MODEL_MANAGER.set(manager);
}

/// The model manager, if the shell registered one.
pub fn model_manager() -> Option<Arc<ModelManager>> {
    MODEL_MANAGER.get().cloned()
}

/// Register the transcription manager. Call once at startup.
pub fn set_transcription_manager(manager: Arc<TranscriptionManager>) {
    let _ = TRANSCRIPTION_MANAGER.set(manager);
}

/// The transcription manager, if the shell registered one.
pub fn transcription_manager() -> Option<Arc<TranscriptionManager>> {
    TRANSCRIPTION_MANAGER.get().cloned()
}

/// Register the history manager. Call once at startup.
pub fn set_history_manager(manager: Arc<HistoryManager>) {
    let _ = HISTORY_MANAGER.set(manager);
}

/// The history manager, if the shell registered one.
pub fn history_manager() -> Option<Arc<HistoryManager>> {
    HISTORY_MANAGER.get().cloned()
}
