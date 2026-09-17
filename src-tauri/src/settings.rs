//! Tauri adapter over [`talkwtf_core::settings`].
//!
//! The core crate owns the data model and the store file (`settings_store.json`
//! in the app data dir). This module keeps the `AppHandle`-taking API the rest
//! of the Tauri shell was written against, so both shells — the legacy Tauri
//! app and the SwiftUI app via `talkwtf-ffi` — share one implementation.

use std::collections::HashMap;
use tauri::AppHandle;

pub use talkwtf_core::settings::*;

/// Load (creating/migrating as needed) the settings for the running app.
pub fn load_or_create_app_settings(_app: &AppHandle) -> AppSettings {
    talkwtf_core::settings::load_or_create()
}

pub fn get_settings(_app: &AppHandle) -> AppSettings {
    talkwtf_core::settings::current()
}

pub fn write_settings(_app: &AppHandle, settings: AppSettings) {
    talkwtf_core::settings::store(settings);
}

pub fn get_bindings(_app: &AppHandle) -> HashMap<String, ShortcutBinding> {
    talkwtf_core::settings::bindings()
}

pub fn get_stored_binding(_app: &AppHandle, id: &str) -> ShortcutBinding {
    talkwtf_core::settings::stored_binding(id)
}

pub fn get_history_limit(_app: &AppHandle) -> usize {
    talkwtf_core::settings::history_limit()
}

pub fn get_recording_retention_period(_app: &AppHandle) -> RecordingRetentionPeriod {
    talkwtf_core::settings::recording_retention_period()
}

/// Map the core's log level onto the Tauri log plugin's enum. Kept here (not as
/// a `From` impl) because the target type belongs to a Tauri crate the core
/// must not depend on.
pub fn to_tauri_log_level(level: LogLevel) -> tauri_plugin_log::LogLevel {
    match level {
        LogLevel::Trace => tauri_plugin_log::LogLevel::Trace,
        LogLevel::Debug => tauri_plugin_log::LogLevel::Debug,
        LogLevel::Info => tauri_plugin_log::LogLevel::Info,
        LogLevel::Warn => tauri_plugin_log::LogLevel::Warn,
        LogLevel::Error => tauri_plugin_log::LogLevel::Error,
    }
}
