//! Real macOS 26+ Liquid Glass (`NSGlassEffectView`) as a window's backdrop.
//!
//! Tauri's `effects` only exposes the classic `NSVisualEffectView` materials,
//! which read as flat frosted glass. macOS 26 added `NSGlassEffectView` — the
//! same material SwiftUI's `.glassEffect()` uses — and installing it behind the
//! webview gives the translucent, specular look of Apple's own apps.
//!
//! `install_glass_backdrop` returns `false` when the real glass view could not
//! be installed (macOS < 26, or no window handle), so the caller can fall back
//! to Tauri's vibrancy.

use tauri::WebviewWindow;

/// Installed glass views, keyed by window label, so the corner radius can be
/// updated when the window resizes (the overlay changes size per state). The
/// superview owns the view, so the pointer stays valid for the window's life.
#[cfg(target_os = "macos")]
static GLASS_VIEWS: once_cell::sync::Lazy<
    std::sync::Mutex<std::collections::HashMap<String, usize>>,
> = once_cell::sync::Lazy::new(|| std::sync::Mutex::new(std::collections::HashMap::new()));

/// Insert a glass backdrop behind `window`'s webview. Returns `true` when the
/// real glass view was installed.
#[cfg(target_os = "macos")]
pub fn install_glass_backdrop(window: &WebviewWindow, corner_radius: f64) -> bool {
    use objc2::runtime::AnyClass;
    use objc2::MainThreadMarker;
    use objc2_app_kit::{
        NSAutoresizingMaskOptions, NSGlassEffectView, NSGlassEffectViewStyle, NSWindow,
        NSWindowOrderingMode,
    };

    // Runtime availability: `NSGlassEffectView` is macOS 26+. Sending `new` to a
    // missing class would crash, so check the class exists first.
    if AnyClass::get(c"NSGlassEffectView").is_none() {
        log::info!("NSGlassEffectView is unavailable on this macOS; using vibrancy");
        return false;
    }
    // AppKit views must be created on the main thread.
    let Some(mtm) = MainThreadMarker::new() else {
        log::warn!("Not on the main thread; cannot install the glass backdrop");
        return false;
    };
    let Ok(ns_window) = window.ns_window() else {
        log::warn!(
            "No NSWindow for '{}'; cannot install the glass backdrop",
            window.label()
        );
        return false;
    };
    let ns_window: &NSWindow = unsafe { &*(ns_window as *const NSWindow) };
    let Some(content) = ns_window.contentView() else {
        log::warn!(
            "No contentView for '{}'; cannot install the glass backdrop",
            window.label()
        );
        return false;
    };

    let glass = NSGlassEffectView::new(mtm);
    glass.setCornerRadius(corner_radius);
    glass.setStyle(NSGlassEffectViewStyle::Regular);
    glass.setFrame(content.bounds());
    glass.setAutoresizingMask(
        NSAutoresizingMaskOptions::ViewWidthSizable | NSAutoresizingMaskOptions::ViewHeightSizable,
    );

    // Below every other subview, so the transparent webview draws on top of it.
    content.addSubview_positioned_relativeTo(&glass, NSWindowOrderingMode::Below, None);
    if let Ok(mut views) = GLASS_VIEWS.lock() {
        views.insert(
            window.label().to_string(),
            objc2::rc::Retained::as_ptr(&glass) as usize,
        );
    }
    log::debug!(
        "Installed NSGlassEffectView backdrop (corner radius {corner_radius}) on '{}'",
        window.label()
    );
    true
}

#[cfg(not(target_os = "macos"))]
pub fn install_glass_backdrop(_window: &WebviewWindow, _corner_radius: f64) -> bool {
    false
}

/// Update the installed glass view's corner radius (the overlay window resizes
/// per state, so a fixed radius would no longer match the card).
#[cfg(target_os = "macos")]
pub fn set_glass_corner_radius(window: &WebviewWindow, corner_radius: f64) {
    let Some(pointer) = GLASS_VIEWS
        .lock()
        .ok()
        .and_then(|views| views.get(window.label()).copied())
    else {
        return;
    };
    if pointer == 0 {
        return;
    }
    // Safe: the pointer was stored from a live view that the content view owns.
    let glass: &objc2_app_kit::NSGlassEffectView =
        unsafe { &*(pointer as *const objc2_app_kit::NSGlassEffectView) };
    glass.setCornerRadius(corner_radius);
}

#[cfg(not(target_os = "macos"))]
pub fn set_glass_corner_radius(_window: &WebviewWindow, _corner_radius: f64) {}

/// Tauri's classic vibrancy, used when the real glass view is unavailable.
#[cfg(target_os = "macos")]
pub fn fallback_vibrancy() -> tauri::utils::config::WindowEffectsConfig {
    use tauri::utils::config::WindowEffectsConfig;
    use tauri::window::{Effect, EffectState};
    WindowEffectsConfig {
        effects: vec![Effect::UnderWindowBackground],
        state: Some(EffectState::FollowsWindowActiveState),
        radius: Some(12.0),
        color: None,
    }
}
