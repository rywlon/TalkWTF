//! TalkWTF core.
//!
//! Everything the app needs that is not UI: settings, and (as the extraction
//! progresses) ASR, audio, LLM, dictionary, history and edit learning.
//!
//! This crate has **no Tauri dependency**. The SwiftUI app links it through
//! `talkwtf-ffi`; the legacy Tauri app re-exports it through thin adapters so
//! both shells share one implementation.

pub mod audio;
pub mod audio_toolkit;
pub mod catalog;
pub mod dashboard;
pub mod dictation;
pub mod dictionary;
pub mod dictionary_io;
pub mod engine;
pub mod events;
pub mod gguf_meta;
pub mod helpers;
pub mod history;
pub mod hotkeys;
pub mod keycodes;
pub mod languages;
pub mod learning;
pub mod llm_client;
pub mod model;
pub mod model_capabilities;
pub mod pipeline;
pub mod polish_profile;
pub mod secure_input;
pub mod settings;
pub mod state;
pub mod transcription;
pub mod util;
pub mod wav;
