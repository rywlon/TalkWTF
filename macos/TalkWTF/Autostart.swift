import Foundation
import ServiceManagement

/// Launch-at-login, via `SMAppService` so System Settings attributes the item
/// to this app bundle instead of a developer certificate.
///
/// Errors are logged rather than surfaced: the preference is re-applied on
/// every launch, so a transient failure self-heals and must not block startup.
enum Autostart {
    static func apply(_ enabled: Bool) {
        let service = SMAppService.mainApp

        if enabled {
            guard service.status != .enabled else { return }
            do {
                try service.register()
                NSLog("TalkWTF: registered login item")
            } catch {
                NSLog("TalkWTF: failed to register login item: \(error.localizedDescription)")
            }
        } else {
            guard service.status != .notRegistered, service.status != .notFound else { return }
            do {
                try service.unregister()
                NSLog("TalkWTF: unregistered login item")
            } catch {
                NSLog("TalkWTF: failed to unregister login item: \(error.localizedDescription)")
            }
        }
    }

    /// Remove the launch agent plist older builds wrote, so login does not start
    /// the app twice. Missing file is the normal case.
    static func removeLegacyLaunchAgent() {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "TalkWTF"
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(name).plist")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        do {
            try FileManager.default.removeItem(at: path)
            NSLog("TalkWTF: removed legacy launch agent \(path.path)")
        } catch {
            NSLog("TalkWTF: failed to remove legacy launch agent: \(error.localizedDescription)")
        }
    }
}
