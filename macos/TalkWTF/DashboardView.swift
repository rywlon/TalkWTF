import SwiftUI

/// Overview: dictation entry, today, recent activity and service status.
struct DashboardView: View {
    var onOpenAgents: () -> Void = {}
    @ObservedObject private var store = SettingsStore.shared
    @State private var stats: Core.Dashboard?
    @State private var error: String?

    private let fourColumns = Array(
        repeating: GridItem(.flexible(), spacing: 12),
        count: 4
    )

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                HStack(alignment: .top) {
                    pageHeader(L("dashboard.title"), subtitle: L("dashboard.subtitle"))
                    Spacer()
                    Button {
                        load()
                    } label: {
                        Label(L("dashboard.refresh"), systemImage: "arrow.clockwise")
                    }

                }

                voiceEntry

                if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }

                if let stats {
                    todaySection(stats)
                    recentSection(stats)
                    servicesSection(stats)
                } else if error == nil {
                    ProgressView().padding(.top, 40)
                }
                Spacer()
            }
            .pageLayout()
        }
        .task { load() }
        .onReceive(NotificationCenter.default.publisher(for: .talkWtfCoreEvent)) { note in
            guard let raw = note.object as? String, raw.contains("history-update-payload") else { return }
            load()
        }
    }

    private var voiceEntry: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("从想法到行动，\n只需开口。")
                        .font(.system(size: 34, weight: .medium, design: .rounded))
                        .tracking(-0.8).fixedSize(horizontal: false, vertical: true)
                    Text("写下此刻的想法，或直接交给你的 Agent。")
                        .font(Theme.Fonts.body).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "waveform")
                    .font(.system(size: 52, weight: .ultraLight))
                    .foregroundStyle(Color.accentColor.opacity(0.65))
                    .padding(.top, 12)
            }
            HStack(spacing: 12) {
                Label(dictationShortcut, systemImage: "keyboard")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                Text("按热键开始听写").font(Theme.Fonts.callout).foregroundStyle(.secondary)
                Spacer()
                Button(action: onOpenAgents) {
                    Label("添加语音 Agent", systemImage: "arrow.up.forward")
                }.buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding(28)
        .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 22))
    }

    private var dictationShortcut: String {
        let bindings = store.settings["bindings"] as? [String: [String: Any]] ?? [:]
        return bindings["transcribe"]?["current_binding"] as? String ?? "未设置热键"
    }

    // MARK: - sections

    private func todaySection(_ stats: Core.Dashboard) -> some View {
        DashboardSection(title: L("dashboard.today.title")) {
            LazyVGrid(columns: fourColumns, spacing: 12) {
                StatCard(
                    symbol: "mic",
                    title: L("dashboard.today.recordings"),
                    value: "\(stats.today.recordings)"
                )
                StatCard(
                    symbol: "character.cursor.ibeam",
                    title: L("dashboard.today.chars"),
                    value: "\(stats.today.chars)"
                )
                StatCard(
                    symbol: "character.book.closed",
                    title: L("dashboard.today.translations"),
                    value: "\(stats.today.translations)"
                )
                StatCard(
                    symbol: "clock",
                    title: L("dashboard.today.dictationTime"),
                    value: duration(stats.today.dictationMs)
                )
            }
            .padding(.vertical, 4)
        }
    }

    private func servicesSection(_ stats: Core.Dashboard) -> some View {
        DashboardSection(title: L("dashboard.services.title")) {
            VStack(alignment: .leading, spacing: 8) {
                ServiceRow(
                    title: L("dashboard.services.asr"),
                    value: stats.services.asrModel,
                    ok: stats.services.asrReady
                )
                ServiceRow(
                    title: L("dashboard.services.llm"),
                    value: stats.services.llmProvider.isEmpty
                        ? L("dashboard.services.none")
                        : stats.services.llmProvider,
                    ok: stats.services.polishReady
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func recentSection(_ stats: Core.Dashboard) -> some View {
        DashboardSection(title: L("dashboard.recent.title")) {
            if stats.recent.isEmpty {
                Text(L("dashboard.recent.empty"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(stats.recent) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: entry.workflow == "translate"
                                ? "character.book.closed" : "mic")
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(entry.preview).lineLimit(1)
                            Spacer()
                            Text(L("dashboard.recent.chars", ["count": entry.charCount]))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(Date(timeIntervalSince1970: TimeInterval(entry.timestamp)), style: .relative)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - helpers

    private func load() {
        do {
            stats = try Core.Dashboard(Core.invoke("get_dashboard_stats"))
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func duration(_ milliseconds: Int) -> String {
        let totalSeconds = milliseconds / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }
}

private struct StatCard: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(Theme.Fonts.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(Theme.Fonts.metric)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

private struct ServiceRow: View {
    let title: String
    let value: String
    let ok: Bool

    var body: some View {
        HStack {
            Text(title).font(Theme.Fonts.body)
            Spacer()
            Text(value).font(Theme.Fonts.body).foregroundStyle(.secondary)
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
        }
        .frame(height: 28)
    }
}

private struct DashboardSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(Theme.Fonts.sectionHeader).foregroundStyle(.secondary)
            content
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
