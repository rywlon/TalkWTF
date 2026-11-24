import SwiftUI

@main
struct TalkWTFApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Read before the scene is built, since the core (which owns the settings
    /// file) is not up yet at that point.
    private let startHidden = LaunchSettings.startHidden()

    init() {
        if let status = AgentPairing.handleCommandLine(ProcessInfo.processInfo.arguments) { exit(status) }
        // Register the core's event channel once, before any UI appears.
        talkwtf_set_event_callback(handleCoreEvent, nil)
    }

    var body: some Scene {
        WindowGroup(id: "main") { shell }
            .defaultSize(width: Theme.Layout.windowWidth, height: Theme.Layout.windowHeight)
            .windowToolbarStyle(.unifiedCompact)
    }

    private var shell: some View {
        AppShell()
            .frame(
                minWidth: Theme.Layout.windowMinWidth,
                minHeight: Theme.Layout.windowMinHeight
            )
    }
}

/// Launch-time reads of the core-owned settings file, available before the
/// engine initializes.
enum LaunchSettings {
    static func startHidden() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.talkwtf.app/settings_store.json")
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let settings = object["settings"] as? [String: Any]
        else { return false }
        return settings["start_hidden"] as? Bool ?? false
    }
}

/// TalkWTF is a menu-bar app (`LSUIElement`): it has no Dock presence until a
/// window is open, then hands the Dock icon and app menus back while one is.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        WindowActivationController.shared.start()
        if LaunchSettings.startHidden() {
            suppressLaunchWindow()
        }
    }

    /// "Start hidden": SwiftUI auto-presents the launch window, so hide it as
    /// soon as it exists. A couple of retries cover it being created a moment
    /// after launch; the tray can still open it later.
    private func suppressLaunchWindow() {
        func hide() {
            for window in NSApp.windows where !(window is NSPanel) && window.canBecomeMain {
                window.orderOut(nil)
            }
        }
        hide()
        DispatchQueue.main.async(execute: hide)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: hide)
    }

    /// Closing the last window leaves the app running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// Flips the app between accessory (menu-bar only) and regular (Dock icon +
/// menus) based on whether a normal window is visible. Panels such as the
/// dictation overlay never count.
@MainActor
final class WindowActivationController {
    static let shared = WindowActivationController()
    private var observing = false

    func start() {
        guard !observing else { return }
        observing = true
        let center = NotificationCenter.default
        for name in [
            NSWindow.didBecomeMainNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
        ] {
            center.addObserver(self, selector: #selector(refresh), name: name, object: nil)
        }
        refresh()
    }

    /// Defer a tick so `willClose`/miniaturize notifications are reflected in
    /// the window list before deciding.
    @objc private func refresh() {
        DispatchQueue.main.async { [weak self] in self?.apply() }
    }

    private func apply() {
        // Only a real content window counts: exclude panels (the overlay) and
        // the menu bar item's `NSStatusBarWindow` (which lives at `.statusBar`).
        let hasWindow = NSApp.windows.contains { window in
            window.isVisible
                && window.level == .normal
                && window.canBecomeMain
                && !(window is NSPanel)
        }
        let desired: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != desired else { return }
        NSApp.setActivationPolicy(desired)
        if desired == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// C callback invoked from the Rust core (on a Rust thread). Bounce to the main
/// thread and route the envelope `{ "event": name, "payload": … }`.
func handleCoreEvent(_ eventJson: UnsafePointer<CChar>?, _ userdata: UnsafeMutableRawPointer?) {
    guard let eventJson else { return }
    let raw = String(cString: eventJson)
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .talkWtfCoreEvent, object: raw)

        guard
            let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let name = object["event"] as? String
        else { return }

        if name == "mic-level", let levels = object["payload"] as? [Double] {
            NotificationCenter.default.post(
                name: .talkWtfMicLevel,
                object: levels.map { CGFloat($0) }
            )
        }
    }
}

extension Notification.Name {
    static let talkWtfCoreEvent = Notification.Name("talkWtfCoreEvent")
    static let talkWtfMicLevel = Notification.Name("talkWtfMicLevel")
}
