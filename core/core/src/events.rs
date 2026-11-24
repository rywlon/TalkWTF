//! Event sink.
//!
//! The core needs to push events (history updated, learned corrections, overlay
//! state, …) without knowing who is hosting it. The shell installs a sink at
//! startup: the Tauri app forwards to `app.emit`, the SwiftUI app forwards to
//! the C callback registered with `talkwtf-ffi`.

use std::sync::OnceLock;

/// Where core events go.
pub trait EventSink: Send + Sync {
    fn emit(&self, event: &str, payload: serde_json::Value);
}

static SINK: OnceLock<Box<dyn EventSink>> = OnceLock::new();

/// Install the process-wide event sink. Call once at startup.
pub fn set_sink(sink: Box<dyn EventSink>) {
    let _ = SINK.set(sink);
}

/// Emit an event with a serializable payload. A no-op when no sink is installed
/// (e.g. unit tests). Generic so call sites read like the old `app.emit(name, &x)`.
pub fn emit<T: serde::Serialize>(event: &str, payload: T) {
    let Some(sink) = SINK.get() else {
        return;
    };
    let value = serde_json::to_value(payload).unwrap_or(serde_json::Value::Null);
    sink.emit(event, value);
}

/// Mic-level events are high-frequency, so they are throttled here and can be
/// switched off entirely (the shell turns them off when no overlay is shown).
static MIC_LEVELS_ENABLED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(true);
static LAST_MIC_LEVEL_EMIT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
const MIC_LEVEL_EMIT_THROTTLE_MS: u64 = 33; // ~30 FPS

/// Turn mic-level emission on/off (the shell calls this when the overlay style
/// changes). Off avoids per-frame work for a hidden overlay.
pub fn set_mic_levels_enabled(enabled: bool) {
    MIC_LEVELS_ENABLED.store(enabled, std::sync::atomic::Ordering::Relaxed);
}

/// Emit throttled microphone levels for the overlay waveform.
pub fn emit_mic_levels(levels: &[f32]) {
    use std::sync::atomic::Ordering;
    if !MIC_LEVELS_ENABLED.load(Ordering::Relaxed) {
        return;
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;
    let last = LAST_MIC_LEVEL_EMIT.load(Ordering::Relaxed);
    if now.saturating_sub(last) < MIC_LEVEL_EMIT_THROTTLE_MS {
        return;
    }
    LAST_MIC_LEVEL_EMIT.store(now, Ordering::Relaxed);
    emit("mic-level", levels);
}
