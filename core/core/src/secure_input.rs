//! Secure Event Input detection, monitoring and the Carbon fallback plan
//! (macOS).
//!
//! When any process turns on Secure Event Input (a password field, Terminal's
//! Secure Keyboard Entry, a stuck `loginwindow`), CGEventTaps stop seeing
//! KeyDown/KeyUp while modifier changes still flow. The `handy-keys` listener is
//! tap-based, so keyed shortcuts go silent while modifier-only ones keep working.
//!
//! This module polls for that state and, once it has been held long enough to be
//! "sustained", computes which bindings should be shadow-registered through
//! Carbon instead — Carbon hotkeys are handled by the window server and are not
//! affected. The shell performs the actual registration (it owns the run loop)
//! and re-emits the same `hotkey` events, so the rest of the app is unaware.
//!
//! The live check is also used by the edit watcher, which must stop reading text
//! while secure input is active.

use serde::Serialize;

#[cfg(target_os = "macos")]
mod imp {
    #[link(name = "Carbon", kind = "framework")]
    extern "C" {
        // Carbon HIToolbox; Boolean is an unsigned char.
        fn IsSecureEventInputEnabled() -> u8;
    }

    pub fn is_enabled() -> bool {
        unsafe { IsSecureEventInputEnabled() != 0 }
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    pub fn is_enabled() -> bool {
        false
    }
}

/// True if secure input is enabled right now (live check).
pub fn is_enabled_now() -> bool {
    imp::is_enabled()
}

/// Carbon modifier masks (`Events.h`).
pub mod carbon {
    pub const CMD: u32 = 1 << 8;
    pub const SHIFT: u32 = 1 << 9;
    pub const OPTION: u32 = 1 << 11;
    pub const CONTROL: u32 = 1 << 12;
}

/// A binding to shadow-register through Carbon while secure input is held.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ShadowBinding {
    pub binding_id: String,
    /// macOS virtual key code.
    pub key_code: u16,
    /// Carbon modifier mask.
    pub modifiers: u32,
    /// Side-specific modifiers had to widen to the whole group, so this shadow
    /// matches more than the original binding did.
    pub degraded: bool,
}

/// What the shell should do about the current secure-input state.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct FallbackPlan {
    /// Secure input has been held long enough that the tap is dead.
    pub sustained: bool,
    /// Bindings to register through Carbon (empty when not sustained).
    pub shadows: Vec<ShadowBinding>,
    /// Keyed bindings Carbon cannot express (e.g. the `fn` key), so they stay
    /// dead until secure input ends.
    pub uncovered: Vec<String>,
}

/// macOS virtual key code for a key, or `None` when it has no key code (media
/// keys and mouse buttons are not registrable through Carbon).
/// Carbon modifier mask for a set of modifiers. `None` when `fn` is involved:
/// Carbon cannot express it, so the binding cannot be shadowed.
pub fn carbon_modifiers(modifiers: handy_keys::Modifiers) -> Option<(u32, bool)> {
    use handy_keys::Modifiers as M;

    if modifiers.contains(M::FN) {
        return None;
    }

    let mut mask = 0;
    let mut degraded = false;
    for (group, bit) in [
        (M::CMD, carbon::CMD),
        (M::SHIFT, carbon::SHIFT),
        (M::OPT, carbon::OPTION),
        (M::CTRL, carbon::CONTROL),
    ] {
        if modifiers.intersects(group) {
            mask |= bit;
            // Only one side was named, so matching gets wider than the original.
            if !modifiers.contains(group) {
                degraded = true;
            }
        }
    }
    Some((mask, degraded))
}

/// Plan the Carbon fallback for `bindings` (id → hotkey string).
///
/// Modifier-only and mouse bindings are immune to secure input and need no
/// shadow. Keyed bindings that Carbon cannot express (the `fn` key) are reported
/// as uncovered so the UI can explain why they stopped working.
pub fn plan_fallback(bindings: &[(String, String)]) -> FallbackPlan {
    let mut plan = FallbackPlan::default();

    for (id, binding) in bindings {
        let Ok(hotkey) = binding.parse::<handy_keys::Hotkey>() else {
            plan.uncovered.push(id.clone());
            continue;
        };

        // Modifier-only: the tap still receives FlagsChanged, so it keeps working.
        let Some(key) = hotkey.key.as_ref() else {
            continue;
        };
        if key.to_string().to_lowercase().starts_with("mouse") {
            continue;
        }

        let Some(key_code) = crate::keycodes::code_for(key) else {
            plan.uncovered.push(id.clone());
            continue;
        };
        let Some((modifiers, degraded)) = carbon_modifiers(hotkey.modifiers) else {
            plan.uncovered.push(id.clone());
            continue;
        };

        plan.shadows.push(ShadowBinding {
            binding_id: id.clone(),
            key_code,
            modifiers,
            degraded,
        });
    }

    plan
}

