// C ABI for the TalkWTF Rust core.
//
// Hand-maintained; keep in sync with core/ffi/src/lib.rs. The SwiftUI app links
// the static library built from that crate.

#ifndef TALKWTF_H
#define TALKWTF_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Event callback: receives a JSON string plus the opaque `userdata` pointer.
typedef void (*TalkWtfEventCallback)(const char *event_json, void *userdata);

/// The core version, e.g. "0.9.6". Free with `talkwtf_free_string`.
char *talkwtf_version(void);

/// JSON command dispatcher. Returns `{"ok": ...}` or `{"error": "..."}`.
/// Free the result with `talkwtf_free_string`.
char *talkwtf_invoke(const char *command, const char *payload_json);

/// Release a string returned by this library.
void talkwtf_free_string(char *value);

/// Register (or clear, passing NULL) the event callback.
void talkwtf_set_event_callback(TalkWtfEventCallback callback, void *userdata);

#ifdef __cplusplus
}
#endif

#endif // TALKWTF_H
