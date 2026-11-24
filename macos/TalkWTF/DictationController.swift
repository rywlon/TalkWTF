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

    private var processing = false
    private var destination: AgentTarget?
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

    /// Start or stop a recording from a button, independent of the hotkey's
    /// activation mode. `mode` is `dictation`, `translate`, or an `agent_` id.
    func toggle(mode: String) {
        guard !processing, !AgentHub.shared.sending else { return }
        if recording { stop(mode: activeMode) } else { begin(mode: mode) }
    }

    /// True while a finished recording is being transcribed/pasted.
    var isBusy: Bool { processing }

    /// Finish the current recording and paste the result — the overlay's ✓.
    func finish() {
        guard recording else { return }
        stop(mode: activeMode)
    }

    /// Throw the current recording away — the overlay's ✕.
    func discard() {
        guard recording else { return }
        recording = false
        destination = nil
        AgentHub.shared.recordingTarget = nil
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
        guard !processing, !AgentHub.shared.sending else { return }
        let mode = bindingId.hasPrefix("agent_") ? bindingId : bindingId == "translate" ? "translate" : "dictation"
        guard bindingId.hasPrefix("agent_") || ["transcribe", "transcribe_with_post_process", "translate"].contains(bindingId) else {
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
        guard !processing, !AgentHub.shared.sending else { return }
        let isRouter = mode == AgentHub.routerBindingID
        let target = mode.hasPrefix("agent_") && !isRouter
            ? AgentHub.shared.targets.first { $0.bindingID == mode } : nil
        if isRouter {
            guard !AgentHub.shared.targets.isEmpty else {
                OverlayController.shared.show(.agentMessage(
                    text: "还没有连接 Agent，先在 TalkWTF 里连一个。", failed: true))
                return
            }
            guard AgentHub.shared.failedText == nil else {
                OverlayController.shared.show(.agentMessage(text: "上次内容尚未处理，请先打开 TalkWTF 复制或清除。", failed: true))
                return
            }
        } else if mode.hasPrefix("agent_") {
            guard let target else { return }
            guard AgentHub.shared.failedText == nil else {
                OverlayController.shared.show(.agentMessage(text: "上次内容尚未处理，请先打开 TalkWTF 复制或清除。", failed: true))
                return
            }
            do { try AgentTransport.validate(target) }
            catch {
                OverlayController.shared.show(.agentMessage(text: error.localizedDescription, failed: true))
                return
            }
        }
        do {
            try Core.invoke("start_dictation", ["mode": mode == "translate" ? "translate" : "dictation"])
            destination = target
            AgentHub.shared.recordingTarget = target
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
        guard recording else { return }
        let pipelineMode = activeMode == "translate" ? "translate" : "dictation"
        let isRouter = activeMode == AgentHub.routerBindingID
        let target = destination
        destination = nil
        recording = false
        processing = true
        pressStartedAt = nil
        SecureInputFallback.shared.setCancelActive(false)
        SoundPlayer.play(.stop)
        // Transcription + polish take seconds; keep them off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let value = try Core.invoke("stop_dictation", ["mode": pipelineMode])
                let text = value as? String ?? ""
                DispatchQueue.main.async {
                    self.processing = false
                    AgentHub.shared.recordingTarget = nil
                    if isRouter {
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            OverlayController.shared.show(.agentMessage(text: "没有识别到内容，请重新录音。", failed: true))
                        } else {
                            AgentHub.shared.route(text)
                        }
                        return
                    }
                    if let target {
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            OverlayController.shared.show(.agentMessage(text: "没有识别到内容，请重新录音。", failed: true))
                        } else {
                            AgentHub.shared.deliver(text, to: target)
                        }
                        return
                    }
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
                    self.processing = false
                    AgentHub.shared.recordingTarget = nil
                    if target != nil {
                        OverlayController.shared.show(.agentMessage(text: error.localizedDescription, failed: true))
                        return
                    }
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