/// How often the monitor polls.
const POLL_INTERVAL: std::time::Duration = std::time::Duration::from_secs(1);
/// Secure input must be held this long before it counts as stuck. A password
/// field gaining momentary focus is normal and must not trigger the fallback.
const SUSTAIN_THRESHOLD: std::time::Duration = std::time::Duration::from_secs(3);

static SUSTAINED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
static MONITOR_STARTED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
/// While a recording is in flight the cancel binding is shadowed too, so Escape
/// keeps working when the tap is dead.
static CANCEL_ACTIVE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// The process holding secure input, best effort. Apple documents no reliable
/// API; the IORegistry PID is frequently absent or points at the responsible
/// parent rather than the actual holder.
#[derive(Debug, Clone, Serialize)]
pub struct Culprit {
    pub pid: i32,
    pub name: String,
}

/// Everything the shell needs to explain (and compensate for) the state.
#[derive(Debug, Clone, Serialize)]
pub struct Status {
    pub enabled: bool,
    pub sustained: bool,
    pub culprit: Option<Culprit>,
    pub shadows: Vec<ShadowBinding>,
    pub uncovered: Vec<String>,
}

/// Best-effort holder lookup. Shells out to `ioreg` / `ps`, so only the monitor
/// thread and the diagnostic call it.
fn lookup_culprit() -> Option<Culprit> {
    let out = std::process::Command::new("ioreg")
        .args(["-l", "-w", "0"])
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    let pid: i32 = text
        .lines()
        .find_map(|line| line.split("\"kCGSSessionSecureInputPID\"=").nth(1))?
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect::<String>()
        .parse()
        .ok()?;

    // `ps -o comm=` gives the full path; show just the binary name.
    let name = std::process::Command::new("ps")
        .args(["-o", "comm=", "-p", &pid.to_string()])
        .output()
        .ok()
        .and_then(|out| {
            let raw = String::from_utf8_lossy(&out.stdout);
            let trimmed = raw.trim();
            (!trimmed.is_empty()).then(|| trimmed.rsplit('/').next().unwrap_or(trimmed).to_string())
        })
        .unwrap_or_else(|| "(process no longer running)".to_string());

    Some(Culprit { pid, name })
}

/// The bindings eligible for shadowing right now.
fn shadow_candidates() -> Vec<(String, String)> {
    let cancel_active = CANCEL_ACTIVE.load(std::sync::atomic::Ordering::SeqCst);
    crate::settings::bindings()
        .into_iter()
        .filter(|(id, binding)| {
            if id == "cancel" && !cancel_active {
                return false;
            }
            !binding.current_binding.trim().is_empty()
        })
        .map(|(id, binding)| (id, binding.current_binding))
        .collect()
}

/// Whether the tap is currently known to be dead.
pub fn is_sustained() -> bool {
    SUSTAINED.load(std::sync::atomic::Ordering::SeqCst)
}

/// Shadow the cancel binding while a recording is in flight.
pub fn set_cancel_active(active: bool) {
    CANCEL_ACTIVE.store(active, std::sync::atomic::Ordering::SeqCst);
}

/// The current state, including the plan the shell should apply. Does not touch
/// the process list, so it is safe to call from a command handler.
pub fn status() -> Status {
    let sustained = is_sustained();
    let plan = if sustained {
        plan_fallback(&shadow_candidates())
    } else {
        FallbackPlan::default()
    };

    Status {
        enabled: is_enabled_now(),
        sustained,
        culprit: CULPRIT
            .get()
            .and_then(|slot| slot.lock().ok().and_then(|guard| guard.clone())),
        shadows: plan.shadows,
        uncovered: plan.uncovered,
    }
}

