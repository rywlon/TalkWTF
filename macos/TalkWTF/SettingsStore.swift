import Foundation
import SwiftUI

/// Observable settings, read from and written to the Rust core.
///
/// The core is the single source of truth (it owns `settings_store.json`); this
/// just republishes the dictionary so SwiftUI can bind to it.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published private(set) var settings: [String: Any] = [:]
    @Published private(set) var error: String?

    func load() {
        do {
            settings = try Core.appSettings()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Typed read with a fallback.
    func value<T>(_ key: String, _ fallback: T) -> T {
        settings[key] as? T ?? fallback
    }

    func string(_ key: String, _ fallback: String = "") -> String {
        settings[key] as? String ?? fallback
    }

    func bool(_ key: String, _ fallback: Bool = false) -> Bool {
        settings[key] as? Bool ?? fallback
    }

    func int(_ key: String, _ fallback: Int = 0) -> Int {
        (settings[key] as? NSNumber)?.intValue ?? fallback
    }

    func double(_ key: String, _ fallback: Double = 0) -> Double {
        (settings[key] as? NSNumber)?.doubleValue ?? fallback
    }

    func array(_ key: String) -> [Any] {
        settings[key] as? [Any] ?? []
    }

    func stringArray(_ key: String) -> [String] {
        settings[key] as? [String] ?? []
    }

    /// Merge a partial patch and reload.
    @discardableResult
    func patch(_ values: [String: Any]) -> Bool {
        do {
            try Core.updateSettings(values)
            load()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Binding for a string setting.
    func binding(_ key: String, default fallback: String) -> Binding<String> {
        Binding(get: { [weak self] in self?.string(key, fallback) ?? fallback },
                set: { [weak self] in self?.patch([key: $0]) })
    }

    func boolBinding(_ key: String, default fallback: Bool = false) -> Binding<Bool> {
        Binding(get: { [weak self] in self?.bool(key, fallback) ?? fallback },
                set: { [weak self] in self?.patch([key: $0]) })
    }

    func intBinding(_ key: String, default fallback: Int = 0) -> Binding<Int> {
        Binding(get: { [weak self] in self?.int(key, fallback) ?? fallback },
                set: { [weak self] in self?.patch([key: $0]) })
    }

    func doubleBinding(_ key: String, default fallback: Double = 0) -> Binding<Double> {
        Binding(get: { [weak self] in self?.double(key, fallback) ?? fallback },
                set: { [weak self] in self?.patch([key: $0]) })
    }

    /// Binding for an enum-ish string setting with a fixed set of options.
    func pickerBinding(_ key: String, default fallback: String) -> Binding<String> {
        binding(key, default: fallback)
    }

    /// Replace the whole scene list (the core validates).
    func setScenes(_ scenes: [[String: Any]], activeSceneId: String?) {
        var patch: [String: Any] = ["scenes": scenes]
        patch["active_scene_id"] = activeSceneId ?? NSNull()
        self.patch(patch)
    }
}
