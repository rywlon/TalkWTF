import AppKit
import SwiftUI

// MARK: - Rules and labels

/// The 1pt hairline used everywhere instead of cards and shadows.
struct Hairline: View {
    var vertical = false
    var color: Color = Theme.Colors.hairline

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// Small caps-style section label, e.g. "今日" / "最近活动".
/// Underline tab row used by the settings panes and the library.
struct StudioTabs<Item: Hashable>: View {
    let items: [Item]
    let title: (Item) -> String
    @Binding var selection: Item

    var body: some View {
        HStack(spacing: 22) {
            ForEach(items, id: \.self) { item in
                Button {
                    selection = item
                } label: {
                    VStack(spacing: 9) {
                        Text(title(item))
                            .font(.system(size: 12.5, weight: selection == item ? .semibold : .regular))
                            .foregroundStyle(selection == item ? Theme.Colors.ink : Theme.Colors.inkSecondary)
                        Rectangle()
                            .fill(selection == item ? Theme.Colors.accent : .clear)
                            .frame(height: 2)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}

struct SectionLabel: View {
    let text: String
    var trailing: String?
    var action: (() -> Void)?
    var actionTitle: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text)
                .font(Theme.Fonts.sectionHeader)
                .tracking(0.4)
                .foregroundStyle(Theme.Colors.inkSecondary)
            Spacer(minLength: 12)
            if let actionTitle, let action {
                Button(action: action) {
                    HStack(spacing: 5) {
                        Text(actionTitle).font(.system(size: 12.5, weight: .medium))
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Theme.Colors.accent)
                }
                .buttonStyle(.plain)
            }
            if let trailing {
                Text(trailing)
                    .font(Theme.Fonts.mono(12))
                    .foregroundStyle(Theme.Colors.inkTertiary)
            }
        }
    }
}

// MARK: - Keycaps

/// One key cap: `⌥`, `Space`, `⌘`.
struct Keycap: View {
    let text: String
    var muted = true

    var body: some View {
        Text(text)
            .font(Theme.Fonts.mono(10.5, weight: .medium))
            .foregroundStyle(muted ? Theme.Colors.inkSecondary : Theme.Colors.ink)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Theme.Colors.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Theme.Colors.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}

/// Turns a stored binding such as `fn+option_right+left` into human glyphs.
enum KeyGlyphs {
    static func parse(_ combo: String) -> [String] {
        combo
            .split(whereSeparator: { $0 == "+" })
            .map { part -> String in
                let token = part.trimmingCharacters(in: .whitespaces).lowercased()
                switch token {
                case "alt", "option", "option_left", "option_right": return "⌥"
                case "cmd", "command", "command_left", "command_right": return "⌘"
                case "ctrl", "control", "control_left", "control_right": return "⌃"
                case "shift", "shift_left", "shift_right": return "⇧"
                case "fn": return "fn"
                case "space": return "Space"
                case "return", "enter": return "⏎"
                case "left", "arrow_left": return "←"
                case "right", "arrow_right": return "→"
                case "up", "arrow_up": return "↑"
                case "down", "arrow_down": return "↓"
                case "": return ""
                default: return token.uppercased()
                }
            }
            .filter { !$0.isEmpty }
    }
}

/// A stored binding rendered inline as glyphs, for inside buttons and headers.
struct ShortcutLabel: View {
    let combo: String
    var tint: Color = Theme.Colors.inkTertiary

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(KeyGlyphs.parse(combo).prefix(4).enumerated()), id: \.offset) { _, glyph in
                Text(glyph)
                    .font(Theme.Fonts.mono(10.5, weight: .medium))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(tint)
        .lineLimit(1)
        .fixedSize()
    }
}

/// A stored binding such as `Alt+Space`, rendered as a row of keycaps.
struct KeycapCombo: View {
    let combo: String
    var muted = true

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(KeyGlyphs.parse(combo).enumerated()), id: \.offset) { _, key in
                Keycap(text: key, muted: muted)
            }
        }
    }
}

// MARK: - Buttons

enum StudioButtonKind {
    case accent
    case ghost
    case quiet
}

/// The design system's button: square corners, one filled variant, one outline
/// variant, optional trailing keycap hint.
struct StudioButton: View {
    let title: String
    var systemImage: String?
    var trailing: String?
    var kind: StudioButtonKind = .ghost
    var height: CGFloat = 40
    var fontSize: CGFloat = 13.5
    var expands = false
    let action: () -> Void

