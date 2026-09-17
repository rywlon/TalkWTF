import AppKit
import SwiftUI

/// The overlay's state machine. Core drives it with `overlay-state` and
/// `learned-overlay` events; the panel only renders.
enum OverlayState: Equatable {
    case recording
    case streaming
    case transcribing
    case processing(label: String?)
    case translating(label: String?)
    case translationFailed(label: String)
    case notice(kind: String)
    case learned(pattern: String, replacement: String, count: Int)

    /// Transient states hide themselves; the rest stay until the shell acts.
    var autoHideAfter: TimeInterval? {
        switch self {
        case .learned, .translationFailed, .notice: return 8
        default: return nil
        }
    }

    /// Fixed geometry per state (see the design system's overlay table).
    var size: CGSize {
        switch self {
        case .recording, .streaming: return Theme.Overlay.recordingSize
        case .transcribing, .processing, .translating: return Theme.Overlay.workingSize
        case .translationFailed, .notice, .learned: return Theme.Overlay.cardSize
        }
    }

    /// A pill while recording, a roomier card for text states.
    var cornerRadius: CGFloat {
        switch self {
        case .recording, .streaming, .transcribing, .processing, .translating:
            return Theme.Overlay.recordingRadius
        case .translationFailed, .notice, .learned:
            return Theme.Overlay.cardRadius
        }
    }
}

/// Observable bridge between the core's events and the SwiftUI panel.
@MainActor
final class OverlayModel: ObservableObject {
    @Published var state: OverlayState = .recording
    @Published var levels: [CGFloat] = Array(repeating: 0.15, count: 18)

    func setLevels(_ values: [CGFloat]) {
        guard !values.isEmpty else { return }
        // Mirror the spectrum around the centre bar: the strongest (lowest)
        // buckets land in the middle and the shape tapers outward, so it reads
        // as pulsing from the centre instead of sweeping from the left.
        let count = 18
        let centre = (count - 1) / 2
        levels = (0 ..< count).map { index in
            let distance = abs(index - centre)
            let bucket = min(values.count - 1, distance * values.count / (centre + 1))
            return max(0.12, min(1.0, values[bucket]))
        }
    }
}

/// Owns the overlay panel and translates core events into state changes.
@MainActor
final class OverlayController {
    static let shared = OverlayController()

    let model = OverlayModel()
    private var panel: OverlayPanel?

    /// Subscribe to the core's events. Call once, after the core is up.
    func start() {
        let center = NotificationCenter.default
        center.addObserver(forName: .talkWtfCoreEvent, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.handle(raw: note.object as? String) }
        }
        center.addObserver(forName: .talkWtfMicLevel, object: nil, queue: .main) { [weak self] note in
            guard let levels = note.object as? [CGFloat] else { return }
            MainActor.assumeIsolated { self?.model.setLevels(levels) }
        }
    }

    /// Show the panel in `state`, optionally next to the field it refers to.
    func show(_ state: OverlayState, near frame: CGRect? = nil) {
        model.state = state
        let panel = panel ?? OverlayPanel(model: model)
        self.panel = panel
        panel.show(autoHideAfter: state.autoHideAfter, near: frame)
    }

    func hide() {
        panel?.hide()
    }

    private func handle(raw: String?) {
        guard
            let raw,
            let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let name = object["event"] as? String
        else { return }

        switch name {
        case "overlay-state":
            guard let payload = object["payload"] as? [String: Any],
                  let state = payload["state"] as? String else { return }
            let label = payload["label"] as? String
            let kind = payload["kind"] as? String
            show(Self.decode(state: state, label: label, kind: kind))
        case "learned-overlay":
            guard let payload = object["payload"] as? [String: Any],
                  let notice = payload["notice"] as? [String: Any] else { return }
            show(
                .learned(
                    pattern: notice["pattern"] as? String ?? "",
                    replacement: notice["replacement"] as? String ?? "",
                    count: (notice["count"] as? NSNumber)?.intValue ?? 1
                ),
                near: Self.rect(from: payload["frame"])
            )
        default:
            break
        }
    }

    private static func decode(state: String, label: String?, kind: String?) -> OverlayState {
        switch state {
        case "recording": return .recording
        case "streaming": return .streaming
        case "transcribing": return .transcribing
        case "processing": return .processing(label: label)
        case "translating": return .translating(label: label)
        case "translation_failed": return .translationFailed(label: label ?? "")
        case "notice": return .notice(kind: kind ?? "")
        default: return .recording
        }
    }

    /// AX frames are `[x, y, width, height]` in top-left screen coordinates.
    private static func rect(from value: Any?) -> CGRect? {
        guard let values = value as? [NSNumber], values.count == 4 else { return nil }
        return CGRect(
            x: values[0].doubleValue,
            y: values[1].doubleValue,
            width: values[2].doubleValue,
            height: values[3].doubleValue
        )
    }
}

/// A non-activating floating panel that hosts the recording overlay.
///
/// Native `NSPanel` + SwiftUI so the pill can use the real macOS 26 Liquid Glass
/// (`glassEffect`), which a webview cannot render.
@MainActor
final class OverlayPanel {
    private let model: OverlayModel
    private var panel: NSPanel?

    init(model: OverlayModel) {
        self.model = model
    }

    /// Show the overlay, optionally auto-hiding after `autoHideAfter` seconds and
    /// placed next to `near` (top-left screen coordinates).
    func show(autoHideAfter seconds: TimeInterval?, near: CGRect? = nil) {
        let panel = existingOrCreate()
        panel.setContentSize(model.state.size)
        reposition(panel, near: near)
        panel.orderFrontRegardless()

        if let seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.hide()
            }
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func existingOrCreate() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Theme.Overlay.recordingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = false

