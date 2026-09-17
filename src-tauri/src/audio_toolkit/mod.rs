//! Tauri-facing re-export of [`talkwtf_core::audio_toolkit`].
//!
//! Audio capture, resampling, VAD and text post-processing live in the core so
//! both shells share one implementation.

pub use talkwtf_core::audio_toolkit::*;