    @State private var hovered = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: fontSize - 1, weight: .medium))
                }
                Text(title)
                    .font(.system(size: fontSize, weight: kind == .accent ? .semibold : .medium))
                    .lineLimit(1)
                    .fixedSize()
                if let trailing {
                    Spacer(minLength: 8)
                    ShortcutLabel(
                        combo: trailing,
                        tint: kind == .accent
                            ? Color.white.opacity(0.82)
                            : Theme.Colors.inkTertiary
                    )
                }
            }
            .frame(maxWidth: expands ? .infinity : nil, alignment: expands ? .leading : .center)
            .padding(.horizontal, 14)
            .frame(height: height)
            .foregroundStyle(foreground)
            .background(background)
            .overlay(border)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
            .contentShape(Rectangle())
            .opacity(pressed ? 0.92 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private var foreground: Color {
        switch kind {
        case .accent: return Theme.Colors.onAccent
        case .ghost: return Theme.Colors.ink
        case .quiet: return Theme.Colors.inkSecondary
        }
    }

    private var background: Color {
        switch kind {
        case .accent: return hovered ? Theme.Colors.accentHover : Theme.Colors.accent
        case .ghost, .quiet: return hovered ? Theme.Colors.hover : .clear
        }
    }

    @ViewBuilder private var border: some View {
        if kind != .accent {
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .strokeBorder(
                    hovered ? Theme.Colors.hairlineStrong : Theme.Colors.hairline,
                    lineWidth: 1
                )
        }
    }
}

/// A bare icon button (copy / reload) that lightens on hover.
struct StudioIconButton: View {
    let systemImage: String
    var help: String?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovered ? Theme.Colors.ink : Theme.Colors.inkSecondary)
                .frame(width: 30, height: 30)
                .background(hovered ? Theme.Colors.active : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help ?? "")
    }
}

// MARK: - Acoustic strip

/// The hairline-ruled oscilloscope strip above the primary action. Draws live
/// microphone levels when recording, and a slow idle breath otherwise.
struct AcousticCanvas: View {
    var levels: [CGFloat] = []
    var active = false
    var height: CGFloat = 62
    var barCount = 48

    private var bars: [CGFloat] {
        let source = levels.isEmpty ? Array(repeating: 0, count: barCount) : levels
        if source.count == barCount { return source }
        return (0..<barCount).map { index in
            guard !source.isEmpty else { return 0 }
            let position = Double(index) / Double(max(barCount - 1, 1)) * Double(source.count - 1)
            let lower = Int(position)
            let upper = min(lower + 1, source.count - 1)
            let fraction = position - Double(lower)
            return source[lower] * (1 - fraction) + source[upper] * fraction
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: active ? 1.0 / 30.0 : 1.0 / 12.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geometry in
                let spacing: CGFloat = 3
                let width = max(
                    (geometry.size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount),
                    1
                )
                HStack(alignment: .center, spacing: spacing) {
                    ForEach(0..<barCount, id: \.self) { index in
                        let sample = bars[index]
                        let idle = CGFloat(
                            0.20 + 0.13 * sin(time * 0.85 + Double(index) * 0.42)
                                + 0.07 * sin(time * 1.9 + Double(index) * 0.17)
                        )
                        let level = active ? sample : idle
                        let barHeight = max(2, min(level, 1) * height)
                        Capsule(style: .continuous)
                            .fill(color(for: active ? sample : 0))
                            .frame(width: width, height: barHeight)
                            .frame(maxHeight: height, alignment: .center)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: height)
        }
        .allowsHitTesting(false)
    }

    private func color(for sample: CGFloat) -> Color {
        guard active else { return Theme.Colors.inkTertiary.opacity(0.55) }
        return sample > 0.06 ? Theme.Colors.accent : Theme.Colors.inkTertiary.opacity(0.3)
    }
}

// MARK: - Panels

/// Bordered surface, the studio replacement for rounded cards.
struct StudioPanel<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.surface)
            .overlay(
                Rectangle().strokeBorder(Theme.Colors.hairline, lineWidth: 1)
            )
    }
}

/// A row of the signal-chain list inside the photography panel.
struct SignalRow: View {
    let label: String
    let value: String
    var detail: String?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.white.opacity(0.55))
                    Text(value)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(Theme.Fonts.mono(11))
                            .foregroundStyle(Color.white.opacity(0.45))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(hovered ? 0.95 : 0.45))
                    .offset(x: hovered ? 2 : 0)
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

// MARK: - Bundled imagery

/// Photos shipped in `resources/images`. Loaded lazily; a missing file just
/// means the view falls back to its gradient.
enum StudioAssets {
    static let microphone: NSImage? = load("studio-mic")
    static let waveguide: NSImage? = load("agent-waveguide")

    static func image(_ name: String) -> NSImage? { load(name) }

    private static func load(_ name: String) -> NSImage? {
        guard let base = Bundle.main.resourceURL else { return nil }
        let url = base
            .appendingPathComponent("resources/images", isDirectory: true)
            .appendingPathComponent("\(name).jpg")
        guard let image = NSImage(contentsOf: url) else { return nil }
        return image
    }
}
