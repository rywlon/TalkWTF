import AppKit
import Carbon.HIToolbox
import Foundation

/// Drives dictation from the core's `hotkey` events: records through the Rust
/// core, then pastes the finished transcript into the frontmost app.
///
/// The activation mode (`shortcut_activation`) decides how press/release edges
/// map to recording, matching the Tauri app:
/// - `toggle`: press starts, press stops.
/// - `push_to_talk`: press starts, release stops.
/// - `hold_or_toggle`: a hold records while held; a tap locks recording on.
@MainActor
final class DictationController {
    static let shared = DictationController()

    private var recording = false
    private var activeMode = "dictation"
    private var pressStartedAt: Date?
    private var started = false

    /// Register for core events and start the core's hotkey listener.
    func start() {
        guard !started else { return }
        started = true
        do {
            try Core.invoke("start_hotkeys")
        } catch {
            NSLog("TalkWTF: failed to start hotkeys: \(error.localizedDescription)")
        }
        NotificationCenter.default.addObserver(
            forName: .talkWtfCoreEvent,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handle(raw: notification.object as? String)
        }
    }

    /// Menu-bar / tray entry point.
    func toggleFromTray() {
        recording ? stop(mode: activeMode) : begin(mode: "dictation")
    }

    /// Whether a recording is in flight (the overlay's buttons need to know).
    var isRecording: Bool { recording }

    /// Finish the current recording and paste the result — the overlay's ✓.
    func finish() {
        guard recording else { return }
        stop(mode: activeMode)
    }

    /// Throw the current recording away — the overlay's ✕.
    func discard() {
        guard recording else { return }
        recording = false
        pressStartedAt = nil
        SecureInputFallback.shared.setCancelActive(false)
        SoundPlayer.play(.stop)
        try? Core.invoke("cancel_dictation")
        OverlayController.shared.hide()
    }

    // MARK: - event routing

    private func handle(raw: String?) {
        guard
            let raw,
            let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["event"] as? String == "hotkey",
            let payload = object["payload"] as? [String: Any],
            let bindingId = payload["bindingId"] as? String,
            let pressed = payload["pressed"] as? Bool
        else { return }
        handle(bindingId: bindingId, pressed: pressed)
    }

    /// Shared by the tap (core `hotkey` events) and the Carbon shadows used
    /// while Secure Event Input is blocking the tap.
    func handle(bindingId: String, pressed: Bool) {
        let mode = bindingId == "translate" ? "translate" : "dictation"
        guard ["transcribe", "transcribe_with_post_process", "translate"].contains(bindingId) else {
            return
        }

        switch SettingsStore.shared.string("shortcut_activation", "hold_or_toggle") {
        case "toggle":
            if pressed { recording ? stop(mode: mode) : begin(mode: mode) }
        case "push_to_talk":
            if pressed { if !recording { begin(mode: mode) } } else if recording { stop(mode: mode) }
        default: // hold_or_toggle
            holdOrToggle(pressed: pressed, mode: mode)
        }
    }

    private func holdOrToggle(pressed: Bool, mode: String) {
        let threshold = Double(SettingsStore.shared.int("hold_threshold_ms", 300)) / 1000.0
        if pressed {
            if recording {
                stop(mode: mode)
            } else {
                pressStartedAt = Date()
                begin(mode: mode)
            }
        } else if recording, let started = pressStartedAt {
            // A tap keeps recording until the next press; a hold stops on release.
            if Date().timeIntervalSince(started) >= threshold {
                stop(mode: mode)
            }
            pressStartedAt = nil
        }
    }

    // MARK: - recording

    private func begin(mode: String) {
        do {
            try Core.invoke("start_dictation", ["mode": mode])
            recording = true
            activeMode = mode
            SecureInputFallback.shared.setCancelActive(true)
            // The core emits `overlay-state` (recording / streaming / notice), so
            // the panel is driven from there rather than from here.
            SoundPlayer.play(.start)
        } catch {
            NSLog("TalkWTF: failed to start dictation: \(error.localizedDescription)")
        }
    }

    private func stop(mode: String) {
        recording = false
        pressStartedAt = nil
        SecureInputFallback.shared.setCancelActive(false)
        SoundPlayer.play(.stop)
        // Transcription + polish take seconds; keep them off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let value = try Core.invoke("stop_dictation", ["mode": mode])
                let text = value as? String ?? ""
                DispatchQueue.main.async {
                    if !text.isEmpty {
                        Paster.paste(text)
                        // Watch the field we just wrote into, so a correction the
                        // user makes can be learned into the dictionary.
                        try? Core.invoke("watch_for_edit", ["text": text])
                    }
                    OverlayController.shared.hide()
                }
            } catch {
                NSLog("TalkWTF: dictation failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    // A failed translation keeps its retry card up; everything
                    // else has no state worth showing.
                    if !error.localizedDescription.contains("translation failed") {
                        OverlayController.shared.hide()
                    }
                }
            }
        }
    }
}

/// Pastes text into the frontmost app via the clipboard + a synthesized Cmd+V.
enum Paster {
    static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let source = CGEventSource(stateID: .hidSystemState)
        let vKey = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = CGEventFlags.maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = CGEventFlags.maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        if let previous {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
    }
}
