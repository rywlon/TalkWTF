//! C ABI for the TalkWTF Rust core.
//!
//! The SwiftUI app links this static library and talks to the core through two
//! entry points:
//!
//! * `talkwtf_invoke(command, payload_json)` — a JSON dispatcher, so the whole
//!   command surface (settings, dictionary, history, …) needs one C function
//!   rather than one per command.
//! * `talkwtf_set_event_callback(cb, userdata)` — pushes core events (overlay
//!   state, stream text, learned corrections, …) back to Swift.
//!
//! Ownership: every returned `char *` is a heap-allocated C string that the
//! caller must release with [`talkwtf_free_string`]. Inputs are borrowed and
//! never freed by us.

use std::ffi::{c_char, c_void, CStr, CString};
use std::sync::atomic::{AtomicPtr, Ordering};

use serde_json::{json, Value};
use talkwtf_core::{dashboard, dictionary, engine, history, model, settings, state};

/// Event callback signature: receives a JSON string and the opaque userdata
/// pointer passed to [`talkwtf_set_event_callback`].
pub type TalkWtfEventCallback = extern "C" fn(event_json: *const c_char, userdata: *mut c_void);

static EVENT_CALLBACK: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static EVENT_USERDATA: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

/// Turn a Rust `String` into an owned C string the caller frees.
fn into_c_string(value: String) -> *mut c_char {
    match CString::new(value) {
        Ok(c_string) => c_string.into_raw(),
        Err(_) => CString::new("")
            .expect("empty string has no NUL")
            .into_raw(),
    }
}

/// Borrow a C string as `&str`, or `""` when the pointer is null/invalid UTF-8.
///
/// # Safety
/// `pointer` must be null or a valid NUL-terminated C string.
unsafe fn borrow_str<'a>(pointer: *const c_char) -> &'a str {
    if pointer.is_null() {
        return "";
    }
    CStr::from_ptr(pointer).to_str().unwrap_or("")
}

/// The core version, e.g. `"0.9.6"`. Caller frees with [`talkwtf_free_string`].
#[no_mangle]
pub extern "C" fn talkwtf_version() -> *mut c_char {
    into_c_string(env!("CARGO_PKG_VERSION").to_string())
}

/// JSON command dispatcher.
///
/// Returns a JSON object: `{"ok": <value>}` on success, `{"error": "..."}` on
/// failure. Caller frees the result with [`talkwtf_free_string`].
///
/// # Safety
/// `command` and `payload` must be null or valid NUL-terminated C strings.
#[no_mangle]
pub unsafe extern "C" fn talkwtf_invoke(
    command: *const c_char,
    payload: *const c_char,
) -> *mut c_char {
    let command = borrow_str(command);
    let payload = borrow_str(payload);
    into_c_string(dispatch(command, payload))
}

