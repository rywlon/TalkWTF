//! Tauri-facing re-export of [`talkwtf_core::learning`], plus the specta mirror
//! of its learned-correction event.
//!
//! The watcher lives in the core and emits `learned-correction` /
//! `learned-overlay` JSON through the core event sink. The mirror below exists
//! only so `collect_events!` can export the TypeScript event type.

use serde::{Deserialize, Serialize};
use specta::Type;

pub use talkwtf_core::learning::*;

/// Specta/Tauri mirror of the core's correction event (type generation only).
#[cfg(target_os = "macos")]
#[derive(Clone, Debug, Serialize, Deserialize, Type, tauri_specta::Event)]
pub struct LearnedCorrection {
    pub pattern: String,
    pub replacement: String,
    pub count: u32,
}
