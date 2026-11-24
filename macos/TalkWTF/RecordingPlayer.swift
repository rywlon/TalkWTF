import AppKit
import SwiftUI

/// Plays a saved recording from the library.
///
/// One player at a time: starting another row stops the previous one, which is
/// what a list of recordings should do.
@MainActor
final class RecordingPlayer: ObservableObject {
    static let shared = RecordingPlayer()

    /// The history entry currently playing, if any.
    @Published private(set) var playingId: Int?
    @Published private(set) var error: String?

    private var sound: NSSound?

    func toggle(entryId: Int, fileName: String) {
        if playingId == entryId {
            stop()
            return
        }
        stop()
        error = nil

        guard let path = audioPath(for: fileName) else {
            error = L("settings.history.playError")
            return
        }
        guard let sound = NSSound(contentsOf: path, byReference: true) else {
            error = L("settings.history.playError")
            return
        }
        sound.delegate = SoundDelegate.shared
        SoundDelegate.shared.onFinish = { [weak self] in
            MainActor.assumeIsolated { self?.stop() }
        }
        sound.play()
        self.sound = sound
        playingId = entryId
    }

    func stop() {
        sound?.stop()
        sound = nil
        playingId = nil
    }

    private func audioPath(for fileName: String) -> URL? {
        guard let path = try? Core.invoke("get_audio_file_path", ["fileName": fileName]) as? String,
              !path.isEmpty
        else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// `NSSound` finishes on a callback; hop back to the main actor there.
private final class SoundDelegate: NSObject, NSSoundDelegate {
    static let shared = SoundDelegate()
    var onFinish: (() -> Void)?

    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        onFinish?()
    }
}

/// Play/stop button for one history row.
struct RecordingPlayButton: View {
    let entryId: Int
    let fileName: String
    @ObservedObject private var player = RecordingPlayer.shared

    var body: some View {
        Button {
            player.toggle(entryId: entryId, fileName: fileName)
        } label: {
            Image(systemName: player.playingId == entryId ? "stop.circle" : "play.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(fileName.isEmpty)
        .help(L(player.playingId == entryId ? "settings.history.stop" : "settings.history.play"))
        .accessibilityLabel(L(player.playingId == entryId ? "settings.history.stop" : "settings.history.play"))
    }
}