static CULPRIT: std::sync::OnceLock<std::sync::Mutex<Option<Culprit>>> = std::sync::OnceLock::new();

fn set_culprit(culprit: Option<Culprit>) {
    let slot = CULPRIT.get_or_init(|| std::sync::Mutex::new(None));
    if let Ok(mut guard) = slot.lock() {
        *guard = culprit;
    }
}

fn emit_status() {
    crate::events::emit("secure-input-changed", status());
}

/// Watch for secure input and tell the shell when to switch to Carbon shadows.
/// Idempotent: the first call starts the thread, later calls do nothing.
pub fn start_monitor() {
    if MONITOR_STARTED.swap(true, std::sync::atomic::Ordering::SeqCst) {
        return;
    }

    std::thread::spawn(|| {
        use std::sync::atomic::Ordering;
        use std::time::Instant;

        log::info!("secure-input monitor started");
        let mut enabled_since: Option<Instant> = None;
        let mut was_enabled = false;

        loop {
            std::thread::sleep(POLL_INTERVAL);
            let now_enabled = is_enabled_now();

            if !now_enabled {
                let changed = was_enabled || is_sustained();
                was_enabled = false;
                enabled_since = None;
                set_culprit(None);
                if SUSTAINED.swap(false, Ordering::SeqCst) {
                    log::info!("SecureInput disabled — releasing Carbon shadows");
                }
                if changed {
                    emit_status();
                }
                continue;
            }

            if !was_enabled {
                was_enabled = true;
                enabled_since = Some(Instant::now());
                let culprit = lookup_culprit();
                match &culprit {
                    Some(c) => log::info!("SecureInput enabled (held by {} '{}')", c.pid, c.name),
                    None => log::info!("SecureInput enabled (no visible holder)"),
                }
                set_culprit(culprit);
                emit_status();
            }

            if !is_sustained()
                && enabled_since
                    .map(|t| t.elapsed() >= SUSTAIN_THRESHOLD)
                    .unwrap_or(false)
            {
                log::warn!(
                    "SecureInput held for {}s — keyed shortcuts are blocked; enabling Carbon shadows",
                    SUSTAIN_THRESHOLD.as_secs()
                );
                SUSTAINED.store(true, Ordering::SeqCst);
                emit_status();
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keyed_bindings_shadow_with_carbon_modifiers() {
        let plan = plan_fallback(&[("transcribe".into(), "option+space".into())]);
        assert_eq!(plan.uncovered, Vec::<String>::new());
        assert_eq!(plan.shadows.len(), 1);
        let shadow = &plan.shadows[0];
        assert_eq!(shadow.binding_id, "transcribe");
        assert_eq!(shadow.modifiers, carbon::OPTION);
        assert!(!shadow.degraded);
    }

    #[test]
    fn side_specific_modifiers_widen_and_report_degraded() {
        let plan = plan_fallback(&[("translate".into(), "option_right+fn+down".into())]);
        // fn cannot be expressed through Carbon at all.
        assert_eq!(plan.uncovered, vec!["translate".to_string()]);
        assert!(plan.shadows.is_empty());

        let plan = plan_fallback(&[("transcribe".into(), "option_right+space".into())]);
        assert_eq!(plan.shadows.len(), 1);
        assert_eq!(plan.shadows[0].modifiers, carbon::OPTION);
        assert!(plan.shadows[0].degraded, "one side named → wider match");
    }

    #[test]
    fn modifier_only_bindings_are_immune() {
        // The tap still sees FlagsChanged, so nothing to shadow.
        let plan = plan_fallback(&[("transcribe".into(), "option".into())]);
        assert!(plan.shadows.is_empty());
        assert!(plan.uncovered.is_empty());
    }

    #[test]
    fn unparseable_bindings_are_reported_uncovered() {
        let plan = plan_fallback(&[("transcribe".into(), "not a hotkey".into())]);
        assert_eq!(plan.uncovered, vec!["transcribe".to_string()]);
    }

    #[test]
    fn letters_map_to_their_virtual_key_codes() {
        use handy_keys::Key;
        assert_eq!(crate::keycodes::code_for(&Key::Space), Some(0x31));
        assert_eq!(crate::keycodes::code_for(&Key::A), Some(0x00));
        assert_eq!(crate::keycodes::code_for(&Key::Escape), Some(0x35));
    }
}
