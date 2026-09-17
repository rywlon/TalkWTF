import AppKit
import SwiftUI

/// Captures a key combination for a binding.
///
/// The core's listener is paused while recording so the user's existing
/// shortcuts cannot fire (or swallow the keystroke) mid-capture. The captured
/// press is handed to the core, which owns the `handy-keys` spelling and
/// validates it, so a binding the UI accepts is always registrable.
@MainActor
final class ShortcutRecorder: ObservableObject {
    static let shared = ShortcutRecorder()

    /// The binding currently being recorded, if any.
    @Published private(set) var recording: String?
    /// Live preview of the combination held so far.
    @Published private(set) var preview = ""
    @Published private(set) var error: String?

    private var monitor: Any?
    private var heldModifiers: [UInt16: String] = [:]

    /// Physical modifier keys, with the side the user actually pressed.
    private static let modifierNames: [UInt16: String] = [
        55: "cmd_left", 54: "cmd_right",
        56: "shift_left", 60: "shift_right",
        58: "option_left", 61: "option_right",
        59: "ctrl_left", 62: "ctrl_right",
    ]

    func begin(_ bindingId: String) {
        guard recording == nil else { return }
        error = nil
        // Never leave the label empty: the row has to say what to do next.
        preview = L("settings.general.shortcut.pressKeys")
        heldModifiers = [:]
        recording = bindingId

        // Existing shortcuts must not fire while the user is pressing keys.
        try? Core.invoke("stop_hotkeys")

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {
            [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) }
        }
    }

    func cancel() {
        finish()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .flagsChanged:
            updateHeldModifiers(event)
            preview = describe(modifiers: currentModifiers(event), key: nil)
            return nil

        case .keyDown:
            // Escape always cancels: it is the one key the user needs to get out.
            if event.keyCode == 53 {
                finish()
                return nil
            }
            let modifiers = currentModifiers(event)
            guard let binding = buildBinding(keyCode: event.keyCode, modifiers: modifiers) else {
                error = L("settings.general.shortcut.errors.set", ["error": "unsupported key"])
                finish()
                return nil
            }
            save(binding)
            return nil

        default:
            return event
        }
    }

    private func updateHeldModifiers(_ event: NSEvent) {
        guard let name = Self.modifierNames[event.keyCode] else { return }
        let flag = Self.flag(for: event.keyCode)
        if event.modifierFlags.contains(flag) {
            heldModifiers[event.keyCode] = name
        } else {
            heldModifiers.removeValue(forKey: event.keyCode)
        }
    }

    private static func flag(for keyCode: UInt16) -> NSEvent.ModifierFlags {
        switch keyCode {
        case 55, 54: return .command
        case 56, 60: return .shift
        case 58, 61: return .option
        case 59, 62: return .control
        default: return []
        }
    }

    /// Modifiers for a key press.
    ///
    /// `heldModifiers` is the accurate source because it carries the side the
    /// user pressed, but it only fills in from `flagsChanged`. The event's own
    /// flags are the fallback, so a synthesised press (or one where a
    /// `flagsChanged` was coalesced away) still records its modifiers — just
    /// without a side.
    private func currentModifiers(_ event: NSEvent) -> [String] {
        var names = Set(heldModifiers.values)
        let flags = event.modifierFlags

        func add(_ flag: NSEvent.ModifierFlags, sidePrefix: String, compound: String) {
            guard flags.contains(flag) else { return }
            if !names.contains(where: { $0.hasPrefix(sidePrefix) }) { names.insert(compound) }
        }
        add(.command, sidePrefix: "cmd", compound: "cmd")
        add(.shift, sidePrefix: "shift", compound: "shift")
        add(.option, sidePrefix: "option", compound: "option")
        add(.control, sidePrefix: "ctrl", compound: "ctrl")

        // fn has no side and no separate key code; the flag is the only signal.
        if flags.contains(.function) { names.insert("fn") }

        return names.sorted()
    }

    private func describe(modifiers: [String], key: String?) -> String {
        var parts = modifiers
        if let key { parts.append(key) }
        return parts.isEmpty ? L("settings.general.shortcut.pressKeys") : parts.joined(separator: "+")
    }

    /// Ask the core for the canonical spelling and validate it in one step.
    private func buildBinding(keyCode: UInt16, modifiers: [String]) -> String? {
        (try? Core.invoke("build_binding", [
            "keyCode": Int(keyCode),
            "modifiers": modifiers,
        ])) as? String
    }

    private func save(_ binding: String) {
        guard let bindingId = recording else { return }
        do {
            _ = try Core.invoke("set_binding", ["id": bindingId, "hotkey": binding])
            error = nil
            // The row renders from the store, so pick the new value up.
            SettingsStore.shared.load()
        } catch {
            self.error = L("settings.general.shortcut.errors.set", ["error": error.localizedDescription])
        }
        finish()
    }

    private func finish() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        recording = nil
        preview = ""
        heldModifiers = [:]
        // Restore the listener with whatever is now stored.
        try? Core.invoke("start_hotkeys")
    }
}
