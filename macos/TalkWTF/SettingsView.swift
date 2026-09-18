import SwiftUI

/// Settings: a native `Form`, split into panes, bound to the Rust core.
struct SettingsView: View {
    let pane: SettingsPane
    @ObservedObject private var store = SettingsStore.shared
    @State private var accelerators: [String: Any] = [:]
    @State private var recognition: [String: Any] = [:]
    @ObservedObject private var keyboard = KeyboardDiagnostic.shared
    @State private var secureInput: [String: Any] = [:]
    @ObservedObject private var recorder = ShortcutRecorder.shared
    @State private var inputDevices: [[String: Any]] = []
    @State private var outputDevices: [[String: Any]] = []
    @State private var learningAttempts: [Core.LearningAttempt] = []
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("settings.panes.\(pane.rawValue)"))
                    .font(Theme.Fonts.largeTitle)

                if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }

                switch pane {
                case .general: generalPane
                case .personalization: PersonalizationView()
                case .models: ModelsView(accelerators: accelerators)
                case .audio: audioPane
                case .advanced: advancedPane
                case .debug: debugPane
                case .about: aboutPane
                }
                Spacer()
            }
            .pageLayout()
        }
        .task { load() }
        .onReceive(
            NotificationCenter.default.publisher(for: .talkWtfCoreEvent)
                .receive(on: DispatchQueue.main)
        ) { note in
            guard let raw = note.object as? String, raw.contains("secure-input-changed") else { return }
            refreshSecureInput()
        }
    }

    // MARK: - general

    private var generalPane: some View {
        Form {
            Section(L("settings.general.title")) {
                Picker(L("appLanguage.title"), selection: store.binding("app_language", default: "en")) {
                    ForEach(Languages.all) { language in
                        Text(language.nativeName).tag(language.code)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: store.string("app_language")) { _, language in
                    Localization.shared.load(language: language)
                }

                Picker(L("settings.general.language.title"), selection: store.binding("selected_language", default: "auto")) {
                    ForEach(recognitionOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .pickerStyle(.menu)
                Text(L("settings.general.language.description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(L("theme.title"), selection: store.binding("theme", default: "system")) {
                    Text(L("theme.options.system")).tag("system")
                    Text(L("theme.options.light")).tag("light")
                    Text(L("theme.options.dark")).tag("dark")
                }
                .pickerStyle(.menu)
                .onChange(of: store.string("theme", "system")) { _, theme in
                    ThemeController.apply(theme)
                }
            }

            Section(L("settings.general.shortcutsGroup")) {
                Picker(
                    L("settings.general.shortcutActivation.title"),
                    selection: store.binding("shortcut_activation", default: "hold_or_toggle")
                ) {
                    Text(L("settings.general.shortcutActivation.options.holdOrToggle")).tag("hold_or_toggle")
                    Text(L("settings.general.shortcutActivation.options.pushToTalk")).tag("push_to_talk")
                    Text(L("settings.general.shortcutActivation.options.toggle")).tag("toggle")
                }
                .pickerStyle(.menu)

                if store.string("shortcut_activation", "hold_or_toggle") == "hold_or_toggle" {
                    sliderField(
                        "hold_threshold_ms",
                        "settings.debug.holdThreshold.title",
                        description: "settings.debug.holdThreshold.description",
                        range: 100...1000,
                        step: 50,
                        format: { "\(Int($0)) ms" }
                    )
                }

                ForEach(["transcribe", "transcribe_with_post_process", "translate", "cancel"], id: \.self) { id in
                    shortcutRow(id)
                }
            }

            Section(L("settings.general.behaviorGroup")) {
                Toggle(L("settings.advanced.startHidden.label"), isOn: store.boolBinding("start_hidden"))
                Toggle(L("settings.advanced.autostart.label"), isOn: store.boolBinding("autostart_enabled"))
                    .onChange(of: store.bool("autostart_enabled")) { _, enabled in
                        Autostart.apply(enabled)
                    }
                Toggle(L("settings.advanced.showTrayIcon.label"), isOn: store.boolBinding("show_tray_icon"))
                    .onChange(of: store.bool("show_tray_icon")) { _, visible in
                        TrayController.shared.setVisible(visible)
                    }
                Picker(L("settings.advanced.overlay.style.title"), selection: store.binding("overlay_style", default: "minimal")) {
                    Text(L("settings.advanced.overlay.style.options.none")).tag("none")
                    Text(L("settings.advanced.overlay.style.options.minimal")).tag("minimal")
                    Text(L("settings.advanced.overlay.style.options.live")).tag("live")
                }
                .pickerStyle(.menu)
                Picker(L("settings.advanced.overlay.position.title"), selection: store.binding("overlay_position", default: "bottom")) {
                    Text(L("settings.advanced.overlay.position.options.top")).tag("top")
                    Text(L("settings.advanced.overlay.position.options.bottom")).tag("bottom")
                }
                .pickerStyle(.menu)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - audio

    private var audioPane: some View {
        Form {
            Section(L("settings.sound.microphone.title")) {
                Picker(L("settings.sound.microphone.title"), selection: store.binding("selected_microphone", default: "")) {
                    Text(L("settings.sound.microphone.placeholder")).tag("")
                    ForEach(inputDevices.indices, id: \.self) { index in
                        if let name = inputDevices[index]["name"] as? String {
                            Text(name).tag(name)
                        }
                    }
                }
                .pickerStyle(.menu)

                Picker(L("settings.sound.channel.title"), selection: store.intBinding("selected_channel", default: 0)) {
                    Text(L("settings.sound.channel.average")).tag(0)
                    Text(L("settings.sound.channel.channel", ["n": 1])).tag(1)
                    Text(L("settings.sound.channel.channel", ["n": 2])).tag(2)
                }
                .pickerStyle(.menu)

                Toggle(L("settings.debug.alwaysOnMicrophone.label"), isOn: store.boolBinding("always_on_microphone"))
                Toggle(L("settings.debug.muteWhileRecording.label"), isOn: store.boolBinding("mute_while_recording"))
            }
            Section(L("settings.sound.outputDevice.title")) {
                Picker(L("settings.sound.outputDevice.title"), selection: store.binding("selected_output_device", default: "")) {
                    Text(L("settings.sound.outputDevice.placeholder")).tag("")
                    ForEach(outputDevices.indices, id: \.self) { index in
                        if let name = outputDevices[index]["name"] as? String {
                            Text(name).tag(name)
                        }
                    }
                }
                .pickerStyle(.menu)

                Toggle(L("settings.sound.audioFeedback.label"), isOn: store.boolBinding("audio_feedback"))
                Picker(L("settings.debug.soundTheme.label"), selection: store.binding("sound_theme", default: "marimba")) {
                    Text("Marimba").tag("marimba")
                    Text("Pop").tag("pop")
                    Text(L("modelSelector.custom")).tag("custom")
                }
                .pickerStyle(.menu)
                .onChange(of: store.string("sound_theme", "marimba")) { _, _ in
                    SoundPlayer.playPreview(.start)
                }
                LabeledContent(L("settings.sound.volume.title")) {
                    Slider(
                        value: Binding(
                            get: { store.double("audio_feedback_volume", 1.0) },
                            set: { store.patch(["audio_feedback_volume": $0]) }
                        ),
                        in: 0...1
                    )
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - advanced

    private var advancedPane: some View {
        Form {
            Section(L("settings.advanced.groups.output")) {
                Picker(L("settings.advanced.pasteMethod.title"), selection: store.binding("paste_method", default: "ctrl_v")) {
                    Text(L("settings.advanced.pasteMethod.options.clipboard", ["modifier": "⌘"])).tag("ctrl_v")
                    Text(L("settings.advanced.pasteMethod.options.clipboardShiftInsert", ["modifier": "⇧"])).tag("shift_insert")
                    Text(L("settings.advanced.pasteMethod.options.clipboardCtrlShiftV", ["modifier": "⌘⇧"])).tag("ctrl_shift_v")
                    Text(L("settings.advanced.pasteMethod.options.direct")).tag("direct")
                    Text(L("settings.advanced.pasteMethod.options.none")).tag("none")
                }
                .pickerStyle(.menu)

                delayField("paste_delay_ms", "settings.debug.pasteDelay.title", description: "settings.debug.pasteDelay.description")
                delayField("paste_delay_after_ms", "settings.debug.pasteDelayAfter.title", description: "settings.debug.pasteDelayAfter.description")
                Toggle(L("settings.debug.reliablePaste.title"), isOn: store.boolBinding("reliable_paste"))

                Picker(L("settings.advanced.clipboardHandling.title"), selection: store.binding("clipboard_handling", default: "dont_modify")) {
                    Text(L("settings.advanced.clipboardHandling.options.dontModify")).tag("dont_modify")
                    Text(L("settings.advanced.clipboardHandling.options.copyToClipboard")).tag("copy_to_clipboard")
                }
                .pickerStyle(.menu)

                Picker(L("settings.advanced.autoSubmit.title"), selection: store.binding("auto_submit_key", default: "off")) {
                    Text(L("settings.advanced.autoSubmit.options.off")).tag("off")
                    Text(L("settings.advanced.autoSubmit.options.enter")).tag("enter")
                    Text(L("settings.advanced.autoSubmit.options.ctrlEnter")).tag("ctrl_enter")
                    Text(L("settings.advanced.autoSubmit.options.cmdEnter")).tag("cmd_enter")
                }
                .pickerStyle(.menu)

                Toggle(L("settings.debug.appendTrailingSpace.label"), isOn: store.boolBinding("append_trailing_space"))
            }
            Section(L("settings.advanced.groups.transcription")) {
                Toggle(L("settings.advanced.voiceActivityDetection.title"), isOn: store.boolBinding("vad_enabled"))
                Picker(L("settings.advanced.vadBackend.title"), selection: store.binding("vad_backend", default: "silero")) {
                    Text(L("settings.advanced.vadBackend.options.silero")).tag("silero")
                    Text(L("settings.advanced.vadBackend.options.earshot")).tag("earshot")
                }
                .pickerStyle(.menu)
                Toggle(L("settings.advanced.fillerWordRemoval.title"), isOn: store.boolBinding("filler_word_removal_enabled"))
                Toggle(L("settings.dictionary.learn.title"), isOn: store.boolBinding("learn_from_edits"))
                Toggle(L("settings.advanced.translateToEnglish.label"), isOn: store.boolBinding("translate_to_english"))
                sliderField(
                    "word_correction_threshold",
                    "settings.debug.wordCorrectionThreshold.title",
                    description: "settings.debug.wordCorrectionThreshold.description",
                    range: 0.01...1.0,
                    step: 0.01,
                    format: { "\(Int(($0 * 100).rounded()))%" }
                )
                Picker(L("settings.advanced.modelUnload.title"), selection: store.binding("model_unload_timeout", default: "min5")) {
                    Text(L("settings.advanced.modelUnload.options.immediately")).tag("immediately")
                    Text(L("settings.advanced.modelUnload.options.sec15")).tag("sec15")
                    Text(L("settings.advanced.modelUnload.options.min2")).tag("min2")
                    Text(L("settings.advanced.modelUnload.options.min5")).tag("min5")
                    Text(L("settings.advanced.modelUnload.options.min10")).tag("min10")
                    Text(L("settings.advanced.modelUnload.options.min15")).tag("min15")
                    Text(L("settings.advanced.modelUnload.options.hour1")).tag("hour1")
                    Text(L("settings.advanced.modelUnload.options.never")).tag("never")
                }
                .pickerStyle(.menu)
            }
            Section(L("settings.advanced.groups.history")) {
                LabeledContent(L("settings.debug.historyLimit.title")) {
                    Stepper(
                        value: store.intBinding("history_limit", default: 5),
                        in: 0...1000
                    ) {
                        Text("\(store.int("history_limit", 5)) \(L("settings.debug.historyLimit.entries"))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Picker(L("settings.debug.recordingRetention.title"), selection: store.binding("recording_retention_period", default: "preserve_limit")) {
                    Text(L("settings.debug.recordingRetention.preserveLimit")).tag("preserve_limit")
                    Text(L("settings.debug.recordingRetention.never")).tag("never")
                    Text(L("settings.debug.recordingRetention.days3")).tag("days3")
                    Text(L("settings.debug.recordingRetention.weeks2")).tag("weeks2")
                    Text(L("settings.debug.recordingRetention.months3")).tag("months3")
                }
                .pickerStyle(.menu)
            }
            Section(L("settings.advanced.groups.experimental")) {
                Toggle(L("settings.advanced.experimentalToggle.label"), isOn: store.boolBinding("experimental_enabled"))
                Text(L("settings.advanced.experimentalToggle.description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(L("settings.advanced.lazyStreamClose.label"), isOn: store.boolBinding("lazy_stream_close"))
            }
            Section(L("settings.advanced.groups.app")) {
                Picker(L("settings.advanced.acceleration.transcribe.title"), selection: store.binding("transcription_accelerator", default: "auto")) {
                    Text(L("settings.advanced.acceleration.gpuDevice.auto")).tag("auto")
                    ForEach(acceleratorOptions, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .pickerStyle(.menu)
                Text(L("settings.advanced.acceleration.transcribe.description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - debug

    private var debugPane: some View {
        Form {
            Section(L("settings.debug.logLevel.title")) {
                Picker(L("settings.debug.logLevel.title"), selection: store.binding("log_level", default: "debug")) {
                    Text("Trace").tag("trace")
                    Text("Debug").tag("debug")
                    Text("Info").tag("info")
                    Text("Warn").tag("warn")
                    Text("Error").tag("error")
                }
                .pickerStyle(.menu)
                Toggle(L("settings.dictionary.diagnose.title"), isOn: store.boolBinding("debug_mode"))
                LabeledContent(L("settings.debug.logDirectory.title")) {
                    Button(L("common.open")) { NSWorkspace.shared.open(AppPaths.logDirectory) }
                }
            }
            Section(L("settings.advanced.groups.app")) {
                delayField(
                    "extra_recording_buffer_ms",
                    "settings.debug.recordingBuffer.title",
                    description: "settings.debug.recordingBuffer.description"
                )
                Toggle(L("settings.debug.updateChecks.label"), isOn: store.boolBinding("update_checks_enabled"))
                Picker(L("settings.debug.keyboardImplementation.title"), selection: store.binding("keyboard_implementation", default: "handy_keys")) {
                    Text("handy-keys").tag("handy_keys")
                    Text("Tauri").tag("tauri")
                }
                .pickerStyle(.menu)
            }
            Section(L("settings.debug.overlayPreview.title")) {
                Text(L("settings.debug.overlayPreview.description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    previewButton(.recording, "settings.debug.overlayPreview.recording")
                    previewButton(.streaming, "settings.debug.overlayPreview.streaming")
                    previewButton(.transcribing, "settings.debug.overlayPreview.transcribing")
                }
                HStack {
                    previewButton(.processing(label: nil), "settings.debug.overlayPreview.processing")
                    previewButton(.translating(label: "English (English)"), "settings.debug.overlayPreview.translating")
                }
                HStack {
                    previewButton(
                        .learned(pattern: "浏览起", replacement: "浏览器", count: 1),
                        "settings.debug.overlayPreview.learned"
                    )
                    previewButton(
                        .translationFailed(label: "English (English)"),
                        "settings.debug.overlayPreview.translationFailed"
                    )
                    previewButton(.notice(kind: "no_target"), "settings.debug.overlayPreview.notice")
                }
            }
            Section(L("settings.dictionary.diagnose.title")) {
                LabeledContent(
                    L("onboarding.permissions.accessibility.title"),
                    value: Permissions.accessibilityGranted ? L("dashboard.services.enabled") : L("dashboard.services.disabled")
                )
                LabeledContent(
                    L("onboarding.permissions.microphone.title"),
                    value: Permissions.microphoneGranted ? L("dashboard.services.enabled") : L("dashboard.services.disabled")
                )
                Button(L("settings.dictionary.diagnose.action")) {
                    Permissions.requestAccessibility()
                }
            }
            Section(L("settings.debug.secureInput.title")) {
                Text(L("settings.debug.secureInput.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent(
                    L("settings.debug.keyboardDiagnostic.secureInputLabel"),
                    value: (secureInput["enabled"] as? Bool ?? false)
                        ? L("settings.debug.keyboardDiagnostic.enabled")
                        : L("settings.debug.keyboardDiagnostic.disabled")
                )
                if secureInput["sustained"] as? Bool ?? false {
                    if let culprit = secureInput["culprit"] as? [String: Any] {
                        LabeledContent(
                            L("settings.debug.keyboardDiagnostic.holder", [
                                "name": culprit["name"] as? String ?? "?",
                                "pid": culprit["pid"] as? NSNumber ?? 0,
                            ]),
                            value: ""
                        )
                    } else {
                        LabeledContent(
                            L("settings.debug.keyboardDiagnostic.holderUnknown"),
                            value: ""
                        )
                    }
                }
                if !coveredBindings.isEmpty {
                    Text(L("settings.debug.secureInput.covered", [
                        "bindings": coveredBindings.joined(separator: ", "),
                    ]))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                if !uncoveredBindings.isEmpty {
                    Text(L("settings.debug.secureInput.uncovered", [
                        "bindings": uncoveredBindings.joined(separator: ", "),
                    ]))
                    .font(.callout)
                    .foregroundStyle(.orange)
                }
                Button(L("dashboard.refresh")) { refreshSecureInput() }
            }
            Section(L("settings.debug.keyboardDiagnostic.title")) {
                Text(L("settings.debug.keyboardDiagnostic.description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button(keyboard.running
                        ? L("settings.debug.keyboardDiagnostic.running")
                        : L("settings.debug.keyboardDiagnostic.run")) {
                        keyboard.running ? keyboard.stop() : keyboard.run()
                    }
                    .disabled(keyboard.running && keyboard.liveCount < 0)
                    if keyboard.running {
                        ProgressView().controlSize(.small)
                        Text("\(keyboard.liveCount)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }

                if let report = keyboard.report {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                        GridRow {
                            Text(L("settings.debug.keyboardDiagnostic.keyDown"))
                            Text("\(report.keyDown)").monospacedDigit()
                        }
                        GridRow {
                            Text(L("settings.debug.keyboardDiagnostic.keyUp"))
                            Text("\(report.keyUp)").monospacedDigit()
                        }
                        GridRow {
                            Text(L("settings.debug.keyboardDiagnostic.flagsChanged"))
                            Text("\(report.flagsChanged)").monospacedDigit()
                        }
                        GridRow {
                            Text(L("settings.debug.keyboardDiagnostic.mouse"))
                            Text("\(report.mouse)").monospacedDigit()
                        }
                        GridRow {
                            Text(L("settings.debug.keyboardDiagnostic.secureInputLabel"))
                            Text(report.secureInputEnabled
                                ? L("settings.debug.keyboardDiagnostic.enabled")
                                : L("settings.debug.keyboardDiagnostic.disabled"))
                        }
                    }
                    .font(.callout)
                }

                if let verdict = keyboard.verdict() {
                    Text(verdict).font(.callout).foregroundStyle(.secondary)
                }
                if let error = keyboard.error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
            Section(L("settings.debug.learningAttempts.title")) {
                if learningAttempts.isEmpty {
                    Text(L("settings.debug.learningAttempts.empty"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(learningAttempts) { attempt in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(attempt.pasted) → \(attempt.finalText)")
                                .font(.callout)
                                .lineLimit(2)
                                .textSelection(.enabled)
                            HStack(spacing: 6) {
                                Text(attempt.outcome)
                                    .font(.caption2)
                                    .foregroundStyle(attempt.outcome == "learned" ? Color.green : Color.secondary)
                                Text(attempt.source)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(Self.attemptTime(attempt.createdAt))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(attempt.reason)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button(L("settings.debug.learningAttempts.clear")) {
                        do {
                            try Core.clearLearningAttempts()
                            learningAttempts = []
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - about

    private var aboutPane: some View {
        Form {
            Section(L("settings.about.title")) {
                LabeledContent(L("settings.about.version.title"), value: Core.version)
                LabeledContent("talkwtf-core", value: "Rust · FFI · 无 Tauri")
                LabeledContent(L("settings.about.appDataDirectory.title"), value: AppPaths.dataDirectory.path)
                Button(L("common.open")) { NSWorkspace.shared.open(AppPaths.dataDirectory) }
                Button(L("settings.debug.logDirectory.title")) {
                    NSWorkspace.shared.open(AppPaths.logDirectory)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - helpers

    private func load() {
        store.load()
        do {
            accelerators = try Core.invoke("get_available_accelerators") as? [String: Any] ?? [:]
            recognition = try Core.invoke("get_recognition_languages") as? [String: Any] ?? [:]
            secureInput = try Core.invoke("get_secure_input_status") as? [String: Any] ?? [:]
            inputDevices = try Core.invoke("list_input_devices") as? [[String: Any]] ?? []
            outputDevices = try Core.invoke("list_output_devices") as? [[String: Any]] ?? []
            learningAttempts = (try? Core.learningAttempts()) ?? []
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static let attemptDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let attemptDateFormatterNoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// A short local time for a stored RFC 3339 timestamp, falling back to the
    /// raw value when it cannot be parsed.
    private static func attemptTime(_ value: String) -> String {
        let date = attemptDateFormatter.date(from: value)
            ?? attemptDateFormatterNoFraction.date(from: value)
        guard let date else { return value }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private var acceleratorOptions: [String] {
        let available = accelerators["available"] as? [String] ?? []
        return available.isEmpty ? ["cpu", "metal"] : available
    }

    /// A labelled slider with the value shown on the right, matching the
    /// alignment of the surrounding rows.
    private func sliderField(
        _ key: String,
        _ titleKey: String,
        description descriptionKey: String,
        range: ClosedRange<Double>,
        step: Double,
        format: @escaping (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.Spacing.row) {
                Text(L(titleKey))
                Slider(
                    value: Binding(
                        get: { store.double(key, range.lowerBound) },
                        set: { store.patch([key: $0]) }
                    ),
                    in: range,
                    step: step
                )
                Text(format(store.double(key, range.lowerBound)))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
            Text(L(descriptionKey))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// A labelled millisecond number field, with its description underneath.
    private func delayField(
        _ key: String,
        _ titleKey: String,
        description descriptionKey: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(L(titleKey))
                TextField("", value: store.intBinding(key, default: 0), format: .number)
                    .frame(width: 80)
                Text("ms").foregroundStyle(.secondary)
            }
            Text(L(descriptionKey))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The transcription-language picker entries, filtered to what the loaded
    /// model can actually handle (plus "Auto" only when it can detect).
    private var recognitionOptions: [(value: String, label: String)] {
        let languages = recognition["languages"] as? [[String: Any]] ?? []
        let supported = recognition["supported"] as? [String] ?? []
        let supportsDetection = recognition["supports_detection"] as? Bool ?? true
        let supportsSelection = recognition["supports_selection"] as? Bool ?? true

        guard supportsSelection else {
            return [(store.string("selected_language", "auto"), L("settings.general.language.auto"))]
        }

        return languages.compactMap { entry in
            guard let value = entry["value"] as? String else { return nil }
            let label = entry["label"] as? String ?? value
            if value == "auto" {
                return supportsDetection ? (value, L("settings.general.language.auto")) : nil
            }
            // No capability list means "any language"; otherwise gate on it.
            if supported.isEmpty { return (value, label) }
            let wanted = value.split(separator: "-").first.map(String.init) ?? value
            let ok = supported.contains { code in
                (code.split(separator: "-").first.map(String.init) ?? code) == wanted
            }
            return ok ? (value, label) : nil
        }
    }

    private var coveredBindings: [String] {
        (secureInput["shadows"] as? [[String: Any]] ?? [])
            .compactMap { $0["binding_id"] as? String }
    }

    private var uncoveredBindings: [String] {
        secureInput["uncovered"] as? [String] ?? []
    }

    private func refreshSecureInput() {
        secureInput = (try? Core.invoke("get_secure_input_status") as? [String: Any]) ?? [:]
    }

    /// One editable shortcut: click to capture, or reset to the shipped default.
    private func shortcutRow(_ id: String) -> some View {
        let isRecording = recorder.recording == id
        return HStack(spacing: Theme.Spacing.row) {
            Text(L("settings.general.shortcut.bindings.\(id).name"))
            Spacer()
            Button {
                isRecording ? recorder.cancel() : recorder.begin(id)
            } label: {
                Text(isRecording ? recorder.preview : bindingText(id))
                    .font(.callout)
                    .monospaced()
                    .foregroundStyle(isRecording ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 8)
                    .frame(minWidth: 120, minHeight: 22)
                    .background(
                        isRecording ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control)
                    )
            }
            .buttonStyle(.plain)
            .help(L("settings.general.shortcut.pressKeys"))

            Button {
                do {
                    try Core.invoke("reset_binding", ["id": id])
                    store.load()
                } catch {
                    self.error = error.localizedDescription
                }
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(L("settings.postProcessing.prompts.restoreDefault"))
            .accessibilityLabel(L("settings.postProcessing.prompts.restoreDefault"))
            .disabled(isRecording)
        }
    }

    private func previewButton(_ state: OverlayState, _ titleKey: String) -> some View {
        Button(L(titleKey)) { OverlayController.shared.show(state) }
    }

    private func bindingText(_ id: String) -> String {
        let bindings = store.settings["bindings"] as? [String: Any] ?? [:]
        let binding = bindings[id] as? [String: Any] ?? [:]
        let value = binding["current_binding"] as? String ?? ""
        return value.isEmpty ? L("settings.general.shortcut.none") : value
    }
}

/// App directories, resolved the same way the core does.
enum AppPaths {
    static var dataDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("com.pais.handy")
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    static var recordingsDirectory: URL {
        dataDirectory.appendingPathComponent("recordings")
    }

    static var logDirectory: URL {
        FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs/com.pais.handy")
            ?? dataDirectory
    }
}

/// Applies the appearance setting (native window chrome + document attribute).
enum ThemeController {
    static func apply(_ theme: String) {
        switch theme {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}
