//! Tauri-facing re-export of [`talkwtf_core::history`], plus the specta mirror
//! of its update event.
//!
//! The manager lives in the core and pushes `history-update-payload` JSON
//! through the core event sink. This module re-declares the payload only so
//! `collect_events!` can export the TypeScript event type; it must stay in sync
//! with `talkwtf_core::history::HistoryUpdatePayload`.

use serde::{Deserialize, Serialize};
use specta::Type;

pub use talkwtf_core::history::*;

/// Specta/Tauri mirror of the core's update payload (type generation only).
#[derive(Clone, Debug, Serialize, Deserialize, Type, tauri_specta::Event)]
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
