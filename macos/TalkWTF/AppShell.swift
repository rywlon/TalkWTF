import SwiftUI

extension AppSection {
    /// Debug affordance: `TALKWTF_SECTION=agents` opens straight to a page,
    /// which keeps screenshot/QA runs from depending on mouse coordinates.
    static var launchOverride: AppSection? {
        guard let raw = ProcessInfo.processInfo.environment["TALKWTF_SECTION"] else { return nil }
        return AppSection(rawValue: raw)
    }
}

extension SettingsPane {
    static var launchOverride: SettingsPane? {
        guard let raw = ProcessInfo.processInfo.environment["TALKWTF_PANE"] else { return nil }
        return SettingsPane(rawValue: raw)
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard
    case agents
    case library
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return L("sidebar.dashboard")
        case .agents: return "Voice to Agent"
        case .library: return L("sidebar.library")
        case .settings: return L("sidebar.settings")
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .agents: return "arrow.up.right"
        case .library: return "archivebox"
        case .settings: return "gearshape"
        }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case personalization
    case models
    case audio
    case advanced
    case debug
    case about

    var id: String { rawValue }

    var title: String { L("settings.panes.\(rawValue)") }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .personalization: return "wand.and.stars"
        case .models: return "cpu"
        case .audio: return "waveform"
        case .advanced: return "slider.horizontal.3"
        case .debug: return "ladybug"
        case .about: return "info.circle"
        }
    }
}

/// One-time engine/UI boot, shared across scene lifetimes.
///
/// As a menu-bar app the window can be closed and reopened, which recreates
/// `AppShell`. Booting per-view would register the hotkey/event observers again
/// and double-handle every hotkey, so the work runs exactly once per process and
/// the resulting state is published for whichever scene is on screen.
@MainActor
final class AppBoot: ObservableObject {
    static let shared = AppBoot()

    @Published var booted = false
    @Published var bootError: String?
    @Published var needsOnboarding = false

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        // The engine loads native backends; keep it off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try Core.initialize()
                DispatchQueue.main.async {
                    let store = SettingsStore.shared
                    store.load()
                    Localization.shared.load(language: store.settings["app_language"] as? String)
                    ThemeController.apply(
                        ProcessInfo.processInfo.environment["TALKWTF_APPEARANCE"]
                            ?? store.string("theme", "system")
                    )
                    // Always present: with no Dock icon the menu bar item is the
                    // app's only entry point.
                    TrayController.shared.install()
                    AgentHub.shared.ensureRouterBinding()
                    Autostart.removeLegacyLaunchAgent()
                    Autostart.apply(store.bool("autostart_enabled"))
                    OverlayController.shared.start()
                    DictationController.shared.start()
                    SecureInputFallback.shared.onHotkey = { bindingId, pressed in
                        DictationController.shared.handle(bindingId: bindingId, pressed: pressed)
                    }
                    SecureInputFallback.shared.start()
                    self.booted = true
                    self.needsOnboarding = ProcessInfo.processInfo.environment["TALKWTF_ONBOARDING"] == "1"
                        || !Permissions.microphoneGranted
                }
            } catch {
                DispatchQueue.main.async { self.bootError = error.localizedDescription }
            }
        }
    }
}

