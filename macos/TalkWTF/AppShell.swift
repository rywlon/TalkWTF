import SwiftUI

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
        case .dashboard: return "waveform.circle"
        case .agents: return "arrow.up.forward.app"
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
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: "waveform")
                                .font(.system(size: 26, weight: .medium))
                                .foregroundStyle(.tint)
                            Text("TalkWTF").font(.system(size: 22, weight: .semibold, design: .rounded))
                            Text("Words that flow.")
                                .font(Theme.Fonts.callout).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 28)
                        .padding(.bottom, 32)

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
                        Spacer()
                        VStack(alignment: .leading, spacing: 8) {
                            Label("本地语音识别", systemImage: "waveform.badge.mic")
                            Text("说出来，继续向前。")
                        }
                        .font(Theme.Fonts.caption).foregroundStyle(.secondary)
                        .padding(16)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                    .background(.ultraThinMaterial)
                    .padding(.trailing, 1)
                    .navigationSplitViewColumnWidth(
                        min: Theme.Layout.sidebarMinWidth,
                        ideal: Theme.Layout.sidebarWidth,
                        max: Theme.Layout.sidebarMaxWidth
                    )
                } detail: {
                    switch section {
                    case .dashboard:
                        DashboardView(onOpenAgents: { section = .agents })
                    case .agents:
                        AgentsView()
                    case .library:
                        LibraryView()
                    case .settings:
                        // The categories live in a segmented control instead of a
                        // third sidebar column: seven items were a long, mostly
                        // empty list, and the content gets the width back.
                        VStack(spacing: 0) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(SettingsPane.allCases) { item in
                                        Button { pane = item } label: {
                                            Text(item.title)
                                                .font(Theme.Fonts.callout)
                                                .padding(.horizontal, 12).padding(.vertical, 8)
                                                .background(pane == item ? Theme.Colors.selectionAccent : Color.clear,
                                                    in: RoundedRectangle(cornerRadius: 8))
                                                .foregroundStyle(pane == item ? Color.accentColor : Color.secondary)
                                        }.buttonStyle(.plain)
                                    }
                                }.padding(.horizontal, Theme.Layout.contentPadding).padding(.vertical, 16)
                            }

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
