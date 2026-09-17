import AVFoundation
import AppKit
import ApplicationServices
import Foundation

/// System permission checks and prompts the app needs before it can dictate.
enum Permissions {
    /// Microphone: needed by the core's audio capture.
    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Accessibility: needed to read the focused field (auto-learn) and to paste
    /// with a synthesized Cmd+V.
    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Ask for the microphone (shows the system prompt once).
    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    /// Ask for Accessibility, opening the privacy pane when it is missing.
    /// macOS only shows the prompt once, so a second call just returns the state.
    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Open the Accessibility privacy pane (for users who dismissed the prompt).
    static func openAccessibilitySettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
        if let url { NSWorkspace.shared.open(url) }
    }
}
