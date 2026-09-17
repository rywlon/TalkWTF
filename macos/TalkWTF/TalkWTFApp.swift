import SwiftUI

@main
struct TalkWTFApp: App {
    init() {
        // Register the core's event channel once, before any UI appears.
        talkwtf_set_event_callback(handleCoreEvent, nil)
    }

    var body: some Scene {
        WindowGroup {
            AppShell()
                .frame(
                    minWidth: Theme.Layout.windowMinWidth,
                    minHeight: Theme.Layout.windowMinHeight
                )
        }
        .defaultSize(width: Theme.Layout.windowWidth, height: Theme.Layout.windowHeight)
        .windowToolbarStyle(.unifiedCompact)
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
