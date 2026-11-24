import AppKit
import SwiftUI

/// The UI design system. Every view reads its sizes and colors from here instead
/// of hard-coding numbers, so the whole app moves together.
///
/// The visual language is a Swiss / editorial studio look: hairline rules,
/// near-square corners, no shadows, one signal color. Values come from
/// `web/src/index.css` (the design reference kept under `web/`); keep the two in
/// sync when either changes.
enum Theme {
    /// Color tokens. All of them resolve per appearance, so a view never needs
    /// to branch on light/dark itself.
    enum Colors {
        /// Page background behind everything.
        static let canvas = Palette.dynamic(light: 0xF6F6F3, dark: 0x0B0C0E)
        /// Sidebar rail.
        static let sidebar = Palette.dynamic(light: 0xEFEFEA, dark: 0x0F1114)
        /// Raised panel / card surface.
        static let surface = Palette.dynamic(light: 0xFFFFFF, dark: 0x131519)
        /// Inset well (inputs, code, empty states).
        static let well = Palette.dynamic(light: 0xEAEAE4, dark: 0x181B20)

        static let hover = Palette.dynamic(light: 0x111214, dark: 0xFFFFFF, lightAlpha: 0.045, darkAlpha: 0.045)
        static let active = Palette.dynamic(light: 0x111214, dark: 0xFFFFFF, lightAlpha: 0.075, darkAlpha: 0.085)

        static let hairline = Palette.dynamic(light: 0x111214, dark: 0xFFFFFF, lightAlpha: 0.11, darkAlpha: 0.09)
        static let hairlineStrong = Palette.dynamic(light: 0x111214, dark: 0xFFFFFF, lightAlpha: 0.22, darkAlpha: 0.18)

        static let ink = Palette.dynamic(light: 0x111214, dark: 0xF2F3F5)
        static let inkSecondary = Palette.dynamic(light: 0x565A63, dark: 0x989FA9)
        static let inkTertiary = Palette.dynamic(light: 0x848994, dark: 0x656C76)

        /// The single signal color. Everything else stays neutral.
        static let accent = Palette.dynamic(light: 0xE5481F, dark: 0xFF552B)
        static let accentHover = Palette.dynamic(light: 0xCC3A14, dark: 0xFF6B45)
        static let accentSoft = Palette.dynamic(light: 0xE5481F, dark: 0xFF552B, lightAlpha: 0.10, darkAlpha: 0.14)

        static let ok = Palette.dynamic(light: 0x16A34A, dark: 0x22C55E)
        static let warn = Palette.dynamic(light: 0xD97706, dark: 0xF59E0B)
        static let err = Palette.dynamic(light: 0xDC2626, dark: 0xEF4444)

        /// Text on top of `accent`.
        static let onAccent = Color.white

        // Legacy aliases kept so older views compile while they are ported.
        static let selection = hover
        static let selectionHover = hover
        static let selectionAccent = accentSoft
        static let cardFill = surface
    }

    /// Type scale in the studio look: SF with tight tracking for display sizes,
    /// monospaced for metadata and keycaps.
    enum Fonts {
        /// Hero headline on the overview page.
        static let hero = Font.system(size: 44, weight: .bold)
        /// Page title (概览 / 资料库 / 设置).
        static let largeTitle = Font.system(size: 30, weight: .semibold)
        /// Section title inside a page.
        static let title = Font.system(size: 20, weight: .semibold)
        /// Row title.
        static let headline = Font.system(size: 15, weight: .semibold)
        /// Body copy.
        static let body = Font.system(size: 14)
        /// Secondary text and control labels.
        static let callout = Font.system(size: 13)
        /// Metadata and descriptions.
        static let caption = Font.system(size: 11)
        /// Large numbers (metrics).
        static let metric = Font.system(size: 34, weight: .semibold).monospacedDigit()
        /// Page subtitle under the large title.
        static let pageSubtitle = Font.system(size: 13)
        /// Small bold group header inside a page.
        static let sectionHeader = Font.system(size: 12, weight: .semibold)

