import AppKit
import SwiftUI

/// Overview: the capture strip, live signal chain, today's numbers and the
/// recent activity feed.
struct DashboardView: View {
    var onOpenAgents: () -> Void = {}
    var onOpenLibrary: () -> Void = {}
    var onOpenSettings: (SettingsPane) -> Void = { _ in }

    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var agents = AgentHub.shared
    @State private var stats: Core.Dashboard?
    @State private var error: String?
    @State private var levels: [CGFloat] = []
    @State private var levelGeneration = 0
    @State private var copiedID: Int?

    private let panelWidth: CGFloat = 420

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                metaLine
                hero.padding(.top, 16)
                captureRow.padding(.top, 34)

                if let error {
                    Text(error)
                        .font(Theme.Fonts.callout)
                        .foregroundStyle(Theme.Colors.err)
                        .textSelection(.enabled)
                        .padding(.top, 24)
                }

                if let stats {
                    metrics(stats).padding(.top, 44)
                    recent(stats).padding(.top, 40)
                } else if error == nil {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 60)
                }
            }
            .pageLayout()
            .padding(.bottom, 48)
        }
        .task { load() }
        .onReceive(NotificationCenter.default.publisher(for: .talkWtfCoreEvent)) { note in
            guard let raw = note.object as? String, raw.contains("history-update-payload") else { return }
            load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .talkWtfMicLevel)) { note in
            guard let incoming = note.object as? [CGFloat] else { return }
            levels = incoming
            levelGeneration += 1
            let generation = levelGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if generation == levelGeneration { levels = [] }
            }
        }
    }

    // MARK: - header

    private var metaLine: some View {
        HStack(spacing: 6) {
            Text(metaText)
                .font(Theme.Fonts.mono(11))
                .foregroundStyle(Theme.Colors.inkTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var metaText: String {
        var parts: [String] = []
        if let services = stats?.services, !services.asrModel.isEmpty {
            parts.append(services.asrModel)
        }
        if let services = stats?.services, !services.llmProvider.isEmpty {
            parts.append(services.llmProvider)
        }
        let count = agents.targets.count
        if count > 0 { parts.append("\(count) Agent") }
        return parts.joined(separator: "  /  ")
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("dashboard.hero.title"))
                .studioDisplay(44)
                .foregroundStyle(Theme.Colors.ink)
                .frame(maxWidth: 640, alignment: .leading)
            Text(L("dashboard.hero.subtitle"))
                .font(.system(size: 15))
                .foregroundStyle(Theme.Colors.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - capture

    private var captureRow: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 22) {
                captureStrip
                actions
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            signalPanel
                .frame(width: panelWidth)
        }
    }

    private var captureStrip: some View {
        VStack(spacing: 0) {
            Hairline()
            AcousticCanvas(levels: levels, active: !levels.isEmpty)
                .padding(.horizontal, 2)
            Hairline()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            DictationController.shared.toggle(mode: "dictation")
        }
        .help(L("dashboard.captureHint"))
    }

    private var actions: some View {
        HStack(spacing: 10) {
            StudioButton(
                title: L("dashboard.startDictation"),
                systemImage: "mic.fill",
                kind: .accent,
                height: 44,
                expands: true
            ) {
                DictationController.shared.toggle(mode: "dictation")
            }

            StudioButton(
                title: L("dashboard.startAutoAgent"),
                systemImage: "arrow.triangle.branch",
                kind: .ghost,
                height: 44,
                expands: true
            ) {
                DictationController.shared.toggle(mode: AgentHub.routerBindingID)
            }

            StudioButton(
                title: L("dashboard.startTranslate"),
                systemImage: "character.book.closed",
                kind: .ghost,
                height: 44,
                expands: true
            ) {
                DictationController.shared.toggle(mode: "translate")
            }
        }
    }

    private var signalPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(text: "LIVE SIGNAL")
                Spacer(minLength: 8)
                Text(stats?.services.pasteEnabled == true ? "PASTE ON" : "PASTE OFF")
                    .font(Theme.Fonts.mono(9.5, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Colors.inkTertiary)
            }
            .padding(.bottom, 10)

            VStack(spacing: 0) {
                signalRow(
                    label: L("dashboard.services.asr"),
                    value: stats?.services.asrModel ?? L("dashboard.services.none"),
                    detail: (stats?.services.asrReady ?? false) ? "LOCAL_READY" : "LOCAL_OFFLINE",
                    action: { onOpenSettings(.models) }
                )
                signalRow(
                    label: L("dashboard.services.llm"),
                    value: stats?.services.llmProvider.isEmpty == false
                        ? (stats?.services.llmProvider ?? "")
                        : L("dashboard.services.none"),
                    detail: (stats?.services.polishReady ?? false) ? "POLISH_READY" : "POLISH_OFF",
                    action: { onOpenSettings(.models) }
                )
                signalRow(
                    label: L("dashboard.services.routing"),
                    value: agents.targets.isEmpty
                        ? L("dashboard.services.noAgents")
                        : L("dashboard.services.agentCount", ["count": agents.targets.count]),
                    detail: nil,
                    action: onOpenAgents
                )
            }
            Spacer(minLength: 0)
        }
        .frame(width: panelWidth, alignment: .leading)
    }

    private func signalRow(
        label: String,
        value: String,
        detail: String?,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 0) {
            Hairline()
            SignalRow(label: label, value: value, detail: detail, action: action)
        }
    }

    // MARK: - metrics

    private func metrics(_ stats: Core.Dashboard) -> some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 0) {
                metricCell(
                    L("dashboard.today.recordings"),
                    value: "\(stats.today.recordings)",
                    unit: L("dashboard.units.times")
                )
                Hairline(vertical: true)
                metricCell(
                    L("dashboard.today.chars"),
                    value: "\(stats.today.chars)",
                    unit: L("dashboard.units.chars")
                )
                Hairline(vertical: true)
                metricCell(
                    L("dashboard.today.translations"),
                    value: "\(stats.today.translations)",
                    unit: L("dashboard.units.times")
                )
                Hairline(vertical: true)
                metricCell(
                    L("dashboard.today.dictationTime"),
                    value: duration(stats.today.dictationMs),
                    unit: L("dashboard.units.voice")
                )
            }
            .frame(height: 96)
            Hairline()
        }
    }

    private func metricCell(_ title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Colors.inkSecondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value)
                    .font(.system(size: 34, weight: .semibold))
                    .tracking(-1.1)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !unit.isEmpty {
                    Text(unit)
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Colors.inkTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }

    // MARK: - recent

    private func recent(_ stats: Core.Dashboard) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(
                text: L("dashboard.recent.title"),
                trailing: nil,
                action: onOpenLibrary,
                actionTitle: L("dashboard.recent.viewAll")
            )
            .padding(.bottom, 10)

            Hairline()

            if stats.recent.isEmpty {
                Text(L("dashboard.recent.empty"))
                    .font(Theme.Fonts.callout)
                    .foregroundStyle(Theme.Colors.inkSecondary)
                    .padding(.vertical, 18)
            } else {
                ForEach(stats.recent) { entry in
                    recentRow(entry)
                    Hairline()
                }
            }
        }
    }

    private func recentRow(_ entry: Core.Dashboard.Recent) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text(entry.preview)
                    .font(.system(size: 14.5))
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(entry.workflow == "translate"
                        ? L("dashboard.recent.translate")
                        : L("dashboard.recent.dictate"))
                    Text("·")
                    Text(L("dashboard.recent.chars", ["count": entry.charCount]))
                    Text("·")
                    Text(Date(timeIntervalSince1970: TimeInterval(entry.timestamp)), style: .relative)
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.Colors.inkTertiary)
            }
            Spacer(minLength: 12)
            HStack(spacing: 2) {
                StudioIconButton(
                    systemImage: copiedID == entry.id ? "checkmark" : "doc.on.doc",
                    help: L("dashboard.actions.copy")
                ) {
                    copy(entry)
                }
                StudioIconButton(systemImage: "arrow.up.right", help: L("dashboard.actions.open")) {
                    onOpenLibrary()
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 16)
        .contentShape(Rectangle())
    }

    private func copy(_ entry: Core.Dashboard.Recent) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.preview, forType: .string)
        copiedID = entry.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if copiedID == entry.id { copiedID = nil }
        }
    }

    // MARK: - data

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
        if hours > 0 { return "\(hours)h\(minutes)m" }
        if minutes > 0 { return "\(minutes)m\(seconds)s" }
        return "\(seconds)s"
    }
}
