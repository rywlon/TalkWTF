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

struct AppShell: View {
    @State private var section: AppSection = .dashboard
    @State private var pane: SettingsPane = .general
    @State private var booted = false
    @State private var bootError: String?
    @State private var needsOnboarding = false
    @State private var hoveredSection: AppSection?

    var body: some View {
        Group {
            if let bootError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text("核心启动失败").font(.headline)
                    Text(bootError).font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(40)
            } else if !booted {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(L("common.loading")).foregroundStyle(.secondary)
                }
                .padding(40)
            } else if needsOnboarding {
                OnboardingView { needsOnboarding = false }
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

                        // A native `List` keeps arrow-key navigation and the
                        // `.isSelected` trait that hand-rolled buttons lose on
                        // macOS (buttons are not in the key loop unless Full
                        // Keyboard Access is on). Rows are styled by hand so the
                        // card look is preserved; the list chrome is hidden.
                        List(selection: $section) {
                            ForEach(AppSection.allCases) { item in
                                Label(item.title, systemImage: item.symbol)
                                    .font(Theme.Fonts.body)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .sidebarRow(
                                        isSelected: section == item,
                                        isHovered: hoveredSection == item
                                    )
                                    .tag(item)
                                    .onHover { hovering in
                                        hoveredSection = hovering ? item : nil
                                    }
                                    .listRowInsets(
                                        EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0)
                                    )
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                                    .accessibilityAddTraits(section == item ? [.isSelected] : [])
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
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
        .task { boot() }
        .busyAlert()
    }

    private func boot() {
        guard !booted else { return }
        // The engine loads native backends; keep it off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try Core.initialize()
                DispatchQueue.main.async {
                    let store = SettingsStore.shared
                    store.load()
                    Localization.shared.load(language: store.settings["app_language"] as? String)
                    ThemeController.apply(store.string("theme", "system"))
                    TrayController.shared.setVisible(store.bool("show_tray_icon", true))
                    Autostart.removeLegacyLaunchAgent()
                    Autostart.apply(store.bool("autostart_enabled"))
                    OverlayController.shared.start()
                    DictationController.shared.start()
                    SecureInputFallback.shared.onHotkey = { bindingId, pressed in
                        DictationController.shared.handle(bindingId: bindingId, pressed: pressed)
                    }
                    SecureInputFallback.shared.start()
                    booted = true
                    needsOnboarding = !Permissions.microphoneGranted
                }
            } catch {
                DispatchQueue.main.async { bootError = error.localizedDescription }
            }
        }
    }
}
