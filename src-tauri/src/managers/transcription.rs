//! Tauri-facing re-export of [`talkwtf_core::transcription`], plus specta
//! mirrors of its streaming events (type generation only).

use serde::{Deserialize, Serialize};
use specta::Type;

pub use talkwtf_core::transcription::*;

/// Specta/Tauri mirror of the core's stream-phase event.
#[derive(Clone, Debug, Serialize, Deserialize, Type, tauri_specta::Event)]
pub struct StreamPhaseEvent {
    pub phase: StreamPhase,
    pub kind: Option<StreamWorkKind>,
}

/// Specta/Tauri mirror of the core's stream-text event.
#[derive(Clone, Debug, Serialize, Deserialize, Type, tauri_specta::Event)]
pub struct StreamTextEvent {
    pub committed: String,
    pub tentative: String,
}
