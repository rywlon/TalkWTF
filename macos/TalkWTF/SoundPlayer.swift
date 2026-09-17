import AppKit
import Foundation

/// Recording start/stop feedback sounds.
///
/// The core used `rodio` + cpal on the Tauri side; the native shell plays the
/// same bundled wavs with `NSSound`, which also honours the selected output
/// device through the system default route.
@MainActor
enum SoundPlayer {
    enum Kind { case start, stop }

    /// Play the feedback sound for `kind`, honouring the user's settings.
    static func play(_ kind: Kind) {
        let store = SettingsStore.shared
        guard store.bool("audio_feedback") else { return }
        guard let url = url(for: kind) else { return }
        play(url, volume: store.double("audio_feedback_volume", 1.0))
    }

    /// Play a sound regardless of the `audio_feedback` toggle (settings preview).
    static func playPreview(_ kind: Kind) {
        guard let url = url(for: kind) else { return }
        play(url, volume: SettingsStore.shared.double("audio_feedback_volume", 1.0))
    }

    private static func play(_ url: URL, volume: Double) {
        guard let sound = NSSound(contentsOf: url, byReference: true) else {
            NSLog("TalkWTF: could not load sound \(url.lastPathComponent)")
            return
        }
        sound.volume = Float(max(0, min(1, volume)))
        sound.play()
    }

    /// Resolve the wav for the current theme: bundled themes live in
    /// `resources/`, the custom theme in the app data directory.
    private static func url(for kind: Kind) -> URL? {
        let suffix = kind == .start ? "start" : "stop"
        let theme = SettingsStore.shared.string("sound_theme", "marimba")

        if theme == "custom" {
            let custom = AppPaths.dataDirectory.appendingPathComponent("custom_\(suffix).wav")
            if FileManager.default.fileExists(atPath: custom.path) { return custom }
        }

        let name = "\(theme)_\(suffix)"
        return Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "resources")
    }
}
