import AppKit
import Carbon.HIToolbox
import Foundation

/// Carbon hotkeys used while Secure Event Input blocks the core's event tap.
///
/// A password field, Terminal's Secure Keyboard Entry, or a stuck `loginwindow`
/// makes CGEventTaps stop seeing key events. The core's `handy-keys` listener is
/// tap-based, so keyed shortcuts go silent — modifier-only ones keep working
/// because `FlagsChanged` still flows.
///
/// Carbon hotkeys are handled by the window server, so they are unaffected. The
/// core decides *what* to shadow (which bindings, widened modifiers, what cannot
/// be expressed) and emits `secure-input-changed`; this class does the
/// registration and feeds the presses back through the same `hotkey` events the
/// tap produces, so the rest of the app cannot tell the difference.
@MainActor
final class SecureInputFallback {
    static let shared = SecureInputFallback()

    /// The shell's handler for a binding edge — wired to `DictationController`.
    var onHotkey: ((String, Bool) -> Void)?

    private var registered: [String: EventHotKeyRef] = [:]
    private var bindingByHotKeyId: [UInt32: String] = [:]
    private var handler: EventHandlerRef?
    private var nextId: UInt32 = 1
    private var active = false
    private var started = false

    /// Subscribe to the core's secure-input events and start the monitor.
    func start() {
        guard !started else { return }
        started = true
        installHandlerIfNeeded()
        NotificationCenter.default.addObserver(
            forName: .talkWtfCoreEvent,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let raw = note.object as? String, raw.contains("secure-input-changed") else { return }
            MainActor.assumeIsolated { self?.apply(raw: raw) }
        }
        try? Core.invoke("start_secure_input_monitor")
    }

    /// Tell the core whether the cancel binding should be shadowed too.
    func setCancelActive(_ isActive: Bool) {
        try? Core.invoke("set_cancel_shadow_active", ["active": isActive])
    }

    // MARK: - plan application

    private func apply(raw: String) {
        guard
            let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["event"] as? String == "secure-input-changed",
            let payload = object["payload"] as? [String: Any]
        else { return }

        let sustained = payload["sustained"] as? Bool ?? false
        let shadows = payload["shadows"] as? [[String: Any]] ?? []

        guard sustained, !shadows.isEmpty else {
            if active { releaseAll() }
            return
        }

        // Keep registrations that are still wanted: Carbon sends the release to
        // the registration that received the press, so replacing a held
        // push-to-talk shadow would swallow its release.
        var wanted: [String: (keyCode: UInt32, modifiers: UInt32)] = [:]
        for shadow in shadows {
            guard
                let bindingId = shadow["binding_id"] as? String,
                let keyCode = shadow["key_code"] as? NSNumber,
                let modifiers = shadow["modifiers"] as? NSNumber
            else { continue }
            wanted[bindingId] = (keyCode.uint32Value, modifiers.uint32Value)
        }

        let stale = registered.keys.filter { wanted[$0] == nil }
        for bindingId in stale { unregister(bindingId) }

        for (bindingId, spec) in wanted where registered[bindingId] == nil {
            register(bindingId, keyCode: spec.keyCode, modifiers: spec.modifiers)
        }

        active = !registered.isEmpty
        if active {
            NSLog("TalkWTF: secure input — \(registered.count) Carbon shadow(s) active")
        }
    }

    private func register(_ bindingId: String, keyCode: UInt32, modifiers: UInt32) {
        let id = nextId
        nextId += 1
        var hotKeyId = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyId,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            NSLog("TalkWTF: Carbon shadow for '\(bindingId)' failed (status \(status))")
            return
        }
        _ = hotKeyId
        registered[bindingId] = ref
        bindingByHotKeyId[id] = bindingId
    }

    private func unregister(_ bindingId: String) {
        guard let ref = registered.removeValue(forKey: bindingId) else { return }
        UnregisterEventHotKey(ref)
        if let id = bindingByHotKeyId.first(where: { $0.value == bindingId })?.key {
            bindingByHotKeyId.removeValue(forKey: id)
        }
    }

    private func releaseAll() {
        for bindingId in registered.keys { unregister(bindingId) }
        active = false
        NSLog("TalkWTF: secure input ended — Carbon shadows released")
    }

    // MARK: - Carbon handler

    private static let signature: OSType = {
        // 'TWTF'
        let bytes: [UInt8] = [0x54, 0x57, 0x54, 0x46]
        return bytes.reduce(OSType(0)) { ($0 << 8) | OSType($1) }
    }()

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyId = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyId
            )
            guard status == noErr else { return OSStatus(eventNotHandledErr) }

            let isPress = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let instance = Unmanaged<SecureInputFallback>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                guard let bindingId = instance.bindingByHotKeyId[hotKeyId.id] else { return }
                instance.onHotkey?(bindingId, isPress)
            }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
    }
}
