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
        case .recording, .streaming, .learned: return Theme.Overlay.recordingSize
        case .transcribing, .processing, .translating: return Theme.Overlay.workingSize
        case .translationFailed, .notice: return Theme.Overlay.cardSize
        }
    }

    /// The panel is taller than the recording card so the hint line beneath it
    /// has room without clipping; every other state fits its card exactly.
    var panelSize: CGSize {
        switch self {
        case .recording, .streaming: return Theme.Overlay.recordingPanelSize
        default: return size
        }
    }

    /// One continuous radius for the glass card, shared with the rest of the UI.
    var cornerRadius: CGFloat { Theme.Radius.overlay }

    /// Recording or live-streaming: the states that show the target app badge.
    var isRecording: Bool {
        switch self {
        case .recording, .streaming: return true
        default: return false
        }
    }
}

/// Where the overlay sits on the pointer's screen when it is not placed next to
/// a field.
enum OverlayAnchor {
    case top
    case bottom
}

/// Observable bridge between the core's events and the SwiftUI panel.
@MainActor
final class OverlayModel: ObservableObject {
    @Published var state: OverlayState = .recording
    @Published var levels: [CGFloat] = Array(repeating: 0.15, count: 18)
    /// The app the dictation is headed to, captured when recording starts.
    @Published var targetAppName: String?
    @Published var targetAppIcon: NSImage?

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
    private var started = false

    /// Subscribe to the core's events. Call once, after the core is up.
    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(forName: .talkWtfCoreEvent, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.handle(raw: note.object as? String) }
        }
        center.addObserver(forName: .talkWtfMicLevel, object: nil, queue: .main) { [weak self] note in
            guard let levels = note.object as? [CGFloat] else { return }
            MainActor.assumeIsolated { self?.model.setLevels(levels) }
        }
        // Follow the frontmost app while recording, so the badge shows where the
        // text will actually land even if the user switches mid-dictation.
        center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.model.state.isRecording else { return }
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    ?? NSWorkspace.shared.frontmostApplication
                self.model.targetAppName = app?.localizedName
                self.model.targetAppIcon = app?.icon
                self.panel?.refit(anchor: self.anchor)
            }
        }
    }

    /// The screen anchor the overlay uses when it is not placed next to a field.
    private var anchor: OverlayAnchor {
        SettingsStore.shared.string("overlay_position", "bottom") == "top" ? .top : .bottom
    }

    /// Show the panel in `state`, optionally next to the field it refers to.
    func show(_ state: OverlayState, near frame: CGRect? = nil) {
        if state.isRecording {
            let app = NSWorkspace.shared.frontmostApplication
            model.targetAppName = app?.localizedName
            model.targetAppIcon = app?.icon
        }
        model.state = state
        let panel = panel ?? OverlayPanel(model: model)
        self.panel = panel
        panel.show(autoHideAfter: state.autoHideAfter, near: frame, anchor: anchor)
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
                )
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
}

/// A non-activating floating panel that hosts the recording overlay.
///
/// Native `NSPanel` + SwiftUI so the pill can use the real macOS 26 Liquid Glass
/// (`glassEffect`), which a webview cannot render.
@MainActor
final class OverlayPanel {
    private let model: OverlayModel
    private var panel: NSPanel?
    private var hosting: NSHostingView<OverlayView>?

    init(model: OverlayModel) {
        self.model = model
    }

    /// Show the overlay, optionally auto-hiding after `autoHideAfter` seconds,
    /// placed next to `near` (top-left screen coordinates) or anchored to the
    /// top/bottom of the pointer's screen.
    func show(autoHideAfter seconds: TimeInterval?, near: CGRect? = nil, anchor: OverlayAnchor) {
        let panel = existingOrCreate()
        panel.orderFrontRegardless()
        // Measure on the next runloop turn so SwiftUI has rendered the new state;
        // measuring synchronously would size the panel for the previous state.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            panel.setContentSize(self.fittedSize())
            panel.layoutIfNeeded()
            // The hosting view settles the panel to the content's intrinsic size
            // during layout, so centre using what the frame actually became
            // (the requested size can differ from it).
            self.reposition(panel, near: near, anchor: anchor, size: panel.frame.size)
            panel.orderFrontRegardless()
        }