/// The window: a 240pt rail on the left, a 56pt breadcrumb header, and the page
/// below. The rail owns the primary actions so they follow you across pages.
struct AppShell: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var boot = AppBoot.shared
    @ObservedObject private var store = SettingsStore.shared
    @State private var section: AppSection = AppSection.launchOverride ?? .dashboard
    @State private var pane: SettingsPane = SettingsPane.launchOverride ?? .general
    @State private var hoveredSection: AppSection?

    var body: some View {
        Group {
            if let bootError = boot.bootError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text("核心启动失败").font(.headline)
                    Text(bootError).font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(40)
            } else if !boot.booted {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(L("common.loading")).foregroundStyle(.secondary)
                }
                .padding(40)
            } else if boot.needsOnboarding {
                OnboardingView { boot.needsOnboarding = false }
            } else {
                main
            }
        }
        .onAppear {
            if let sectionOverride = AppSection.launchOverride { section = sectionOverride }
            if let paneOverride = SettingsPane.launchOverride { pane = paneOverride }
        }
        .task {
            // The window is destroyed on close, so the tray item reopens it via
            // SwiftUI's scene action rather than a stale `NSWindow` reference.
            TrayController.shared.onOpenWindow = { openWindow(id: "main") }
            AppBoot.shared.start()
        }
        .busyAlert()
    }

    private var main: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                header
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(Theme.Colors.canvas)
        }
        .background(Theme.Colors.canvas)
        .tint(Theme.Colors.accent)
    }

    // MARK: - rail

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.bottom, 26)

            captureActions
                .padding(.bottom, 26)

            navigation

            Spacer(minLength: 16)

            footer
        }
        .padding(.horizontal, 14)
        .padding(.top, 30)
        .padding(.bottom, 10)
        .frame(width: Theme.Layout.sidebarWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.Colors.sidebar)
        .overlay(alignment: .trailing) {
            Hairline(vertical: true)
        }
    }

    private var brand: some View {
        HStack(spacing: 9) {
            WaveMark()
            Text("TalkWTF")
                .font(.system(size: 18, weight: .bold))
                .tracking(-0.5)
                .foregroundStyle(Theme.Colors.ink)
        }
        .padding(.horizontal, 4)
    }

    private var captureActions: some View {
        VStack(spacing: 8) {
            StudioButton(
                title: L("sidebar.startDictation"),
                systemImage: "mic.fill",
                trailing: shortcut("transcribe"),
                kind: .accent,
                height: 40,
                expands: true
            ) {
                DictationController.shared.toggle(mode: "dictation")
            }

            StudioButton(
                title: L("dashboard.startAutoAgent"),
                systemImage: "arrow.triangle.branch",
                trailing: shortcut(AgentHub.routerBindingID),
                kind: .ghost,
                height: 40,
                expands: true
            ) {
                DictationController.shared.toggle(mode: AgentHub.routerBindingID)
            }
        }
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(AppSection.allCases) { item in
                Button {
                    section = item
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 16)
                            .foregroundStyle(section == item ? Theme.Colors.accent : Theme.Colors.inkSecondary)
                        Text(item.title)
                            .font(.system(size: 13.5, weight: section == item ? .medium : .regular))
                            .foregroundStyle(section == item ? Theme.Colors.ink : Theme.Colors.inkSecondary)
                        Spacer(minLength: 4)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: Theme.Layout.sidebarRowHeight)
                    .background(
                        Rectangle().fill(
                            section == item
                                ? Theme.Colors.active
                                : (hoveredSection == item ? Theme.Colors.hover : .clear)
                        )
                    )
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(section == item ? Theme.Colors.accent : .clear)
                            .frame(width: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hoveredSection = hovering ? item : nil
                }
                .accessibilityAddTraits(section == item ? [.isSelected] : [])
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 0) {
                footerCell(
                    icon: isDark ? "moon" : "sun",
                    title: isDark ? L("theme.options.dark") : L("theme.options.light")
                ) {
                    toggleTheme()
                }
                Hairline(vertical: true)
                footerCell(
                    icon: "globe",
                    title: store.string("app_language", "en").hasPrefix("zh") ? "中文" : "EN"
                ) {
                    toggleLanguage()
                }
            }
            .frame(height: 40)
        }
        .padding(.horizontal, 2)
    }

    private func footerCell(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .medium))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Theme.Colors.inkSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }

    // MARK: - header

    private var header: some View {
        HStack(spacing: 8) {
            Text("TalkWTF")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Colors.inkTertiary)
            Text("/")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Colors.inkTertiary.opacity(0.6))
            Text(section.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.Colors.ink)
            Spacer(minLength: 12)
            if section != .agents {
                Button {
                    section = .agents
                } label: {
                    HStack(spacing: 6) {
                        Text("Voice to Agent").font(.system(size: 12.5))
                        KeycapCombo(combo: "Alt+A")
                    }
                    .foregroundStyle(Theme.Colors.inkSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .frame(height: Theme.Layout.headerHeight, alignment: .bottom)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { Hairline() }
    }

    // MARK: - pages

    @ViewBuilder private var page: some View {
        switch section {
        case .dashboard:
            DashboardView(
                onOpenAgents: { section = .agents },
                onOpenLibrary: { section = .library },
                onOpenSettings: { pane in
                    self.pane = pane
                    self.section = .settings
                }
            )
        case .agents:
            AgentsView()
        case .library:
            LibraryView()
        case .settings:
            settingsPage
        }
    }

    private var settingsPage: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 22) {
                    ForEach(SettingsPane.allCases) { item in
                        Button {
                            pane = item
                        } label: {
                            VStack(spacing: 9) {
                                Text(item.title)
                                    .font(.system(size: 12.5, weight: pane == item ? .semibold : .regular))
                                    .foregroundStyle(pane == item ? Theme.Colors.ink : Theme.Colors.inkSecondary)
                                Rectangle()
                                    .fill(pane == item ? Theme.Colors.accent : .clear)
                                    .frame(height: 2)
                            }
                            .fixedSize()
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.Layout.contentPadding)
                .padding(.top, 10)
            }
            .overlay(alignment: .bottom) { Hairline() }

            SettingsView(pane: pane)
        }
    }

    // MARK: - helpers

    private var isDark: Bool {
        store.string("theme", "system") == "dark"
    }

    private func toggleTheme() {
        let next = isDark ? "light" : "dark"
        store.patch(["theme": next])
        ThemeController.apply(next)
    }

    private func toggleLanguage() {
        let next = store.string("app_language", "en").hasPrefix("zh") ? "en" : "zh"
        store.patch(["app_language": next])
        Localization.shared.load(language: next)
    }

    /// The current key combo for a core binding, e.g. `Alt+Space`.
    private func shortcut(_ id: String) -> String? {
        let bindings = store.settings["bindings"] as? [String: [String: Any]] ?? [:]
        guard let value = bindings[id]?["current_binding"] as? String, !value.isEmpty else {
            return nil
        }
        return value
    }
}

/// The five-bar waveform mark used next to the wordmark.
private struct WaveMark: View {
    private let heights: [CGFloat] = [9, 15, 20, 13, 7]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, height in
                Capsule()
                    .fill(Theme.Colors.accent)
                    .frame(width: 2.5, height: height)
            }
        }
        .frame(height: 22)
        .accessibilityHidden(true)
    }
}
