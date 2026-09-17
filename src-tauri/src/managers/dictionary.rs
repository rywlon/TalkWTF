//! Tauri-facing re-export of [`talkwtf_core::dictionary`].
//!
//! The store itself lives in the core (no Tauri dependency); the legacy Tauri
//! shell keeps importing it through this path.

pub use talkwtf_core::dictionary::*;
