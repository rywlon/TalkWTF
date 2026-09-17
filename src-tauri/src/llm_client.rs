//! Tauri-facing re-export of [`talkwtf_core::llm_client`].
//!
//! The provider client (BYOK chat completions, model listing) lives in the core
//! so both shells share it.

pub use talkwtf_core::llm_client::*;
