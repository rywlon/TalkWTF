import AppKit
import Carbon.HIToolbox
import Foundation

/// Counts keyboard events for a few seconds so the debug pane can answer "are
/// my shortcuts even reaching TalkWTF?".
///
/// Only event *kinds* are counted — key identity is never captured, stored or
/// shown. Secure Event Input (password fields, Terminal's Secure Keyboard
/// Entry) makes CGEventTaps stop seeing key events while modifier changes still
/// flow, which is the most common reason a shortcut silently stops working.
@MainActor
final class KeyboardDiagnostic: ObservableObject {
    static let shared = KeyboardDiagnostic()

    struct Report {
        let keyDown: Int
        let keyUp: Int
        let flagsChanged: Int
        let mouse: Int
        let secureInputEnabled: Bool
        let durationSeconds: Int
    }

    @Published private(set) var running = false
    @Published private(set) var report: Report?
    @Published private(set) var error: String?
    @Published private(set) var liveCount = 0

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var counts = (down: 0, up: 0, flags: 0, mouse: 0)

    /// Listen for `seconds` (clamped to 3...30) and publish a report.
    func run(seconds: Int = 10) {
        guard !running else { return }
        let duration = min(30, max(3, seconds))
        counts = (0, 0, 0, 0)
        liveCount = 0
        report = nil
        error = nil

        // Listen-only: the tap observes events and can never swallow them.
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                // Listen-only taps must return the event unchanged.
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let diagnostic = Unmanaged<KeyboardDiagnostic>.fromOpaque(userInfo)
                    .takeUnretainedValue()
                MainActor.assumeIsolated { diagnostic.record(type) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            error = L("settings.debug.keyboardDiagnostic.failed", ["error": "no event tap"])
            return
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        running = true

        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(duration)) { [weak self] in
            self?.finish(duration: duration)
        }
    }

    /// Stop early; the partial counts still produce a report.
    func stop() {
        guard running else { return }
        finish(duration: 0)
    }

    private func record(_ type: CGEventType) {
        switch type {
        case .keyDown: counts.down += 1
        case .keyUp: counts.up += 1
        case .flagsChanged: counts.flags += 1
        default: counts.mouse += 1
        }
        liveCount = counts.down + counts.up + counts.flags + counts.mouse
    }

    private func finish(duration: Int) {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        source = nil
        running = false

        let secure = (try? Core.invoke("is_secure_input_enabled") as? Bool) ?? false
        report = Report(
            keyDown: counts.down,
            keyUp: counts.up,
            flagsChanged: counts.flags,
            mouse: counts.mouse,
            secureInputEnabled: secure,
            durationSeconds: duration
        )
    }

    /// The one-line explanation shown under the counters.
    func verdict() -> String? {
        guard let report else { return nil }
        if report.secureInputEnabled && report.keyDown == 0 {
            return L("settings.debug.keyboardDiagnostic.verdictBlocked")
        }
        if report.keyDown == 0 && report.keyUp == 0 {
            return report.flagsChanged > 0
                ? L("settings.debug.keyboardDiagnostic.verdictSuspicious")
                : L("settings.debug.keyboardDiagnostic.verdictNoEvents")
        }
        return L("settings.debug.keyboardDiagnostic.verdictOk")
    }
}