        /// Tabular monospace, for keycaps, counters and status codes.
        static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
        }
    }

    /// Spacing on a 4pt grid.
    enum Spacing {
        static let unit: CGFloat = 4
        /// Between page sections.
        static let section: CGFloat = 36
        /// Inside a card row.
        static let row: CGFloat = 12
        /// Horizontal row inset.
        static let rowHorizontal: CGFloat = 14
    }

    /// Layout constants.
    enum Layout {
        static let contentMaxWidth: CGFloat = 1120
        static let contentPadding: CGFloat = 32
        static let contentPaddingTop: CGFloat = 32

        static let windowWidth: CGFloat = 1200
        static let windowHeight: CGFloat = 820
        static let windowMinWidth: CGFloat = 980
        static let windowMinHeight: CGFloat = 640

        static let sidebarWidth: CGFloat = 240
        static let sidebarMinWidth: CGFloat = 220
        static let sidebarMaxWidth: CGFloat = 280
        static let settingsListWidth: CGFloat = 192
        static let sidebarRowHeight: CGFloat = 40
        /// Header bar above the detail pane.
        static let headerHeight: CGFloat = 56
        /// Space reserved for the traffic lights at the top of the sidebar.
        static let trafficLightInset: CGFloat = 76
    }

    /// Corner radii. The studio look is deliberately near-square.
    enum Radius {
        static let card: CGFloat = 2
        static let control: CGFloat = 2
        static let field: CGFloat = 2
        static let sidebar: CGFloat = 0
        static let overlay: CGFloat = 4
    }

    /// Control metrics.
    enum Control {
        static let buttonHeight: CGFloat = 28
        static let fieldHeight: CGFloat = 30
        static let segmentedHeight: CGFloat = 28
    }

    /// The floating overlay's per-state geometry.
    enum Overlay {
        static let recordingSize = CGSize(width: 320, height: 48)
        static let recordingPanelSize = CGSize(width: 320, height: 70)
        static let workingSize = CGSize(width: 300, height: 48)
        static let cardSize = CGSize(width: 460, height: 84)

        static let hintSpacing: CGFloat = 6
        static let iconSize: CGFloat = 18
    }

    /// Builds a color that resolves to a different value per appearance.
    enum Palette {
        static func dynamic(
            light: UInt32,
            dark: UInt32,
            lightAlpha: CGFloat = 1,
            darkAlpha: CGFloat = 1
        ) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let rgb = isDark ? dark : light
                return NSColor(
                    srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                    green: CGFloat((rgb >> 8) & 0xFF) / 255,
                    blue: CGFloat(rgb & 0xFF) / 255,
                    alpha: isDark ? darkAlpha : lightAlpha
                )
            })
        }
    }
}

extension View {
    /// Page container: title area + content, capped and padded per the design
    /// system. Every top-level page uses this so they line up exactly.
    func pageLayout() -> some View {
        self
            .padding(.horizontal, Theme.Layout.contentPadding)
            .padding(.vertical, Theme.Layout.contentPaddingTop)
            .frame(maxWidth: Theme.Layout.contentMaxWidth, alignment: .leading)
    }

    /// Large page title + secondary subtitle.
    func pageHeader(_ title: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.Fonts.largeTitle)
            if let subtitle {
                Text(subtitle)
                    .font(Theme.Fonts.pageSubtitle)
                    .foregroundStyle(Theme.Colors.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A card surface used by dashboard tiles and list containers.
    func cardSurface() -> some View {
        self
            .padding(Theme.Spacing.row + 4)
            .background(Theme.Colors.surface)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Theme.Colors.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    /// The floating panel: flat surface, hairline edge, and just enough shadow
    /// to stay legible over a white document.
    func overlaySurface(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(shape.fill(Theme.Colors.surface))
            .overlay(shape.strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.16), radius: 18, y: 6)
    }

    /// A rounded surface that uses Liquid Glass on macOS 26 and falls back to a
    /// material elsewhere.
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 2)
        }
    }

    /// Sidebar navigation row.
    func sidebarRow(isSelected: Bool, isHovered: Bool = false) -> some View {
        self
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(
                        isSelected
                            ? Theme.Colors.active
                            : (isHovered ? Theme.Colors.hover : Color.clear)
                    )
            )
            .contentShape(Rectangle())
    }
}

extension View {
    /// Flattens the native `Form` onto the studio canvas: no inset card, no
    /// gradient background, plain hairline rows.
    func studioForm() -> some View {
        self
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Theme.Colors.canvas)
    }
}

extension Text {
    /// Editorial display treatment: bold, tight tracking, balanced wrapping.
    func studioDisplay(_ size: CGFloat, weight: Font.Weight = .bold) -> some View {
        self
            .font(.system(size: size, weight: weight))
            .tracking(-size * 0.032)
            .lineSpacing(size * 0.06)
            .fixedSize(horizontal: false, vertical: true)
    }
}