/// Release a string returned by this library.
///
/// # Safety
/// `value` must be null or a pointer returned by this library, freed once.
#[no_mangle]
pub unsafe extern "C" fn talkwtf_free_string(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

/// Register (or clear, with `cb = None`) the event callback.
///
/// # Safety
/// `userdata` must stay valid until the callback is cleared.
#[no_mangle]
pub unsafe extern "C" fn talkwtf_set_event_callback(
    callback: Option<TalkWtfEventCallback>,
    userdata: *mut c_void,
) {
    match callback {
        Some(callback) => {
            EVENT_CALLBACK.store(callback as *mut c_void, Ordering::SeqCst);
            EVENT_USERDATA.store(userdata, Ordering::SeqCst);
        }
        None => {
            EVENT_CALLBACK.store(std::ptr::null_mut(), Ordering::SeqCst);
            EVENT_USERDATA.store(std::ptr::null_mut(), Ordering::SeqCst);
        }
    }
}

/// Emit an event to the registered callback. No-op when none is registered.
pub fn emit_event(event_json: &str) {
    let raw = EVENT_CALLBACK.load(Ordering::SeqCst);
    if raw.is_null() {
        return;
    }
    // Safe: the pointer was stored from a valid `TalkWtfEventCallback`.
    let callback: TalkWtfEventCallback = unsafe { std::mem::transmute(raw) };
    let userdata = EVENT_USERDATA.load(Ordering::SeqCst);
    if let Ok(c_string) = CString::new(event_json) {
        callback(c_string.as_ptr(), userdata);
    }
}

/// Minimal stderr logger so the core's `log::*` output is visible when the
/// Swift app runs from a terminal (and in Console). Without it every core log
/// call is dropped, since the FFI host installs no logger.
struct StderrLogger;

impl log::Log for StderrLogger {
    fn enabled(&self, _metadata: &log::Metadata) -> bool {
        true
    }

    fn log(&self, record: &log::Record) {
        eprintln!(
            "[{:<5} {}] {}",
            record.level(),
            record.target(),
            record.args()
        );
    }

    fn flush(&self) {}
}

static LOGGER: StderrLogger = StderrLogger;

fn install_logger() {
    let _ = log::set_logger(&LOGGER);
    log::set_max_level(log::LevelFilter::Debug);
}

/// Event sink that forwards core events to the C callback as
/// `{"event": "<name>", "payload": <json>}`.
struct FfiEventSink;

impl talkwtf_core::events::EventSink for FfiEventSink {
    fn emit(&self, event: &str, payload: Value) {
        emit_event(&json!({ "event": event, "payload": payload }).to_string());
    }
}

/* ─────────────────────────── dispatch helpers ─────────────────────────── */

type CmdResult = Result<Value, String>;

fn ok(value: Value) -> String {
    json!({ "ok": value }).to_string()
}

fn err(message: impl std::fmt::Display) -> String {
    json!({ "error": message.to_string() }).to_string()
}

fn parse(payload: &str) -> Result<Value, String> {
    if payload.trim().is_empty() {
        return Ok(json!({}));
    }
    serde_json::from_str(payload).map_err(|e| format!("invalid payload JSON: {e}"))
}

fn arg<T: serde::de::DeserializeOwned>(payload: &Value, key: &str) -> Result<T, String> {
    let value = payload
        .get(key)
        .cloned()
        .ok_or_else(|| format!("missing field '{key}'"))?;
    serde_json::from_value(value).map_err(|e| format!("invalid field '{key}': {e}"))
}

fn opt_arg<T: serde::de::DeserializeOwned>(
    payload: &Value,
    key: &str,
) -> Result<Option<T>, String> {
    match payload.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => serde_json::from_value(value.clone())
            .map(Some)
            .map_err(|e| format!("invalid field '{key}': {e}")),
    }
}

/// Recursively merge `patch` into `base` (objects merge, everything else
/// replaces). Used by `update_settings`.
fn merge(base: &mut Value, patch: Value) {
    match (base, patch) {
        (Value::Object(base), Value::Object(patch)) => {
            for (key, value) in patch {
                merge(base.entry(key).or_insert(Value::Null), value);
            }
        }
        (base, patch) => *base = patch,
    }
}

/// Run a future to completion on a small blocking runtime (the FFI entry points
/// are synchronous).
fn block_on<F: std::future::Future>(future: F) -> F::Output {
    use std::sync::OnceLock;
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    let runtime = RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("failed to build tokio runtime")
    });
    runtime.block_on(future)
}

fn json_of<T: serde::Serialize>(value: T) -> CmdResult {
    serde_json::to_value(value).map_err(|e| e.to_string())
}

/* ────────────────────────────── commands ─────────────────────────────── */

fn dispatch(command: &str, payload: &str) -> String {
    let parsed = match parse(payload) {
        Ok(value) => value,
        Err(message) => return err(message),
    };
    let result = run(command, &parsed);
    match result {
        Ok(value) => ok(value),
        Err(message) => err(message),
    }
}