        let hosting = NSHostingView(rootView: OverlayView(model: model))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        self.panel = panel
        return panel
    }

    /// Place next to the focused field when we know where it is, otherwise
    /// centred on the screen the pointer is on.
    private func reposition(_ panel: NSPanel, near: CGRect?) {
        let size = panel.frame.size

        if let near, let screen = screenContaining(near) {
            // AX y is top-left based; AppKit is bottom-left based.
            let cocoaY = screen.frame.maxY - near.maxY
            let x = near.minX.clamped(to: screen.frame.minX ... (screen.frame.maxX - size.width))
            let y = (cocoaY - size.height - 8)
                .clamped(to: screen.frame.minY ... (screen.frame.maxY - size.height))
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let frame = screen.visibleFrame
        let x = (frame.midX - size.width / 2).clamped(to: frame.minX ... (frame.maxX - size.width))
        let y = (frame.maxY - size.height - 12).clamped(to: frame.minY ... (frame.maxY - size.height))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func screenContaining(_ rect: CGRect) -> NSScreen? {
        NSScreen.screens.first { screen in
            let topLeft = CGRect(
                x: screen.frame.minX,
                y: screen.frame.maxY - screen.frame.height,
                width: screen.frame.width,
                height: screen.frame.height
            )
            return topLeft.intersects(rect)
        }
    }
}

/// The overlay content: a glass rounded rectangle whose body depends on the
/// state the core reported.
struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: model.state.cornerRadius)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: model.state.cornerRadius))
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            switch model.state {
            case .recording, .streaming:
                if hovering {
                    discardButton
                    finishButton
                } else {
                    Circle().fill(.tint).frame(width: 8, height: 8)
                    waveform
                }
            case .transcribing:
                spinner
                Text(L("overlay.transcribing")).font(Theme.Fonts.callout)
                Spacer(minLength: 0)
            case .processing(let label):
                spinner
                Text(label.map { L("overlay.translate.to", ["label": $0]) } ?? L("overlay.processing"))
                    .font(Theme.Fonts.callout)
                Spacer(minLength: 0)
            case .translating(let label):
                spinner
                Text(label.map { L("overlay.translate.to", ["label": $0]) } ?? L("overlay.translate.working"))
                    .font(Theme.Fonts.callout)
                Spacer(minLength: 0)
            case .translationFailed(let label):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(L("overlay.translate.failed", ["label": label])).font(Theme.Fonts.callout)
                Spacer(minLength: 0)
                Button(L("overlay.translate.retry")) { retry() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            case .notice(let kind):
                Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
                Text(kind == "no_target"
                    ? L("overlay.translate.noTarget")
                    : L("overlay.translate.failed", ["label": ""]))
                    .font(Theme.Fonts.callout)
                Spacer(minLength: 0)
            case .learned(let pattern, let replacement, let count):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(count > 1
                    ? L("overlay.learned.titlePlural", ["count": count])
                    : L("overlay.learned.title", ["pattern": pattern, "replacement": replacement]))
                    .font(Theme.Fonts.callout)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(L("overlay.learned.undo")) { undo() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .frame(width: model.state.size.width, height: model.state.size.height)
        .opacity(hovering && isRecordingState ? 0.92 : 1)
        .onHover { hovering = $0 }
    }

    /// Symmetric bars around a fixed centre line, so growth is visibly centred.
    private var waveform: some View {
        HStack(spacing: 3) {
            ForEach(model.levels.indices, id: \.self) { index in
                Capsule()
                    .fill(.tint)
                    .frame(width: 3, height: max(4, model.levels[index] * 30))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .animation(.easeInOut(duration: 0.12), value: model.levels)
    }

    private var isRecordingState: Bool {
        if case .recording = model.state { return true }
        if case .streaming = model.state { return true }
        return false
    }

    private var spinner: some View {
        ProgressView().controlSize(.small)
    }

    /// Hovering dims the pill and swaps the waveform for the two actions, like
    /// Spokenly: throw the recording away, or finish and paste it.
    private var discardButton: some View {
        Button {
            DictationController.shared.discard()
        } label: {
            Label(L("overlay.discard"), systemImage: "xmark")
                .labelStyle(.iconOnly)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(.quaternary, in: Circle())
        }
        .buttonStyle(.plain)
        .help(L("overlay.discard"))
        .accessibilityLabel(L("overlay.discard"))
    }

    private var finishButton: some View {
        Button {
            DictationController.shared.finish()
        } label: {
            Label(L("overlay.finish"), systemImage: "checkmark")
                .labelStyle(.iconOnly)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.tint, in: Circle())
        }
        .buttonStyle(.plain)
        .help(L("overlay.finish"))
        .accessibilityLabel(L("overlay.finish"))
    }

    /// Re-run the failed translation and paste the result.
    private func retry() {
        OverlayController.shared.show(.translating(label: nil))
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let value = try Core.invoke("retry_last_translation")
                let text = value as? String ?? ""
                DispatchQueue.main.async {
                    guard !text.isEmpty else { return }
                    Paster.paste(text)
                    try? Core.invoke("watch_for_edit", ["text": text])
                    OverlayController.shared.hide()
                }
            } catch {
                // The core already re-emitted `translation_failed`.
                NSLog("TalkWTF: translation retry failed: \(error.localizedDescription)")
            }
        }
    }

    private func undo() {
        try? Core.invoke("undo_last_dictionary_learning")
        OverlayController.shared.hide()
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
