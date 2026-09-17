//! Global hotkeys, via the same `handy-keys` library the Tauri shell uses.
//!
//! Carbon (which the Swift shell could call directly) cannot express the `fn`
//! key or side-specific modifiers, and it has no push-to-talk semantics. Keeping
//! the listener here reuses the behaviour the app already ships: any binding the
//! settings UI accepts, including `fn`, plus press/release edges.
//!
//! Events go out through the core event sink as
//! `hotkey { bindingId, pressed }`; the shell decides what each binding means.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::OnceLock;
use std::thread;
use std::time::Duration;

use handy_keys::{Hotkey, HotkeyId, HotkeyManager, HotkeyState};
use log::{debug, error, info};

static RUNNING: AtomicBool = AtomicBool::new(false);
static THREAD: OnceLock<std::sync::Mutex<Option<thread::JoinHandle<()>>>> = OnceLock::new();

/// Register `(binding_id, hotkey_string)` pairs and start dispatching edges.
/// Replaces any previous registration.
pub fn start(bindings: Vec<(String, String)>) -> Result<(), String> {
    stop();

    let manager = HotkeyManager::new_with_blocking().map_err(|e| e.to_string())?;
    let mut id_to_binding: HashMap<HotkeyId, String> = HashMap::new();

    for (binding_id, hotkey_string) in bindings {
        let hotkey: Hotkey = hotkey_string
            .parse()
            .map_err(|e| format!("invalid hotkey '{hotkey_string}': {e}"))?;
        let id = manager
            .register(hotkey)
            .map_err(|e| format!("failed to register '{hotkey_string}': {e}"))?;
        debug!("registered hotkey '{hotkey_string}' for '{binding_id}'");
        id_to_binding.insert(id, binding_id);
    }

    RUNNING.store(true, Ordering::SeqCst);
    let handle = thread::spawn(move || {
        while RUNNING.load(Ordering::SeqCst) {
            while let Some(event) = manager.try_recv() {
                let Some(binding_id) = id_to_binding.get(&event.id) else {
                    continue;
                };
                let pressed = event.state == HotkeyState::Pressed;
                debug!("hotkey event: binding={binding_id}, pressed={pressed}");
                crate::events::emit(
                    "hotkey",
                    serde_json::json!({ "bindingId": binding_id, "pressed": pressed }),
                );
            }
            thread::sleep(Duration::from_millis(10));
        }
        info!("hotkey listener stopped");
    });

    *THREAD
        .get_or_init(|| std::sync::Mutex::new(None))
        .lock()
        .expect("hotkey thread slot") = Some(handle);
    Ok(())
}

/// Stop dispatching and release every registration.
pub fn stop() {
    RUNNING.store(false, Ordering::SeqCst);
    if let Some(slot) = THREAD.get() {
        if let Ok(mut guard) = slot.lock() {
            if let Some(handle) = guard.take() {
                let _ = handle.join();
            }
        }
    }
}

/// Whether the listener is running.
pub fn is_running() -> bool {
    RUNNING.load(Ordering::SeqCst)
}

/// Read the bindings the app should listen for: every configured workflow
/// binding that has at least one shortcut.
pub fn configured_bindings() -> Vec<(String, String)> {
    let mut out = Vec::new();
    for (id, binding) in crate::settings::bindings() {
        if id == "cancel" {
            continue;
        }
        if !binding.current_binding.trim().is_empty() {
            out.push((id.clone(), binding.current_binding.clone()));
        }
    }
    out
}

/// Log-and-continue wrapper used at startup.
pub fn start_configured() {
    let bindings = configured_bindings();
    if bindings.is_empty() {
        debug!("no hotkeys configured");
        return;
    }
    if let Err(e) = start(bindings) {
        error!("failed to start hotkey listener: {e}");
    }
}
