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
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                HStack {
                    Text(L("sidebar.library")).font(Theme.Fonts.largeTitle)
                    Spacer()
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }

                if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
                if let notice {
                    Text(notice).foregroundStyle(.secondary).textSelection(.enabled)
                }

                switch tab {
                case .history:
                    historyList
                case .dictionary:
                    dictionaryList
                }
            }
            .pageLayout()
        }
        .task { load() }
        .onReceive(NotificationCenter.default.publisher(for: .talkWtfCoreEvent)) { note in
            guard let raw = note.object as? String, raw.contains("history-update-payload") else { return }
            load()
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
        let matches = needle.isEmpty
            ? entries
            : entries.filter {
                $0.transcription.lowercased().contains(needle)
                    || ($0.postProcessed ?? "").lowercased().contains(needle)
            }
        return sort == .newest
            ? matches.sorted { $0.timestamp > $1.timestamp }
            : matches.sorted { $0.timestamp < $1.timestamp }
    }

    private var historyList: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.row) {
            HStack(spacing: Theme.Spacing.row) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L("settings.history.searchPlaceholder"), text: $query)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                .frame(height: Theme.Control.fieldHeight)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: 280)

                Picker("", selection: $sort) {
                    Text(L("settings.history.sort.newest")).tag(SortOrder.newest)
                    Text(L("settings.history.sort.oldest")).tag(SortOrder.oldest)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 130)

                Spacer()

                Button(L("settings.history.openFolder")) {
                    NSWorkspace.shared.open(AppPaths.recordingsDirectory)
                }
            }

            if filteredEntries.isEmpty {
                Text(query.isEmpty ? L("settings.history.empty") : L("settings.history.noMatches"))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, Theme.Spacing.section)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ForEach(filteredEntries) { entry in
                    historyRow(entry)
                    Divider()
                }
            }
        }
    }

    /// Spokenly-style row: what you got, the raw transcript when it differs, then
    /// the metadata line.
    private func historyRow(_ entry: Core.HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: Theme.Spacing.row) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.display)
                        .font(Theme.Fonts.body)
                        .lineLimit(3)
                    if let raw = entry.rawIfDifferent {
                        Text(raw)
                            .font(Theme.Fonts.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    RecordingPlayButton(entryId: entry.id, fileName: entry.fileName)

                    Button {
                        copy(entry.display)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help(L("common.copy"))
                    .accessibilityLabel(L("common.copy"))

                    Button {
                        retranscribe(entry.id)
                    } label: {
                        Image(systemName: retrying.contains(entry.id)
                            ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    }
                    .disabled(retrying.contains(entry.id))
                    .help(L("settings.history.retranscribe"))
                    .accessibilityLabel(L("settings.history.retranscribe"))

                    Button {
                        run("delete_history_entry", ["id": entry.id])
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help(L("common.delete"))
                    .accessibilityLabel(L("common.delete"))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Image(systemName: entry.workflow == "translate" ? "character.book.closed" : "mic")
                Text(entry.workflow == "translate"
                    ? L("dashboard.workflow.translate") : L("dashboard.workflow.dictation"))
                Text("·")
                Text(Date(timeIntervalSince1970: TimeInterval(entry.timestamp)), style: .relative)
                if entry.durationMs > 0 {
                    Text("·")
                    Text(Self.shortDuration(entry.durationMs))
                }
            }
            .font(Theme.Fonts.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    static func shortDuration(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1000
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }

    // MARK: - dictionary

    private var dictionaryList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox(L("settings.dictionary.wordsTitle")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField(L("settings.advanced.customWords.placeholder"), text: $newWord)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 260)
                            Button(L("settings.advanced.customWords.add")) {
                                run("add_dictionary_word", ["word": newWord])
                                newWord = ""
                            }
                            .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                            Spacer()
                            Button(L("settings.dictionary.import")) { importDictionary() }
                            Button(L("settings.dictionary.export")) { exportDictionary() }
                                .disabled((dictionary?.words.isEmpty ?? true) && (dictionary?.rules.isEmpty ?? true))
                        }
                        ForEach(dictionary?.words ?? []) { word in
                            HStack {
                                Text(word.word)
                                Spacer()
                                Button(L("settings.postProcessing.scene.edit")) { editingWord = word }
                                    .buttonStyle(.link)
                                Button(L("common.delete")) {
                                    run("delete_dictionary_word", ["id": word.id])
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox(L("settings.dictionary.rulesTitle")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField(L("settings.dictionary.patternPlaceholder"), text: $newPattern)
                                .textFieldStyle(.roundedBorder)
                            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                            TextField(L("settings.dictionary.replacementPlaceholder"), text: $newReplacement)
                                .textFieldStyle(.roundedBorder)
                            Button(L("settings.advanced.customWords.add")) {
                                run("add_correction_rule", [
                                    "pattern": newPattern, "replacement": newReplacement,
                                ])
                                newPattern = ""
                                newReplacement = ""
                            }
                            .disabled(newPattern.isEmpty || newReplacement.isEmpty)
                        }
                        ForEach(dictionary?.rules ?? []) { rule in
                            HStack {
                                Toggle("", isOn: Binding(
                                    get: { rule.enabled },
                                    set: { run("set_correction_rule_enabled", ["id": rule.id, "enabled": $0]) }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                Text(rule.pattern).foregroundStyle(rule.enabled ? .primary : .secondary)
                                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                                Text(rule.replacement)
                                Spacer()
                                Button(L("settings.postProcessing.scene.edit")) { editingRule = rule }
                                    .buttonStyle(.link)
                                Button(L("common.delete")) {
                                    run("delete_correction_rule", ["id": rule.id])
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox(L("settings.dictionary.learn.rejectedTitle")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("settings.dictionary.learn.rejectedDescription"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(rejections, id: \.self) { pattern in
                            HStack {
                                Text(pattern)
                                Spacer()
                                Button(L("settings.dictionary.learn.rejectedRestore")) {
                                    run("forget_learning_rejection", ["pattern": pattern])
                                }
                                .buttonStyle(.link)
                            }
                        }
                        if !rejections.isEmpty {
                            Button(L("settings.dictionary.learn.rejectedClear")) {
                                run("clear_learning_rejections")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.bottom, 20)
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
