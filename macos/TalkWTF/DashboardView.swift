import SwiftUI

/// Dashboard: local-only usage stats (today, all-time, last 7 days, LLM tokens,
/// service status and personalization progress).
struct DashboardView: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var stats: Core.Dashboard?
    @State private var error: String?

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 12)]
    private let fourColumns = Array(
        repeating: GridItem(.flexible(), spacing: 12),
        count: 4
    )

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                HStack {
                    Text(L("dashboard.title")).font(Theme.Fonts.largeTitle)
                    Spacer()
                    Button {
                        load()
                    } label: {
                        Label(L("dashboard.refresh"), systemImage: "arrow.clockwise")
                    }
                    Button(L("settings.debug.overlayPreview.title")) {
                        OverlayController.shared.show(.recording)
                    }
                }

                if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }

                if let stats {
                    todaySection(stats)
                    metricsSection(stats)
                    weeklySection(stats)
                    tokensSection(stats)
                    servicesSection(stats)
                    personalizationSection(stats)
                    recentSection(stats)
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

    // MARK: - sections

    private func todaySection(_ stats: Core.Dashboard) -> some View {
        GroupBox(L("dashboard.today.title")) {
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

    private func metricsSection(_ stats: Core.Dashboard) -> some View {
        GroupBox(L("dashboard.metrics.title")) {
            LazyVGrid(columns: columns, spacing: 12) {
                StatCard(
                    symbol: "mic.fill",
                    title: L("dashboard.metrics.totalRecordings"),
                    value: "\(stats.totalRecordings)"
                )
                StatCard(
                    symbol: "clock.fill",
                    title: L("dashboard.metrics.dictationTime"),
                    value: duration(stats.totalDictationMs)
                )
                StatCard(
                    symbol: "textformat.abc",
                    title: L("dashboard.metrics.chars"),
                    value: "\(stats.totalChars)"
                )
                StatCard(
                    symbol: "gauge.with.needle",
                    title: L("dashboard.metrics.speed"),
                    value: L("dashboard.metrics.charsPerMin", ["value": Int(stats.avgCharsPerMin)])
                )
                StatCard(
                    symbol: "hourglass",
                    title: L("dashboard.metrics.timeSaved"),
                    value: duration(stats.timeSavedMs)
                )
                StatCard(
                    symbol: "character.book.closed",
                    title: L("dashboard.metrics.translations"),
                    value: "\(stats.translationCount)"
                )
            }
            .padding(.vertical, 4)
        }
    }

    private func weeklySection(_ stats: Core.Dashboard) -> some View {
        GroupBox(L("dashboard.weekly.title")) {
            let peak = max(1, stats.weekly.map(\.count).max() ?? 1)
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(stats.weekly) { day in
                    VStack(spacing: 6) {
                        Text("\(day.count)")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(day.count > 0 ? .primary : .tertiary)
                        RoundedRectangle(cornerRadius: 5)
                            .fill(day.count > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                            .frame(width: 26, height: max(4, 88 * CGFloat(day.count) / CGFloat(peak)))
                        Text(day.day)
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .help(L("dashboard.weekly.recordings", ["count": day.count]))
                }
            }
            .frame(height: 140, alignment: .bottom)
            .padding(.vertical, 4)
        }
    }

    private func tokensSection(_ stats: Core.Dashboard) -> some View {
        GroupBox(L("dashboard.tokens.title")) {
            let hasUsage = stats.tokensToday.totalTokens > 0 || stats.tokensWeek.totalTokens > 0
            if !hasUsage {
                Text(L("dashboard.tokens.none"))
                    .font(Theme.Fonts.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        Text(L("dashboard.tokens.prompt")).foregroundStyle(.secondary)
                        Text(L("dashboard.tokens.completion")).foregroundStyle(.secondary)
                        Text(L("dashboard.tokens.total")).foregroundStyle(.secondary)
                        Text(L("dashboard.tokens.requests")).foregroundStyle(.secondary)
                    }
                    .font(Theme.Fonts.caption)
                    GridRow {
                        Text(L("dashboard.tokens.today")).fontWeight(.medium)
                        Text("\(stats.tokensToday.promptTokens)")
                        Text("\(stats.tokensToday.completionTokens)")
                        Text("\(stats.tokensToday.totalTokens)").fontWeight(.semibold)
                        Text("\(stats.tokensToday.requests)")
                    }
                    GridRow {
                        Text(L("dashboard.tokens.week")).fontWeight(.medium)
                        Text("\(stats.tokensWeek.promptTokens)")
                        Text("\(stats.tokensWeek.completionTokens)")
                        Text("\(stats.tokensWeek.totalTokens)").fontWeight(.semibold)
                        Text("\(stats.tokensWeek.requests)")
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func servicesSection(_ stats: Core.Dashboard) -> some View {
        GroupBox(L("dashboard.services.title")) {
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

    private func personalizationSection(_ stats: Core.Dashboard) -> some View {
        GroupBox(L("dashboard.personalization.title")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("dashboard.personalization.label"))
                    Spacer()
                    Text("\(stats.personalizationScore)%")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                ProgressView(value: Double(stats.personalizationScore), total: 100)
                ForEach(stats.personalizationItems, id: \.id) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.done ? .green : .secondary)
                        Text(L("dashboard.personalization.items.\(item.id)"))
                        Spacer()
                    }
                    .font(Theme.Fonts.body)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func recentSection(_ stats: Core.Dashboard) -> some View {
        GroupBox(L("dashboard.recent.title")) {
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
