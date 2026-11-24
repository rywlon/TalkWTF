//! Small shared utilities.

/// Preserve diagnostic text in development builds, but redact it in releases.
/// Do not use for secrets such as API keys, which must always be redacted.
pub fn redact_text(text: &str) -> &str {
    if cfg!(debug_assertions) {
        text
    } else {
        "[REDACTED]"
    }
}

/// Whether this is the x64 Windows build running under emulation on Windows
/// ARM64 (which disables the transcribe.cpp GPU path).
///
/// The detection needs the `windows` crate, which the core deliberately does not
/// depend on; this project targets macOS, where the answer is always `false`.
/// If Windows-x64-on-ARM64 support is ever needed, register a shell-provided
/// detector here.
pub fn is_windows_x64_emulated_on_arm64() -> bool {
    false
}