        if let seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.hide()
            }
        }
    }

    /// The content's intrinsic size for the current state. Recording renders both
    /// the info line and the hover actions in a `ZStack`, so the measured width is
    /// the same hovering or not; the upper clamp keeps a very long app name from
    /// producing an absurdly wide panel.
    private func fittedSize() -> NSSize {
        guard let hosting else { return model.state.panelSize }
        // With `sizingOptions == []` the host reports no intrinsic size, so
        // `fittingSize` would be zero. Enable it only for this synchronous
        // measurement (and restore it) so the panel can be sized and centred to
        // the real content width without SwiftUI ever driving the window itself.
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        hosting.sizingOptions = []
        let width = min(max(fitting.width, 1), 520)
        let height = max(fitting.height, 1)
        return NSSize(width: width, height: height)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Re-measure and recenter after the content changed without a state change
    /// (the target app's name/icon can get longer).
    func refit(anchor: OverlayAnchor) {
        guard let panel else { return }
        panel.setContentSize(fittedSize())
        panel.layoutIfNeeded()
        reposition(panel, near: nil, anchor: anchor, size: panel.frame.size)
    }

    private func existingOrCreate() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Theme.Overlay.recordingPanelSize),
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
        // Keep automatic sizing off so SwiftUI never resizes the panel on its own
        // (the hover actions change the content and an auto-sizing host would
        // stretch the pill mid-hover). `fittedSize` briefly enables intrinsic
        // sizing just to measure. The size is set explicitly in `show`.
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.hosting = hosting

        self.panel = panel
        return panel
    }

    /// Place next to the focused field when we know where it is, otherwise
    /// centred on the pointer's screen at the configured top/bottom anchor.
    private func reposition(_ panel: NSPanel, near: CGRect?, anchor: OverlayAnchor, size: NSSize) {
        if let near, let screen = screenContaining(near) {
            // AX y is top-left based; AppKit is bottom-left based.
            let cocoaY = screen.frame.maxY - near.maxY
            let x = near.minX.clamped(to: screen.frame.minX ... (screen.frame.maxX - size.width))
            // The card is the top child of the panel's VStack, so anchoring the
            // panel's top edge puts the card's top 8pt below the field. The
            // panel's extra height (hint line) extends downward and needs no
            // correction.
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
        let y: CGFloat
        switch anchor {
        case .top:
            y = (frame.maxY - size.height - 12).clamped(to: frame.minY ... (frame.maxY - size.height))
        case .bottom:
            y = (frame.minY + 12).clamped(to: frame.minY ... (frame.maxY - size.height))
        }
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
        VStack(spacing: Theme.Overlay.hintSpacing) {
            content.glassSurface(cornerRadius: model.state.cornerRadius)
            if isRecordingState {
                Text(L("overlay.recordingHint"))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(.secondary)
                    .opacity(hovering ? 0 : 1)
            }
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            switch model.state {
            case .recording, .streaming:
                // Both layers live in one ZStack so the card width is the same
                // hovering or not; the hover actions just fade over the info line.
                ZStack {
                    HStack(spacing: 12) {
                        appBadge
                        Spacer(minLength: 8)
                        waveform
                        Spacer(minLength: 8)
                        Text("TalkWTF")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(.secondary)
                    }
                    .opacity(hovering ? 0 : 1)

                    HStack(spacing: 8) {
                        finishButton
                        discardButton
                    }
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
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
            case .learned(_, let replacement, let count):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(count > 1
                    ? L("overlay.learned.titlePlural", ["count": count])
                    : L("overlay.learned.title", ["replacement": replacement]))
                    .font(Theme.Fonts.callout)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(L("overlay.learned.undo")) { undo() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: model.state.size.height)
        .fixedSize(horizontal: true, vertical: false)
        .opacity(hovering && isRecordingState ? 0.92 : 1)
        .onHover { hovering = $0 }
    }

    /// The app the transcript will land in: its icon and name, omitted entirely
    /// when the frontmost app can't be identified.
    private var appBadge: some View {
        HStack(spacing: 6) {
            if let icon = model.targetAppIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: Theme.Overlay.iconSize, height: Theme.Overlay.iconSize)
            }
            if let name = model.targetAppName {
                Text(name)
                    .font(Theme.Fonts.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .layoutPriority(1)
    }

    /// A dashed resting line that grows into solid bars once audio arrives.
    private var waveform: some View {
        let hasSignal = (model.levels.max() ?? 0) > 0.22
        return HStack(spacing: 3) {
            ForEach(model.levels.indices, id: \.self) { index in
                Capsule()
                    .fill(hasSignal ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.5)))
                    .frame(width: 3, height: hasSignal ? max(4, model.levels[index] * 30) : 2)
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

    /// Hovering dims the card and swaps the waveform for the two actions, like
    /// Spokenly: throw the recording away, or finish and paste it.
    private var discardButton: some View {
        Button {
            DictationController.shared.discard()
        } label: {
            Label(L("overlay.discard"), systemImage: "xmark")
                .font(Theme.Fonts.callout.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(Color.red, in: Capsule())
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
                .font(Theme.Fonts.callout.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(.tint, in: Capsule())
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
