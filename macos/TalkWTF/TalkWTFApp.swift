import SwiftUI

@main
struct TalkWTFApp: App {
    init() {
        // Register the core's event channel once, before any UI appears.
        talkwtf_set_event_callback(handleCoreEvent, nil)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// C callback invoked from the Rust core (on a Rust thread). Bounce to the main
/// thread so SwiftUI can observe it.
func handleCoreEvent(_ eventJson: UnsafePointer<CChar>?, _ userdata: UnsafeMutableRawPointer?) {
    guard let eventJson else { return }
    let json = String(cString: eventJson)
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .talkWtfCoreEvent, object: json)
    }
}

extension Notification.Name {
    static let talkWtfCoreEvent = Notification.Name("talkWtfCoreEvent")
}
