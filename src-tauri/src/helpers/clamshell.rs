//! Tauri command wrappers over [`talkwtf_core::helpers::clamshell`].

pub use talkwtf_core::helpers::clamshell::is_clamshell;

/// True when the machine has a battery (i.e. a laptop). Exposed to the
/// frontend as a command.
#[tauri::command]
#[specta::specta]
pub fn is_laptop() -> Result<bool, String> {
    talkwtf_core::helpers::clamshell::is_laptop()
}
