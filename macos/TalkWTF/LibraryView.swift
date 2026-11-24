import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Library: transcription history and the dictionary, both from the Rust core.
struct LibraryView: View {
    private enum SortOrder: String { case newest, oldest }

    private enum Tab: String, CaseIterable, Identifiable {
        case history, dictionary
        var id: String { rawValue }
        var title: String { self == .history ? L("sidebar.history") : L("sidebar.dictionary") }
    }

    @State private var tab: Tab = .history
    @State private var entries: [Core.HistoryEntry] = []
    @State private var dictionary: Core.Dictionary?
    @State private var rejections: [String] = []
    @State private var query = ""
    @State private var sort: SortOrder = .newest
    @State private var newWord = ""
    @State private var newPattern = ""
    @State private var newReplacement = ""
    @State private var editingWord: Core.DictionaryWord?
    @State private var editingRule: Core.CorrectionRule?
    @State private var notice: String?
    @State private var error: String?
    @State private var retrying: Set<Int> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L("sidebar.library"))
                        .font(.system(size: 30, weight: .semibold))
                        .tracking(-0.7)
                        .foregroundStyle(Theme.Colors.ink)
                    Spacer()
                    Text(String(format: L("library.count"), entries.count))
                        .font(Theme.Fonts.mono(11))
                        .tracking(1.2)
                        .foregroundStyle(Theme.Colors.inkTertiary)
                }
                StudioTabs(items: Tab.allCases, title: { $0.title }, selection: $tab)
                    .padding(.top, 14)

                if let error {
                    Text(error).font(Theme.Fonts.callout).foregroundStyle(Theme.Colors.err)
                        .padding(.top, 16).textSelection(.enabled)
                }
                if let notice {
                    Text(notice).font(Theme.Fonts.callout).foregroundStyle(Theme.Colors.inkSecondary)
                        .padding(.top, 16).textSelection(.enabled)
                }

                Group {
                    switch tab {
                    case .history: historyList
                    case .dictionary: dictionaryList
                    }
                }
                .padding(.top, 22)
                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .pageLayout()
        }
        .task { load() }
        .onReceive(NotificationCenter.default.publisher(for: .talkWtfCoreEvent)) { note in
            guard let raw = note.object as? String else { return }
            if raw.contains("history-update-payload")
                || raw.contains("dictionary-changed")
                || raw.contains("learned-correction")
            {
                load()
            }
        }
        .sheet(item: $editingWord) { word in
            WordEditor(word: word.word) { updated in
                run("update_dictionary_word", ["id": word.id, "word": updated])
            }
        }
        .sheet(item: $editingRule) { rule in
            RuleEditor(rule: rule) { pattern, replacement in
                run("update_correction_rule", [
                    "id": rule.id, "pattern": pattern, "replacement": replacement,
                ])
            }
        }
    }

    // MARK: - history

    private var filteredEntries: [Core.HistoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let recovered = entries.filter { !Self.isUnrecovered($0) }
        let matches = needle.isEmpty
            ? recovered
            : recovered.filter {
                $0.transcription.lowercased().contains(needle)
                    || ($0.postProcessed ?? "").lowercased().contains(needle)
            }
        return sort == .newest
            ? matches.sorted { $0.timestamp > $1.timestamp }
            : matches.sorted { $0.timestamp < $1.timestamp }
    }

    /// A recording whose transcript came back empty: the audio is on disk, so
    /// it can still be recognised, exported, or thrown away.
    static func isUnrecovered(_ entry: Core.HistoryEntry) -> Bool {
        entry.transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var unrecovered: [Core.HistoryEntry] {
        entries
            .filter { Self.isUnrecovered($0) }
            .sorted { $0.timestamp > $1.timestamp }
    }

    private var historyList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.inkTertiary)
                    TextField(L("library.searchPlaceholder"), text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5))
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .frame(maxWidth: 320)
                .overlay(Rectangle().stroke(Theme.Colors.hairline, lineWidth: 1))

                Picker("", selection: $sort) {
                    Text(L("settings.history.sort.newest")).tag(SortOrder.newest)
                    Text(L("settings.history.sort.oldest")).tag(SortOrder.oldest)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 118)

                Spacer()

                StudioButton(title: L("settings.history.openFolder"), systemImage: "folder", kind: .ghost) {
                    NSWorkspace.shared.open(AppPaths.recordingsDirectory)
                }
            }
            .padding(.bottom, 18)

            if !unrecovered.isEmpty && query.isEmpty {
                recoverySection
                    .padding(.bottom, 8)
            }

            if filteredEntries.isEmpty {
                Text(query.isEmpty ? L("settings.history.empty") : L("settings.history.noMatches"))
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.inkSecondary)
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .overlay(alignment: .top) { Hairline() }
            } else {
                VStack(spacing: 0) {
                    Hairline()
                    ForEach(filteredEntries) { entry in
                        historyRow(entry)
                        Hairline()
                    }
                }
            }
        }
    }

    /// "Black box" block: recordings kept even though transcription failed.
    private var recoverySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: L("library.recovery.title"), trailing: "\(unrecovered.count)")
            ForEach(unrecovered) { entry in
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.fileName)
                            .font(Theme.Fonts.mono(11.5))
                            .foregroundStyle(Theme.Colors.ink)
                            .lineLimit(1)
                        HStack(spacing: 7) {
                            Text(Self.relative(entry.timestamp))
                            if entry.durationMs > 0 {
                                Text("·")
                                Text(Self.shortDuration(entry.durationMs))
                            }
                            Text("·")
                            Text(L("library.recovery.kept"))
                        }
                        .font(Theme.Fonts.mono(10.5))
                        .foregroundStyle(Theme.Colors.inkTertiary)
                    }
                    Spacer(minLength: 12)
                    HStack(spacing: 4) {
                        StudioButton(title: L("settings.history.retranscribe"), systemImage: "arrow.clockwise", kind: .ghost, height: 28) {
                            retranscribe(entry.id)
                        }
                        .disabled(retrying.contains(entry.id))
                        StudioIconButton(systemImage: "square.and.arrow.up", help: L("library.recovery.export")) {
                            exportAudio(entry)
                        }
                        StudioIconButton(systemImage: "trash", help: L("common.delete")) {
                            run("delete_history_entry", ["id": entry.id])
                        }
                    }
                }
                .padding(.vertical, 12)
                Hairline()
            }
        }
        .padding(.bottom, 10)
    }

    /// Copy the saved audio somewhere the user chooses.
    private func exportAudio(_ entry: Core.HistoryEntry) {
        guard let source = RecordingPlayer.audioURL(for: entry.fileName) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = source.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// What you got, the raw transcript when it differs, then the metadata line.
    private func historyRow(_ entry: Core.HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.display)
                        .font(.system(size: 14.5))
                        .foregroundStyle(Theme.Colors.ink)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    if let raw = entry.rawIfDifferent {
                        Text(raw)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.Colors.inkTertiary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    RecordingPlayButton(entryId: entry.id, fileName: entry.fileName)
                    StudioIconButton(systemImage: "doc.on.doc", help: L("common.copy")) {
                        copy(entry.display)
                    }
                    StudioIconButton(
                        systemImage: retrying.contains(entry.id) ? "arrow.triangle.2.circlepath" : "arrow.clockwise",
                        help: L("settings.history.retranscribe")
                    ) {
                        retranscribe(entry.id)
                    }
                    .disabled(retrying.contains(entry.id))
                    StudioIconButton(systemImage: "trash", help: L("common.delete")) {
                        run("delete_history_entry", ["id": entry.id])
                    }
                }
            }

            HStack(spacing: 7) {
                Image(systemName: entry.workflow == "translate" ? "character.book.closed" : "mic")
                    .font(.system(size: 10.5))
                Text(entry.workflow == "translate"
                    ? L("dashboard.workflow.translate") : L("dashboard.workflow.dictation"))
                Text("·")
                Text(Self.relative(entry.timestamp))
                if entry.durationMs > 0 {
                    Text("·")
                    Text(Self.shortDuration(entry.durationMs))
                }
            }
            .font(Theme.Fonts.mono(11))
            .foregroundStyle(Theme.Colors.inkTertiary)
        }
        .padding(.vertical, 15)
        .contentShape(Rectangle())
    }

    /// Locale-aware relative stamp ("3 分钟前"), not the en-only `.relative` style.
    static func relative(_ timestamp: Int) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: Localization.shared.language == "zh" ? "zh_Hans_CN" : "en_US")
        formatter.unitsStyle = .short
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func shortDuration(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1000
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }

    // MARK: - dictionary

    private var dictionaryList: some View {
        VStack(alignment: .leading, spacing: 30) {
            wordsSection
            rulesSection
            rejectedSection
        }
        .padding(.bottom, 20)
    }

    private var wordsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: L("settings.dictionary.wordsTitle"), trailing: "\(dictionary?.words.count ?? 0)")
            HStack(spacing: 10) {
                TextField(L("settings.advanced.customWords.placeholder"), text: $newWord)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 260)
                    .overlay(Rectangle().stroke(Theme.Colors.hairline, lineWidth: 1))
                StudioButton(title: L("settings.advanced.customWords.add"), systemImage: "plus", kind: .ghost) {
                    run("add_dictionary_word", ["word": newWord])
                    newWord = ""
                }
                .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                StudioButton(title: L("settings.dictionary.import"), systemImage: "square.and.arrow.down", kind: .quiet) {
                    importDictionary()
                }
                StudioButton(title: L("settings.dictionary.export"), systemImage: "square.and.arrow.up", kind: .quiet) {
                    exportDictionary()
                }
                .disabled((dictionary?.words.isEmpty ?? true) && (dictionary?.rules.isEmpty ?? true))
            }
            .padding(.vertical, 14)

            ForEach(dictionary?.words ?? []) { word in
                Hairline()
                HStack(spacing: 12) {
                    Text(word.word)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.Colors.ink)
                    Spacer()
                    StudioIconButton(systemImage: "pencil", help: L("settings.postProcessing.scene.edit")) {
                        editingWord = word
                    }
                    StudioIconButton(systemImage: "trash", help: L("common.delete")) {
                        run("delete_dictionary_word", ["id": word.id])
                    }
                }
                .padding(.vertical, 11)
            }
            if !(dictionary?.words.isEmpty ?? true) { Hairline() }
        }
    }

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: L("settings.dictionary.rulesTitle"), trailing: "\(dictionary?.rules.count ?? 0)")
            HStack(spacing: 8) {
                TextField(L("settings.dictionary.patternPlaceholder"), text: $newPattern)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .overlay(Rectangle().stroke(Theme.Colors.hairline, lineWidth: 1))
                Image(systemName: "arrow.right")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.inkTertiary)
                TextField(L("settings.dictionary.replacementPlaceholder"), text: $newReplacement)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .overlay(Rectangle().stroke(Theme.Colors.hairline, lineWidth: 1))
                StudioButton(title: L("settings.advanced.customWords.add"), systemImage: "plus", kind: .ghost) {
                    run("add_correction_rule", [
                        "pattern": newPattern, "replacement": newReplacement,
                    ])
                    newPattern = ""
                    newReplacement = ""
                }
                .disabled(newPattern.isEmpty || newReplacement.isEmpty)
            }
            .padding(.vertical, 14)

            ForEach(dictionary?.rules ?? []) { rule in
                Hairline()
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(
                        get: { rule.enabled },
                        set: { run("set_correction_rule_enabled", ["id": rule.id, "enabled": $0]) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    Text(rule.pattern)
                        .font(Theme.Fonts.mono(13))
                        .foregroundStyle(rule.enabled ? Theme.Colors.ink : Theme.Colors.inkTertiary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Colors.inkTertiary)
                    Text(rule.replacement)
                        .font(.system(size: 13))
                        .foregroundStyle(rule.enabled ? Theme.Colors.inkSecondary : Theme.Colors.inkTertiary)
                    Spacer()
                    StudioIconButton(systemImage: "pencil", help: L("settings.postProcessing.scene.edit")) {
                        editingRule = rule
                    }
                    StudioIconButton(systemImage: "trash", help: L("common.delete")) {
                        run("delete_correction_rule", ["id": rule.id])
                    }
                }
                .padding(.vertical, 11)
            }
            if !(dictionary?.rules.isEmpty ?? true) { Hairline() }
        }
    }

    private var rejectedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: L("settings.dictionary.learn.rejectedTitle"), trailing: "\(rejections.count)")
            Text(L("settings.dictionary.learn.rejectedDescription"))
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.inkTertiary)
                .padding(.top, 6)
                .padding(.bottom, 12)
            ForEach(rejections, id: \.self) { pattern in
                Hairline()
                HStack(spacing: 12) {
                    Text(pattern)
                        .font(Theme.Fonts.mono(12.5))
                        .foregroundStyle(Theme.Colors.inkSecondary)
                    Spacer()
                    StudioButton(title: L("settings.dictionary.learn.rejectedRestore"), kind: .quiet) {
                        run("forget_learning_rejection", ["pattern": pattern])
                    }
                }
                .padding(.vertical, 10)
            }
            if !rejections.isEmpty {
                Hairline()
                StudioButton(title: L("settings.dictionary.learn.rejectedClear"), kind: .quiet) {
                    run("clear_learning_rejections")
                }
                .padding(.top, 10)
            }
        }
    }

    // MARK: - actions

    /// Re-run transcription on a saved recording and refresh the row.
    private func retranscribe(_ id: Int) {
        retrying.insert(id)
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try Core.invoke("retry_history_entry_transcription", ["id": id])
                DispatchQueue.main.async {
                    retrying.remove(id)
                    load()
                }
            } catch {
                DispatchQueue.main.async {
                    retrying.remove(id)
                    // A dictation in flight is expected, not an error worth a
                    // red line: it gets its own explanation.
                    if !BusyAlert.shared.handle(error) {
                        self.error = L("settings.history.retranscribeError")
                    }
                    NSLog("TalkWTF: re-transcribe failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Run a command and refresh; surfaces the core's message on failure.
    private func run(_ command: String, _ payload: [String: Any] = [:]) {
        do {
            _ = try Core.invoke(command, payload)
            notice = nil
            error = nil
            load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func importDictionary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let report = try Core.invoke("import_dictionary", ["path": url.path]) as? [String: Any] ?? [:]
            let accepted = (report["accepted"] as? NSNumber)?.intValue ?? 0
            let duplicates = (report["skipped_duplicates"] as? NSNumber)?.intValue ?? 0
            let invalid = (report["skipped_invalid"] as? NSNumber)?.intValue ?? 0
            notice = L("settings.dictionary.importReport", [
                "accepted": accepted, "duplicates": duplicates, "invalid": invalid,
            ])
            error = nil
            load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func exportDictionary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "talkwtf-dictionary.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try Core.invoke("export_dictionary", ["path": url.path])
            notice = L("settings.dictionary.exportDone")
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func load() {
        do {
            entries = try Core.historyEntries()
            if ProcessInfo.processInfo.environment["TALKWTF_FAKE_UNRECOVERED"] == "1" {
                entries.insert(Core.HistoryEntry([
                    "id": -1, "file_name": "未识别-示例.wav",
                    "timestamp": Int(Date().timeIntervalSince1970) - 180,
                    "workflow": "dictation", "char_count": 0, "duration_ms": 8400,
                    "saved": false, "transcription_text": "",
                ]), at: 0)
            }
            dictionary = try Core.dictionary()
            rejections = (try? Core.invoke("list_learning_rejections") as? [String]) ?? []
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct WordEditor: View {
    @State var word: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("settings.advanced.customWords.title")).font(.title3.bold())
            TextField(L("settings.dictionary.wordsTitle"), text: $word)
            HStack {
                Spacer()
                Button(L("settings.postProcessing.prompts.cancel")) { dismiss() }
                Button(L("settings.postProcessing.prompts.updatePrompt")) { onSave(word); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

private struct RuleEditor: View {
    let rule: Core.CorrectionRule
    @State private var pattern: String
    @State private var replacement: String
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    init(rule: Core.CorrectionRule, onSave: @escaping (String, String) -> Void) {
        self.rule = rule
        self.onSave = onSave
        _pattern = State(initialValue: rule.pattern)
        _replacement = State(initialValue: rule.replacement)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("settings.dictionary.rulesTitle")).font(.title3.bold())
            TextField(L("settings.dictionary.patternPlaceholder"), text: $pattern)
            TextField(L("settings.dictionary.replacementPlaceholder"), text: $replacement)
            HStack {
                Spacer()
                Button(L("settings.postProcessing.prompts.cancel")) { dismiss() }
                Button(L("settings.postProcessing.prompts.updatePrompt")) { onSave(pattern, replacement); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
