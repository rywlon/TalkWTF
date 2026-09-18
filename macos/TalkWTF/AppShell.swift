import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard
    case library
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return L("sidebar.dashboard")
        case .library: return L("sidebar.library")
        case .settings: return L("sidebar.settings")
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .library: return "books.vertical"
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
                    ThemeController.apply(store.string("theme", "system"))
                    // Always present: with no Dock icon the menu bar item is the
                    // app's only entry point.
                    TrayController.shared.install()
                    Autostart.removeLegacyLaunchAgent()
                    Autostart.apply(store.bool("autostart_enabled"))
                    OverlayController.shared.start()
                    DictationController.shared.start()
                    SecureInputFallback.shared.onHotkey = { bindingId, pressed in
                        DictationController.shared.handle(bindingId: bindingId, pressed: pressed)
                    }
                    SecureInputFallback.shared.start()
                    self.booted = true
                    self.needsOnboarding = !Permissions.microphoneGranted
                }
            } catch {
                DispatchQueue.main.async { self.bootError = error.localizedDescription }
            }
        }
    }
}

struct AppShell: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var boot = AppBoot.shared
    @State private var section: AppSection = .dashboard
    @State private var pane: SettingsPane = .general
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
                NavigationSplitView {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) {
                            Image(systemName: "waveform").foregroundStyle(.tint)
                            Text("TalkWTF").font(Theme.Fonts.headline)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 14)
                        .padding(.bottom, 10)

                        // Hand-rolled rows so the selection is our rounded pill
                        // instead of the native list highlight (which paints a
                        // full-width blue bar).
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(AppSection.allCases) { item in
                                Button {
                                    section = item
                                } label: {
                                    Label(item.title, systemImage: item.symbol)
                                        .font(Theme.Fonts.body)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .sidebarRow(
                                            isSelected: section == item,
                                            isHovered: hoveredSection == item
                                        )
                                }
                                .buttonStyle(.plain)
                                .onHover { hovering in
                                    hoveredSection = hovering ? item : nil
                                }
                                .accessibilityAddTraits(section == item ? [.isSelected] : [])
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                    .glassSurface(cornerRadius: Theme.Radius.sidebar)
                    .padding(8)
                    .navigationSplitViewColumnWidth(
                        min: Theme.Layout.sidebarMinWidth,
                        ideal: Theme.Layout.sidebarWidth,
                        max: Theme.Layout.sidebarMaxWidth
                    )
                } detail: {
                    switch section {
                    case .dashboard:
                        DashboardView()
                    case .library:
                        LibraryView()
                    case .settings:
                        // The categories live in a segmented control instead of a
                        // third sidebar column: seven items were a long, mostly
                        // empty list, and the content gets the width back.
                        VStack(spacing: 0) {
                            Picker("", selection: $pane) {
                                ForEach(SettingsPane.allCases) { item in
                                    Label(item.title, systemImage: item.symbol).tag(item)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .padding(.horizontal, Theme.Layout.contentPadding)
                            .padding(.top, 12)

                            Divider().padding(.top, 12)

                            SettingsView(pane: pane)
                        }
                    }
                }
            }
        }
        .task {
            // The window is destroyed on close, so the tray item reopens it via
            // SwiftUI's scene action rather than a stale `NSWindow` reference.
            TrayController.shared.onOpenWindow = { openWindow(id: "main") }
            AppBoot.shared.start()
        }
        .busyAlert()
    }
}