fn run(command: &str, payload: &Value) -> CmdResult {
    match command {
        "ping" => Ok(json!({ "pong": true, "version": env!("CARGO_PKG_VERSION") })),

        /// Boots the engine. Call once after `talkwtf_set_event_callback`.
        ///
        /// Payload: `{ "dataDir": "/…/com.pais.handy", "resourceDir": "/…/Resources",
        /// "locale": "zh-Hans-CN" }`. `dataDir` is required; the rest are optional.
        "init" => {
            let data_dir: String = arg(payload, "dataDir")?;
            std::fs::create_dir_all(&data_dir)
                .map_err(|e| format!("failed to create data dir '{data_dir}': {e}"))?;
            settings::init(std::path::PathBuf::from(data_dir));
            if let Some(resource_dir) = opt_arg::<String>(payload, "resourceDir")? {
                settings::set_resource_dir(std::path::PathBuf::from(resource_dir));
            }
            if let Some(locale) = opt_arg::<String>(payload, "locale")? {
                settings::set_locale(locale);
            }

            install_logger();
            talkwtf_core::events::set_sink(Box::new(FfiEventSink));
            engine::init().map_err(|e| e.to_string())?;
            Ok(json!({ "initialized": true }))
        }

        // ---- settings -----------------------------------------------------
        "get_app_settings" => json_of(settings::current()),
        "get_default_settings" => json_of(settings::get_default_settings()),
        /// Merge a partial settings object (e.g. `{"theme":"dark"}`).
        "update_settings" => {
            let mut current =
                serde_json::to_value(settings::current()).map_err(|e| e.to_string())?;
            merge(&mut current, payload.clone());
            let updated: settings::AppSettings =
                serde_json::from_value(current).map_err(|e| format!("invalid settings: {e}"))?;
            settings::store(updated.clone());
            json_of(updated)
        }
        "get_polish_styles" => json_of(settings::polish_style_options()),
        "get_translation_languages" => json_of(settings::translation_languages()),
        "get_bindings" => json_of(settings::bindings()),
        /// Validate and store a shortcut, then re-register the listener so it
        /// takes effect immediately.
        "set_binding" => {
            let id: String = arg(payload, "id")?;
            let hotkey: String = arg(payload, "hotkey")?;
            let updated = settings::set_binding(&id, &hotkey)?;
            restart_hotkeys();
            json_of(updated)
        }
        /// Restore a binding to the value this build ships.
        "reset_binding" => {
            let id: String = arg(payload, "id")?;
            let updated = settings::reset_binding(&id)?;
            restart_hotkeys();
            json_of(updated)
        }
        /// Turn a captured key press into a binding string, so the shell does not
        /// need to know the `handy-keys` spelling.
        "build_binding" => {
            let key_code: u16 = arg(payload, "keyCode")?;
            let modifiers: Vec<String> = opt_arg(payload, "modifiers")?.unwrap_or_default();
            json_of(settings::binding_from_capture(key_code, &modifiers))
        }

        // ---- scenes -------------------------------------------------------
        "add_scene" => {
            let (name, description, prompt) = settings::prepare_scene_input(
                &arg::<String>(payload, "name")?,
                &arg::<String>(payload, "description")?,
                &arg::<String>(payload, "prompt")?,
            )?;
            let mut current = settings::current();
            if current.scenes.len() >= settings::SCENES_MAX_COUNT {
                return Err(format!(
                    "At most {} scenes are supported",
                    settings::SCENES_MAX_COUNT
                ));
            }
            let now = chrono::Utc::now().to_rfc3339();
            let base = chrono::Utc::now().timestamp_millis();
            let mut suffix = 0;
            let mut id = format!("scene_{base}");
            while current.scenes.iter().any(|scene| scene.id == id) {
                suffix += 1;
                id = format!("scene_{base}_{suffix}");
            }
            let scene = settings::Scene {
                id,
                name,
                description,
                prompt,
                created_at: now.clone(),
                updated_at: now,
            };
            current.scenes.push(scene.clone());
            settings::store(current);
            json_of(scene)
        }
        "update_scene" => {
            let (name, description, prompt) = settings::prepare_scene_input(
                &arg::<String>(payload, "name")?,
                &arg::<String>(payload, "description")?,
                &arg::<String>(payload, "prompt")?,
            )?;
            let id: String = arg(payload, "id")?;
            let mut current = settings::current();
            let scene = current
                .scenes
                .iter_mut()
                .find(|scene| scene.id == id)
                .ok_or_else(|| format!("Scene '{id}' not found"))?;
            scene.name = name;
            scene.description = description;
            scene.prompt = prompt;
            scene.updated_at = chrono::Utc::now().to_rfc3339();
            let updated = scene.clone();
            settings::store(current);
            json_of(updated)
        }
        "delete_scene" => {
            let id: String = arg(payload, "id")?;
            let mut current = settings::current();
            let before = current.scenes.len();
            current.scenes.retain(|scene| scene.id != id);
            if current.scenes.len() == before {
                return Err(format!("Scene '{id}' not found"));
            }
            if current.active_scene_id.as_deref() == Some(id.as_str()) {
                current.active_scene_id = None;
            }
            settings::store(current);
            Ok(Value::Null)
        }
        "reset_scene" => {
            let id: String = arg(payload, "id")?;
            let built_in = settings::built_in_scenes()
                .into_iter()
                .find(|scene| scene.id == id)
                .ok_or_else(|| format!("Scene '{id}' is not a built-in scene"))?;
            let mut current = settings::current();
            let scene = current
                .scenes
                .iter_mut()
                .find(|scene| scene.id == id)
                .ok_or_else(|| format!("Scene '{id}' not found"))?;
            scene.name = built_in.name;
            scene.description = built_in.description;
            scene.prompt = built_in.prompt;
            let restored = scene.clone();
            settings::store(current);
            json_of(restored)
        }
        "restore_built_in_scenes" => {
            let mut current = settings::current();
            let mut changed = false;
            for built_in in settings::built_in_scenes() {
                if !current.scenes.iter().any(|scene| scene.id == built_in.id) {
                    current.scenes.push(built_in);
                    changed = true;
                }
            }
            if changed {
                settings::store(current.clone());
            }
            json_of(current.scenes)
        }
        "set_active_scene" => {
            let id: Option<String> = opt_arg(payload, "id")?;
            let mut current = settings::current();
            if let Some(id) = &id {
                if !current.scenes.iter().any(|scene| &scene.id == id) {
                    return Err(format!("Scene '{id}' not found"));
                }
            }
            current.active_scene_id = id;
            settings::store(current);
            Ok(Value::Null)
        }
        "change_polish_style" => {
            let style: String = arg(payload, "style")?;
            if !settings::is_known_polish_style(&style) {
                return Err(format!("Unknown polish style '{style}'"));
            }
            let mut current = settings::current();
            current.polish_style = style;
            settings::store(current);
            Ok(Value::Null)
        }

        // ---- translation targets ------------------------------------------
        "add_translation_target" => {
            let code: String = arg(payload, "code")?;
            if !settings::is_known_translation_language(&code) {
                return Err(format!("Unknown translation language '{code}'"));
            }
            let mut current = settings::current();
            if !current.translation_targets.iter().any(|t| t == &code) {
                if current.translation_targets.len() >= settings::TRANSLATION_TARGETS_MAX_COUNT {
                    return Err(format!(
                        "At most {} target languages are supported",
                        settings::TRANSLATION_TARGETS_MAX_COUNT
                    ));
                }
                current.translation_targets.push(code);
            }
            current.translation_targets =
                settings::prepare_translation_targets(&current.translation_targets);
            if current.translation_active_target.is_none() {
                current.translation_active_target = current.translation_targets.first().cloned();
            }
            let targets = current.translation_targets.clone();
            settings::store(current);
            json_of(targets)
        }
        "remove_translation_target" => {
            let code: String = arg(payload, "code")?;
            let mut current = settings::current();
            current.translation_targets.retain(|target| target != &code);
            if current.translation_active_target.as_deref() == Some(code.as_str()) {
                current.translation_active_target = current.translation_targets.first().cloned();
            }
            let targets = current.translation_targets.clone();
            settings::store(current);
            json_of(targets)
        }
        "set_active_translation_target" => {
            let code: Option<String> = opt_arg(payload, "code")?;
            let mut current = settings::current();
            if let Some(code) = &code {
                if !current
                    .translation_targets
                    .iter()
                    .any(|target| target == code)
                {
                    return Err(format!("Target language '{code}' is not configured"));
                }
            }
            current.translation_active_target = code;
            settings::store(current);
            Ok(Value::Null)
        }

        // ---- dictionary ---------------------------------------------------
        "get_dictionary" => {
            let store = dictionary_store()?;
            Ok(json!({
                "words": store.list_words().map_err(|e| e.to_string())?,
                "rules": store.list_rules().map_err(|e| e.to_string())?,
            }))
        }
        "get_dictionary_limits" => Ok(json!({
            "word_max_chars": dictionary::WORD_MAX_CHARS,
            "rule_pattern_max_chars": dictionary::RULE_PATTERN_MAX_CHARS,
            "rule_replacement_max_chars": dictionary::RULE_REPLACEMENT_MAX_CHARS,
        })),
        "add_dictionary_word" => {
            let word: String = arg(payload, "word")?;
            json_of(
                dictionary_store()?
                    .add_word(&word)
                    .map_err(|e| e.to_string())?,
            )
        }
        "update_dictionary_word" => {
            let id: i64 = arg(payload, "id")?;
            let word: String = arg(payload, "word")?;
            json_of(
                dictionary_store()?
                    .update_word(id, &word)
                    .map_err(|e| e.to_string())?,
            )
        }
        "delete_dictionary_word" => {
            let id: i64 = arg(payload, "id")?;
            dictionary_store()?
                .delete_word(id)
                .map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "add_correction_rule" => {
            let pattern: String = arg(payload, "pattern")?;
            let replacement: String = arg(payload, "replacement")?;
            json_of(
                dictionary_store()?
                    .add_rule(&pattern, &replacement)
                    .map_err(|e| e.to_string())?,
            )
        }
        "update_correction_rule" => {
            let id: i64 = arg(payload, "id")?;
            let pattern: String = arg(payload, "pattern")?;
            let replacement: String = arg(payload, "replacement")?;
            json_of(
                dictionary_store()?
                    .update_rule(id, &pattern, &replacement)
                    .map_err(|e| e.to_string())?,
            )
        }
        "set_correction_rule_enabled" => {
            let id: i64 = arg(payload, "id")?;
            let enabled: bool = arg(payload, "enabled")?;
            json_of(
                dictionary_store()?
                    .set_rule_enabled(id, enabled)
                    .map_err(|e| e.to_string())?,
            )
        }
        "delete_correction_rule" => {
            let id: i64 = arg(payload, "id")?;
            dictionary_store()?
                .delete_rule(id)
                .map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "list_learning_rejections" => json_of(
            dictionary_store()?
                .list_learning_rejections()
                .map_err(|e| e.to_string())?,
        ),
        "forget_learning_rejection" => {
            let pattern: String = arg(payload, "pattern")?;
            dictionary_store()?
                .forget_learning_rejection(&pattern)
                .map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "clear_learning_rejections" => {
            dictionary_store()?
                .clear_learning_rejections()
                .map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }

        "export_dictionary" => {
            let path: String = arg(payload, "path")?;
            let store = dictionary_store()?;
            talkwtf_core::dictionary_io::export_dictionary(store.as_ref(), &path)?;
            Ok(Value::Null)
        }
        "import_dictionary" => {
            let path: String = arg(payload, "path")?;
            let store = dictionary_store()?;
            json_of(talkwtf_core::dictionary_io::import_dictionary(
                store.as_ref(),
                &path,
            )?)
        }
        "export_polish_profile" => {
            let path: String = arg(payload, "path")?;
            talkwtf_core::polish_profile::export_polish_profile(&settings::current(), &path)?;
            Ok(Value::Null)
        }
        "import_polish_profile" => {
            let path: String = arg(payload, "path")?;
            let mut current = settings::current();
            let report = talkwtf_core::polish_profile::import_polish_profile(&mut current, &path)?;
            settings::store(current);
            json_of(report)
        }

        // ---- history ------------------------------------------------------
        "get_history_entries" => {
            let cursor: Option<i64> = opt_arg(payload, "cursor")?;
            let limit: Option<usize> = opt_arg(payload, "limit")?;
            let manager = history_manager()?;
            json_of(
                block_on(manager.get_history_entries(cursor, limit)).map_err(|e| e.to_string())?,
            )
        }
        "toggle_history_entry_saved" => {
            let id: i64 = arg(payload, "id")?;
            let manager = history_manager()?;
            block_on(manager.toggle_saved_status(id)).map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "delete_history_entry" => {
            let id: i64 = arg(payload, "id")?;
            let manager = history_manager()?;
            block_on(manager.delete_entry(id)).map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "get_audio_file_path" => {
            let file_name: String = arg(payload, "fileName")?;
            let manager = history_manager()?;
            Ok(json!(manager
                .get_audio_file_path(&file_name)
                .to_string_lossy()))
        }

        // ---- models -------------------------------------------------------
        "get_available_models" => json_of(model_manager()?.get_available_models()),
        "get_model_info" => {
            let id: String = arg(payload, "modelId")?;
            json_of(model_manager()?.get_model_info(&id))
        }
        "rescan_local_models" => {
            model_manager()?
                .rescan_local_models()
                .map_err(|e| e.to_string())?;
            json_of(model_manager()?.get_available_models())
        }
        "delete_model" => {
            talkwtf_core::dictation::ensure_idle()?;
            let id: String = arg(payload, "modelId")?;
            model_manager()?
                .delete_model(&id)
                .map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }

        "get_current_model" => {
            let manager = transcription_manager()?;
            json_of(manager.get_current_model())
        }
        "is_model_loaded" => {
            let manager = transcription_manager()?;
            json_of(manager.is_model_loaded())
        }
        /// Validate the model, persist it as the selection, and load it.
        "set_active_model" => {
            talkwtf_core::dictation::ensure_idle()?;
            let id: String = arg(payload, "modelId")?;
            let manager = model_manager()?;
            if manager.get_model_info(&id).is_none() {
                return Err(format!("Unknown model '{id}'"));
            }
            let mut current = settings::current();
            current.selected_model = id.clone();
            settings::store(current);
            let transcription = transcription_manager()?;
            transcription.reload_model_on_next_use();
            transcription.initiate_model_load();
            json_of(id)
        }
        /// Blocking download; progress arrives as `model-download-progress`
        /// events. Call from a background thread in the shell.
        "download_model" => {
            let id: String = arg(payload, "modelId")?;
            let manager = model_manager()?;
            block_on(manager.download_model(&id)).map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "cancel_download" => {
            let id: String = arg(payload, "modelId")?;
            model_manager()?
                .cancel_download(&id)
                .map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }

        // ---- learning -----------------------------------------------------
        "diagnose_edit_learning" => json_of(talkwtf_core::learning::diagnose()),
        "undo_last_dictionary_learning" => {
            talkwtf_core::learning::undo_last_learning()?;
            Ok(Value::Null)
        }

        /// Transcription-language picker entries plus what the loaded model
        /// actually supports, so the shell can gate the options.
        "get_recognition_languages" => {
            let settings = settings::current();
            let info = model_manager()
                .ok()
                .and_then(|manager| manager.get_model_info(&settings.selected_model));
            json_of(json!({
                "languages": talkwtf_core::languages::selectable_languages(),
                "supported": info.as_ref().map(|i| i.supported_languages.clone()).unwrap_or_default(),
                "supports_detection": info.as_ref().map(|i| i.supports_language_detection).unwrap_or(true),
                "supports_selection": info.as_ref().map(|i| i.supports_language_selection).unwrap_or(true),
            }))
        }

        // ---- platform / permissions ---------------------------------------
        "is_accessibility_trusted" => json_of(talkwtf_core::learning::is_accessibility_trusted()),
        /// macOS Secure Event Input: when on, CGEventTaps stop seeing key
        /// events, so keyed shortcuts go silent. The debug pane explains it.
        "is_secure_input_enabled" => json_of(talkwtf_core::secure_input::is_enabled_now()),
        /// Secure-input state plus the Carbon shadow plan the shell should apply.
        "get_secure_input_status" => json_of(talkwtf_core::secure_input::status()),
        /// Start watching for secure input; emits `secure-input-changed` on
        /// transitions. Idempotent.
        "start_secure_input_monitor" => {
            talkwtf_core::secure_input::start_monitor();
            Ok(Value::Null)
        }
        /// Shadow the cancel binding while a recording is in flight.
        "set_cancel_shadow_active" => {
            let active: bool = arg(payload, "active")?;
            talkwtf_core::secure_input::set_cancel_active(active);
            Ok(Value::Null)
        }
        "get_available_accelerators" => {
            json_of(talkwtf_core::transcription::get_available_accelerators())
        }
        "list_input_devices" => {
            json_of(talkwtf_core::audio_toolkit::list_input_devices().map_err(|e| e.to_string())?)
        }
        "list_output_devices" => {
            json_of(talkwtf_core::audio_toolkit::list_output_devices().map_err(|e| e.to_string())?)
        }
        "unload_model" => {
            talkwtf_core::dictation::ensure_idle()?;
            transcription_manager()?
                .unload_model()
                .map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }

        // ---- hotkeys ------------------------------------------------------
        /// Register the settings' bindings and start dispatching `hotkey`
        /// events `{ bindingId, pressed }`.
        "start_hotkeys" => {
            talkwtf_core::hotkeys::start_configured();
            json_of(talkwtf_core::hotkeys::is_running())
        }
        "stop_hotkeys" => {
            talkwtf_core::hotkeys::stop();
            Ok(Value::Null)
        }

        // ---- dictation ----------------------------------------------------
        /// `{ "mode": "dictation" | "translate" }` — loads the model and starts
        /// recording. Returns immediately; call `stop_dictation` to finish.
        "start_dictation" => {
            talkwtf_core::dictation::start(parse_mode(payload)?).map_err(|e| e)?;
            Ok(Value::Null)
        }
        /// `{ "mode": ... }` — stops, transcribes and returns the final text
        /// (blocking: run it off the main thread in the shell).
        "stop_dictation" => {
            let text = talkwtf_core::dictation::stop(parse_mode(payload)?)?;
            json_of(text)
        }
        /// Re-transcribe a saved history entry from its audio. Blocking.
        "retry_history_entry_transcription" => {
            let id: i64 = arg(payload, "id")?;
            talkwtf_core::dictation::retry_history_transcription(id)?;
            Ok(Value::Null)
        }
        /// Watch the field we just pasted into, so a correction the user makes
        /// can be learned into the dictionary.
        "watch_for_edit" => {
            let text: String = arg(payload, "text")?;
            talkwtf_core::learning::watch_for_edit(&text);
            Ok(Value::Null)
        }
        /// Whether a dictation is recording or being transcribed.
        "is_dictating" => json_of(talkwtf_core::dictation::is_busy()),
        /// Re-run the most recent failed translation; returns the translated
        /// text for the shell to paste. Blocking.
        "retry_last_translation" => json_of(talkwtf_core::dictation::retry_last_translation()?),
        "cancel_dictation" => {
            talkwtf_core::dictation::cancel();
            Ok(Value::Null)
        }

        // ---- dashboard ----------------------------------------------------
        "get_dashboard_stats" => json_of(dashboard::get_dashboard_stats()?),

        other => Err(format!("unknown command '{other}'")),
    }
}

/// Re-register the hotkey listener after a binding change. Failures are logged:
/// the settings are already saved, and the next launch retries.
fn restart_hotkeys() {
    if let Err(error) = talkwtf_core::hotkeys::start(talkwtf_core::hotkeys::configured_bindings()) {
        log::error!("failed to re-register hotkeys: {error}");
    }
}

fn parse_mode(payload: &Value) -> Result<talkwtf_core::pipeline::ProcessingMode, String> {
    match payload
        .get("mode")
        .and_then(|v| v.as_str())
        .unwrap_or("dictation")
    {
        "translate" => Ok(talkwtf_core::pipeline::ProcessingMode::Translate),
        "dictation" => Ok(talkwtf_core::pipeline::ProcessingMode::Polish),
        other => Err(format!("unknown mode '{other}'")),
    }
}

fn dictionary_store() -> Result<std::sync::Arc<dictionary::DictionaryStore>, String> {
    state::dictionary_store().ok_or_else(|| "dictionary store is not initialized".to_string())
}

fn history_manager() -> Result<std::sync::Arc<history::HistoryManager>, String> {
    state::history_manager().ok_or_else(|| "history manager is not initialized".to_string())
}

fn model_manager() -> Result<std::sync::Arc<model::ModelManager>, String> {
    state::model_manager().ok_or_else(|| "model manager is not initialized".to_string())
}

fn transcription_manager(
) -> Result<std::sync::Arc<talkwtf_core::transcription::TranscriptionManager>, String> {
    state::transcription_manager()
        .ok_or_else(|| "transcription manager is not initialized".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ping_reports_the_version() {
        let response = dispatch("ping", "");
        let value: serde_json::Value = serde_json::from_str(&response).unwrap();
        assert_eq!(value["ok"]["pong"], true);
        assert_eq!(value["ok"]["version"], env!("CARGO_PKG_VERSION"));
    }

    #[test]
    fn unknown_command_is_an_error() {
        let response = dispatch("nope", "");
        let value: serde_json::Value = serde_json::from_str(&response).unwrap();
        assert!(value["error"].as_str().unwrap().contains("unknown command"));
    }

    #[test]
    fn missing_field_is_an_error() {
        let response = dispatch("add_dictionary_word", "{}");
        let value: serde_json::Value = serde_json::from_str(&response).unwrap();
        assert!(value["error"].as_str().unwrap().contains("missing field"));
    }

    #[test]
    fn version_round_trips_through_the_c_abi() {
        let pointer = talkwtf_version();
        assert!(!pointer.is_null());
        let version = unsafe { CStr::from_ptr(pointer) }
            .to_str()
            .unwrap()
            .to_string();
        unsafe { talkwtf_free_string(pointer) };
        assert_eq!(version, env!("CARGO_PKG_VERSION"));
    }

    #[test]
    fn invoke_returns_owned_json_and_accepts_null() {
        let command = CString::new("ping").unwrap();
        let pointer = unsafe { talkwtf_invoke(command.as_ptr(), std::ptr::null()) };
        let response = unsafe { CStr::from_ptr(pointer) }
            .to_str()
            .unwrap()
            .to_string();
        unsafe { talkwtf_free_string(pointer) };
        assert!(response.contains("\"pong\":true"));
    }

    #[test]
    fn merge_patches_nested_settings() {
        let mut base = json!({ "theme": "system", "scenes": [{ "id": "a" }] });
        merge(&mut base, json!({ "theme": "dark", "extra": 1 }));
        assert_eq!(base["theme"], "dark");
        assert_eq!(base["extra"], 1);
        assert_eq!(base["scenes"][0]["id"], "a");
    }
}
