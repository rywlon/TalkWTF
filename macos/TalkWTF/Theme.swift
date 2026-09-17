import SwiftUI

/// The UI design system. Every view reads its sizes from here instead of
/// hard-coding numbers, so the whole app moves together.
///
/// The values come from `docs/specs/phase-8-native-ui-system.md`; keep the two
/// in sync when either changes.
enum Theme {
    /// Type scale. Use these instead of `.title2` / `.callout` so the hierarchy
    /// stays deliberate.
    enum Fonts {
        /// Page title (概览 / 资料库 / 设置 的标题).
        static let largeTitle = Font.system(size: 26, weight: .semibold)
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
        /// Large numbers (dashboard metrics).
        static let metric = Font.system(size: 26, weight: .semibold).monospacedDigit()
    }

    /// Spacing on a 4pt grid.
    enum Spacing {
        static let unit: CGFloat = 4
        /// Between page sections.
        static let section: CGFloat = 24
        /// Inside a card row.
        static let row: CGFloat = 12
        /// Horizontal row inset.
        static let rowHorizontal: CGFloat = 14
    }

    /// Layout constants.
    enum Layout {
        static let contentMaxWidth: CGFloat = 880
        static let contentPadding: CGFloat = 28
        static let contentPaddingTop: CGFloat = 24

        static let windowWidth: CGFloat = 1000
        static let windowHeight: CGFloat = 700
        static let windowMinWidth: CGFloat = 880
        static let windowMinHeight: CGFloat = 600

        static let sidebarWidth: CGFloat = 224
        static let sidebarMinWidth: CGFloat = 200
        static let sidebarMaxWidth: CGFloat = 260
        static let settingsListWidth: CGFloat = 192
        static let sidebarRowHeight: CGFloat = 30
    }

    /// Corner radii.
    enum Radius {
        static let card: CGFloat = 12
        static let control: CGFloat = 8
        static let field: CGFloat = 8
    }

    /// Control metrics. Native controls keep their own size; these are for the
    /// few places we draw a container ourselves.
    enum Control {
        static let buttonHeight: CGFloat = 28
        static let fieldHeight: CGFloat = 30
        static let segmentedHeight: CGFloat = 28
    }

    /// The floating overlay's per-state geometry.
    enum Overlay {
        static let recordingSize = CGSize(width: 260, height: 52)
        static let workingSize = CGSize(width: 280, height: 52)
        static let cardSize = CGSize(width: 460, height: 84)

        static let recordingRadius: CGFloat = 14
        static let cardRadius: CGFloat = 16
        static let iconSize: CGFloat = 18
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

    /// A card surface used by dashboard tiles and list containers.
    func cardSurface() -> some View {
        self
            .padding(Theme.Spacing.row + 4)
            .background(
                .quaternary.opacity(0.4),
                in: RoundedRectangle(cornerRadius: Theme.Radius.card)
            )
    }
}
