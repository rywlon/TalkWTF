//! Secure Event Input detection (macOS).
//!
//! Only the live check lives here; the monitoring thread, Carbon fallback
//! registration and tray warning stay in the shell. The core needs the check so
//! the edit watcher can stop reading text while secure input is active.

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
