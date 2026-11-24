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
            VStack(alignment: .leading, spacing: 30) {
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
            .frame(maxWidth: 760, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 30) {
            SettingsGroup(title: L("settings.general.title")) {
                SettingsRow(title: L("appLanguage.title")) {
                    picker("app_language", default: "en", options: Languages.all.map { ($0.nativeName, $0.code) })
                }
                .onChange(of: store.string("app_language")) { _, language in
                    Localization.shared.load(language: language)
                }

                SettingsRow(
                    title: L("settings.general.language.title"),
                    detail: L("settings.general.language.description")
                ) {
                    picker("selected_language", default: "auto", options: recognitionOptions.map { ($0.label, $0.value) })
                }

                SettingsRow(title: L("theme.title")) {
                    picker("theme", default: "system", options: [
                        (L("theme.options.system"), "system"),
                        (L("theme.options.light"), "light"),
                        (L("theme.options.dark"), "dark"),
                    ])
                }
                .onChange(of: store.string("theme", "system")) { _, theme in
                    ThemeController.apply(theme)
                }
            }

            SettingsGroup(title: L("settings.general.shortcutsGroup")) {
                SettingsRow(title: L("settings.general.shortcutActivation.title")) {
                    picker("shortcut_activation", default: "hold_or_toggle", options: [
                        (L("settings.general.shortcutActivation.options.holdOrToggle"), "hold_or_toggle"),
                        (L("settings.general.shortcutActivation.options.pushToTalk"), "push_to_talk"),
                        (L("settings.general.shortcutActivation.options.toggle"), "toggle"),
                    ])
                }

                if store.string("shortcut_activation", "hold_or_toggle") == "hold_or_toggle" {
                    sliderRow(
                        "hold_threshold_ms",
                        "settings.debug.holdThreshold.title",
                        detail: "settings.debug.holdThreshold.description",
                        range: 100...1000,
                        step: 50,
                        format: { "\(Int($0)) ms" }
                    )
                }

                ForEach(["transcribe", "transcribe_with_post_process", "translate", "cancel"], id: \.self) { id in
                    shortcutRow(id)
                }
            }

            SettingsGroup(title: L("settings.general.behaviorGroup")) {
                toggleRow("settings.advanced.startHidden.label", key: "start_hidden")

                toggleRow("settings.advanced.autostart.label", key: "autostart_enabled")
                    .onChange(of: store.bool("autostart_enabled")) { _, enabled in
                        Autostart.apply(enabled)
                    }

                SettingsRow(title: L("settings.advanced.overlay.style.title")) {
                    picker("overlay_style", default: "minimal", options: [
                        (L("settings.advanced.overlay.style.options.none"), "none"),
                        (L("settings.advanced.overlay.style.options.minimal"), "minimal"),
                        (L("settings.advanced.overlay.style.options.live"), "live"),
                    ])
                }

                SettingsRow(title: L("settings.advanced.overlay.position.title")) {
                    picker("overlay_position", default: "bottom", options: [
                        (L("settings.advanced.overlay.position.options.top"), "top"),
                        (L("settings.advanced.overlay.position.options.bottom"), "bottom"),
                    ])
                }
            }
        }
    }

    // MARK: - audio

    private var audioPane: some View {
        VStack(alignment: .leading, spacing: 30) {
            SettingsGroup(title: "") {
                SettingsRow(title: L("settings.sound.microphone.title")) {
                    picker("selected_microphone", default: "", options: microphoneOptions)
                }

                SettingsRow(title: L("settings.sound.channel.title")) {
                    Picker("", selection: store.intBinding("selected_channel", default: 0)) {
                        Text(L("settings.sound.channel.average")).tag(0)
                        Text(L("settings.sound.channel.channel", ["n": 1])).tag(1)
                        Text(L("settings.sound.channel.channel", ["n": 2])).tag(2)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }

                toggleRow("settings.debug.alwaysOnMicrophone.label", key: "always_on_microphone")
                toggleRow("settings.debug.muteWhileRecording.label", key: "mute_while_recording")
            }

            SettingsGroup(title: "") {
                SettingsRow(title: L("settings.sound.outputDevice.title")) {
                    picker("selected_output_device", default: "", options: outputOptions)
                }

                toggleRow("settings.sound.audioFeedback.label", key: "audio_feedback")

                SettingsRow(title: L("settings.debug.soundTheme.label")) {
                    picker("sound_theme", default: "marimba", options: [
                        ("Marimba", "marimba"),
                        ("Pop", "pop"),
                        (L("modelSelector.custom"), "custom"),
                    ])
                }
                .onChange(of: store.string("sound_theme", "marimba")) { _, _ in
                    SoundPlayer.playPreview(.start)
                }

                SettingsStack(title: L("settings.sound.volume.title")) {
                    HStack(spacing: 12) {
                        Slider(
                            value: Binding(
                                get: { store.double("audio_feedback_volume", 1.0) },
                                set: { store.patch(["audio_feedback_volume": $0]) }
                            ),
                            in: 0...1
                        )
                        Text("\(Int(store.double("audio_feedback_volume", 1.0) * 100))%")
                            .font(Theme.Fonts.mono(11))
                            .foregroundStyle(Theme.Colors.inkTertiary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - advanced

    private var advancedPane: some View {
        VStack(alignment: .leading, spacing: 30) {
            SettingsGroup(title: L("settings.advanced.groups.output")) {
                SettingsRow(title: L("settings.advanced.pasteMethod.title")) {
                    picker("paste_method", default: "ctrl_v", options: [
                        (L("settings.advanced.pasteMethod.options.clipboard", ["modifier": "\u{2318}"]), "ctrl_v"),
                        (L("settings.advanced.pasteMethod.options.clipboardShiftInsert", ["modifier": "\u{21e7}"]), "shift_insert"),
                        (L("settings.advanced.pasteMethod.options.clipboardCtrlShiftV", ["modifier": "\u{2318}\u{21e7}"]), "ctrl_shift_v"),
                        (L("settings.advanced.pasteMethod.options.direct"), "direct"),
                        (L("settings.advanced.pasteMethod.options.none"), "none"),
                    ])
                }

                numberRow("paste_delay_ms", "settings.debug.pasteDelay.title", detail: "settings.debug.pasteDelay.description")
                numberRow("paste_delay_after_ms", "settings.debug.pasteDelayAfter.title", detail: "settings.debug.pasteDelayAfter.description")

                toggleRow("settings.debug.reliablePaste.title", key: "reliable_paste")

                SettingsRow(title: L("settings.advanced.clipboardHandling.title")) {
                    picker("clipboard_handling", default: "dont_modify", options: [
                        (L("settings.advanced.clipboardHandling.options.dontModify"), "dont_modify"),
                        (L("settings.advanced.clipboardHandling.options.copyToClipboard"), "copy_to_clipboard"),
                    ])
                }

                SettingsRow(title: L("settings.advanced.autoSubmit.title")) {
                    picker("auto_submit_key", default: "off", options: [
                        (L("settings.advanced.autoSubmit.options.off"), "off"),
                        (L("settings.advanced.autoSubmit.options.enter"), "enter"),
                        (L("settings.advanced.autoSubmit.options.ctrlEnter"), "ctrl_enter"),
                        (L("settings.advanced.autoSubmit.options.cmdEnter"), "cmd_enter"),
                    ])
                }

                toggleRow("settings.debug.appendTrailingSpace.label", key: "append_trailing_space")
            }

            SettingsGroup(title: L("settings.advanced.groups.transcription")) {
                toggleRow("settings.advanced.voiceActivityDetection.title", key: "vad_enabled")

                SettingsRow(title: L("settings.advanced.vadBackend.title")) {
                    picker("vad_backend", default: "silero", options: [
                        (L("settings.advanced.vadBackend.options.silero"), "silero"),
                        (L("settings.advanced.vadBackend.options.earshot"), "earshot"),
                    ])
                }

                toggleRow("settings.advanced.fillerWordRemoval.title", key: "filler_word_removal_enabled")
                toggleRow("settings.dictionary.learn.title", key: "learn_from_edits")
                toggleRow("settings.advanced.translateToEnglish.label", key: "translate_to_english")

                sliderRow(
                    "word_correction_threshold",
                    "settings.debug.wordCorrectionThreshold.title",
                    detail: "settings.debug.wordCorrectionThreshold.description",
                    range: 0.01...1.0,
                    step: 0.01,
                    format: { "\(Int(($0 * 100).rounded()))%" }
                )

                SettingsRow(title: L("settings.advanced.modelUnload.title")) {
                    picker("model_unload_timeout", default: "min5", options: [
                        (L("settings.advanced.modelUnload.options.immediately"), "immediately"),
                        (L("settings.advanced.modelUnload.options.sec15"), "sec15"),
                        (L("settings.advanced.modelUnload.options.min2"), "min2"),
                        (L("settings.advanced.modelUnload.options.min5"), "min5"),
                        (L("settings.advanced.modelUnload.options.min10"), "min10"),
                        (L("settings.advanced.modelUnload.options.min15"), "min15"),
                        (L("settings.advanced.modelUnload.options.hour1"), "hour1"),
                        (L("settings.advanced.modelUnload.options.never"), "never"),
                    ])
                }
            }

            SettingsGroup(title: L("settings.advanced.groups.history")) {
                SettingsRow(title: L("settings.debug.historyLimit.title")) {
                    HStack(spacing: 10) {
                        Text("\(store.int("history_limit", 5)) \(L("settings.debug.historyLimit.entries"))")
                            .font(Theme.Fonts.mono(11))
                            .foregroundStyle(Theme.Colors.inkTertiary)
                        Stepper(
                            "",
                            value: store.intBinding("history_limit", default: 5),
                            in: 0...1000
                        )
                        .labelsHidden()
                    }
                }

                SettingsRow(title: L("settings.debug.recordingRetention.title")) {
                    picker("recording_retention_period", default: "preserve_limit", options: [
                        (L("settings.debug.recordingRetention.preserveLimit"), "preserve_limit"),
                        (L("settings.debug.recordingRetention.never"), "never"),
                        (L("settings.debug.recordingRetention.days3"), "days3"),
                        (L("settings.debug.recordingRetention.month1"), "month1"),
                        (L("settings.debug.recordingRetention.weeks2"), "weeks2"),
                        (L("settings.debug.recordingRetention.months3"), "months3"),
                    ])
                }
            }

            SettingsGroup(title: L("settings.advanced.groups.experimental")) {
                toggleRow(
                    "settings.advanced.experimentalToggle.label",
                    key: "experimental_enabled",
                    detail: "settings.advanced.experimentalToggle.description"
                )
                toggleRow("settings.advanced.lazyStreamClose.label", key: "lazy_stream_close")
            }

            SettingsGroup(title: L("settings.advanced.groups.app")) {
                SettingsRow(
                    title: L("settings.advanced.acceleration.transcribe.title"),
                    detail: L("settings.advanced.acceleration.transcribe.description")
                ) {
                    picker("transcription_accelerator", default: "auto", options:
                        [(L("settings.advanced.acceleration.gpuDevice.auto"), "auto")]
                        + acceleratorOptions.map { ($0, $0) }
                    )
                }
            }
        }
    }

    // MARK: - debug

    private var debugPane: some View {
        VStack(alignment: .leading, spacing: 30) {
            SettingsGroup(title: "") {
                SettingsRow(title: L("settings.debug.logLevel.title")) {
                    picker("log_level", default: "debug", options: [
                        ("Trace", "trace"),
                        ("Debug", "debug"),
                        ("Info", "info"),
                        ("Warn", "warn"),
                        ("Error", "error"),
                    ])
                }

                toggleRow("settings.dictionary.diagnose.title", key: "debug_mode")

                SettingsRow(title: L("settings.debug.logDirectory.title")) {
                    StudioButton(title: L("common.open"), kind: .ghost, height: 28) {
                        NSWorkspace.shared.open(AppPaths.logDirectory)
                    }
                    .fixedSize()
                }
            }

            SettingsGroup(title: L("settings.advanced.groups.app")) {
                numberRow(
                    "extra_recording_buffer_ms",
                    "settings.debug.recordingBuffer.title",
                    detail: "settings.debug.recordingBuffer.description"
                )

                toggleRow("settings.debug.updateChecks.label", key: "update_checks_enabled")

                SettingsRow(title: L("settings.debug.keyboardImplementation.title")) {
                    picker("keyboard_implementation", default: "handy_keys", options: [
                        ("handy-keys", "handy_keys"),
                        ("Tauri", "tauri"),
                    ])
                }
            }

            SettingsGroup(title: "") {
                SettingsStack(
                    title: L("settings.debug.overlayPreview.title"),
                    detail: L("settings.debug.overlayPreview.description")
                ) {
                    FlowRow(spacing: 8) {
                        previewButton(.recording, "settings.debug.overlayPreview.recording")
                        previewButton(.streaming, "settings.debug.overlayPreview.streaming")
                        previewButton(.transcribing, "settings.debug.overlayPreview.transcribing")
                        previewButton(.processing(label: nil), "settings.debug.overlayPreview.processing")
                        previewButton(.translating(label: "English (English)"), "settings.debug.overlayPreview.translating")
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
            }

            SettingsGroup(title: "") {
                valueRow(
                    L("onboarding.permissions.accessibility.title"),
                    value: Permissions.accessibilityGranted ? L("dashboard.services.enabled") : L("dashboard.services.disabled"),
                    ok: Permissions.accessibilityGranted
                )
                valueRow(
                    L("onboarding.permissions.microphone.title"),
                    value: Permissions.microphoneGranted ? L("dashboard.services.enabled") : L("dashboard.services.disabled"),
                    ok: Permissions.microphoneGranted
                )
                SettingsRow(title: L("settings.dictionary.diagnose.action")) {
                    StudioButton(title: L("settings.dictionary.diagnose.action"), kind: .ghost, height: 28) {
                        Permissions.requestAccessibility()
                    }
                    .fixedSize()
                }
            }

            SettingsGroup(title: "") {
                SettingsStack(title: L("settings.debug.secureInput.title"), detail: L("settings.debug.secureInput.hint")) {
                    VStack(alignment: .leading, spacing: 6) {
                        valueRow(
                            L("settings.debug.keyboardDiagnostic.secureInputLabel"),
                            value: (secureInput["enabled"] as? Bool ?? false)
                                ? L("settings.debug.keyboardDiagnostic.enabled")
                                : L("settings.debug.keyboardDiagnostic.disabled"),
                            ok: !(secureInput["enabled"] as? Bool ?? false)
                        )
                        if secureInput["sustained"] as? Bool ?? false {
                            if let culprit = secureInput["culprit"] as? [String: Any] {
                                valueRow(
                                    L("settings.debug.keyboardDiagnostic.holder", [
                                        "name": culprit["name"] as? String ?? "?",
                                        "pid": culprit["pid"] as? NSNumber ?? 0,
                                    ]),
                                    value: ""
                                )
                            } else {
                                valueRow(L("settings.debug.keyboardDiagnostic.holderUnknown"), value: "")
                            }
                        }
                        if !coveredBindings.isEmpty {
                            Text(L("settings.debug.secureInput.covered", [
                                "bindings": coveredBindings.joined(separator: ", "),
                            ]))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.Colors.inkTertiary)
                        }
                        if !uncoveredBindings.isEmpty {
                            Text(L("settings.debug.secureInput.uncovered", [
                                "bindings": uncoveredBindings.joined(separator: ", "),
                            ]))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.Colors.warn)
                        }
                        StudioButton(title: L("dashboard.refresh"), kind: .ghost, height: 28) {
                            refreshSecureInput()
                        }
                        .fixedSize()
                    }
                }
            }

            SettingsGroup(title: "") {
                SettingsStack(
                    title: L("settings.debug.keyboardDiagnostic.title"),
                    detail: L("settings.debug.keyboardDiagnostic.description")
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            StudioButton(
                                title: keyboard.running
                                    ? L("settings.debug.keyboardDiagnostic.running")
                                    : L("settings.debug.keyboardDiagnostic.run"),
                                kind: keyboard.running ? .ghost : .accent,
                                height: 28
                            ) {
                                keyboard.running ? keyboard.stop() : keyboard.run()
                            }
                            .fixedSize()
                            .disabled(keyboard.running && keyboard.liveCount < 0)
                            if keyboard.running {
                                ProgressView().controlSize(.mini)
                                Text("\(keyboard.liveCount)")
                                    .font(Theme.Fonts.mono(11))
                                    .foregroundStyle(Theme.Colors.inkTertiary)
                            }
                        }

                        if let report = keyboard.report {
                            VStack(alignment: .leading, spacing: 0) {
                                diagnosticRow(L("settings.debug.keyboardDiagnostic.keyDown"), "\(report.keyDown)")
                                diagnosticRow(L("settings.debug.keyboardDiagnostic.keyUp"), "\(report.keyUp)")
                                diagnosticRow(L("settings.debug.keyboardDiagnostic.flagsChanged"), "\(report.flagsChanged)")
                                diagnosticRow(L("settings.debug.keyboardDiagnostic.mouse"), "\(report.mouse)")
                                diagnosticRow(
                                    L("settings.debug.keyboardDiagnostic.secureInputLabel"),
                                    report.secureInputEnabled
                                        ? L("settings.debug.keyboardDiagnostic.enabled")
                                        : L("settings.debug.keyboardDiagnostic.disabled")
                                )
                            }
                        }

                        if let verdict = keyboard.verdict() {
                            Text(verdict)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.Colors.inkTertiary)
                        }
                        if let error = keyboard.error {
                            Text(error)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.Colors.err)
                        }
                    }
                }
            }

            SettingsGroup(title: L("settings.debug.learningAttempts.title")) {
                if learningAttempts.isEmpty {
                    SettingsRow(title: L("settings.debug.learningAttempts.empty")) {
                        EmptyView()
                    }
                } else {
                    ForEach(learningAttempts) { attempt in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(attempt.pasted) → \(attempt.finalText)")
                                .font(.system(size: 12.5))
                                .lineLimit(2)
                                .textSelection(.enabled)
                            HStack(spacing: 8) {
                                Text(attempt.outcome)
                                    .font(Theme.Fonts.mono(10))
                                    .foregroundStyle(attempt.outcome == "learned" ? Theme.Colors.ok : Theme.Colors.inkTertiary)
                                Text(attempt.source)
                                    .font(Theme.Fonts.mono(10))
                                    .foregroundStyle(Theme.Colors.inkTertiary)
                                Text(Self.attemptTime(attempt.createdAt))
                                    .font(Theme.Fonts.mono(10))
                                    .foregroundStyle(Theme.Colors.inkTertiary)
                            }
                            Text(attempt.reason)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.Colors.inkSecondary)
                            if let strategy = attempt.strategy {
                                Text(strategy)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.Colors.inkTertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                        .overlay(alignment: .bottom) { Hairline() }
                    }

                    SettingsRow(title: L("settings.debug.learningAttempts.clear")) {
                        StudioButton(title: L("settings.debug.learningAttempts.clear"), kind: .ghost, height: 28) {
                            do {
                                try Core.clearLearningAttempts()
                                learningAttempts = []
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                        .fixedSize()
                    }
                }
            }
        }
    }

    // MARK: - about

    private var aboutPane: some View {
        VStack(alignment: .leading, spacing: 30) {
            SettingsGroup(title: L("settings.about.title")) {
                valueRow(L("settings.about.version.title"), value: Core.version)
                valueRow("talkwtf-core", value: "Rust · FFI · 无 Tauri")
                SettingsRow(title: L("settings.about.appDataDirectory.title")) {
                    HStack(spacing: 10) {
                        Text(abbreviatedPath(AppPaths.dataDirectory.path))
                            .font(Theme.Fonts.mono(10.5))
                            .foregroundStyle(Theme.Colors.inkTertiary)
                        StudioButton(title: L("common.open"), kind: .ghost, height: 28) {
                            NSWorkspace.shared.open(AppPaths.dataDirectory)
                        }
                        .fixedSize()
                    }
                }
                SettingsRow(title: L("settings.debug.logDirectory.title")) {
                    HStack(spacing: 10) {
                        Text(abbreviatedPath(AppPaths.logDirectory.path))
                            .font(Theme.Fonts.mono(10.5))
                            .foregroundStyle(Theme.Colors.inkTertiary)
                        StudioButton(title: L("common.open"), kind: .ghost, height: 28) {
                            NSWorkspace.shared.open(AppPaths.logDirectory)
                        }
                        .fixedSize()
                    }
                }
            }
        }
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

    // MARK: - row helpers

    /// A menu picker sized to its longest option, so rows keep a single line.
    private func picker(_ key: String, default fallback: String, options: [(String, String)]) -> some View {
        Picker("", selection: store.binding(key, default: fallback)) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Text(option.0).tag(option.1)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .tint(Theme.Colors.ink)
    }

    private func toggleRow(_ titleKey: String, key: String, detail detailKey: String? = nil) -> some View {
        SettingsRow(
            title: L(titleKey),
            detail: detailKey.map { L($0) }
        ) {
            Toggle("", isOn: store.boolBinding(key))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }

    private func sliderRow(
        _ key: String,
        _ titleKey: String,
        detail detailKey: String? = nil,
        range: ClosedRange<Double>,
        step: Double,
        format: @escaping (Double) -> String
    ) -> some View {
        SettingsStack(title: L(titleKey), detail: detailKey.map { L($0) }) {
            HStack(spacing: 12) {
                Slider(
                    value: Binding(
                        get: { store.double(key, range.lowerBound) },
                        set: { store.patch([key: $0]) }
                    ),
                    in: range,
                    step: step
                )
                Text(format(store.double(key, range.lowerBound)))
                    .font(Theme.Fonts.mono(11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.inkTertiary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }

    private func numberRow(_ key: String, _ titleKey: String, detail detailKey: String? = nil) -> some View {
        SettingsRow(title: L(titleKey), detail: detailKey.map { L($0) }) {
            HStack(spacing: 6) {
                TextField("", value: store.intBinding(key, default: 0), format: .number)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(Theme.Fonts.mono(11.5))
                    .frame(width: 64)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.Colors.well)
                    .overlay(Rectangle().strokeBorder(Theme.Colors.hairline, lineWidth: 1))
                Text("ms")
                    .font(Theme.Fonts.mono(10.5))
                    .foregroundStyle(Theme.Colors.inkTertiary)
            }
        }
    }

    /// A read-only label/value row; `ok` tints the value green when true.
    private func valueRow(_ title: String, value: String, ok: Bool? = nil) -> some View {
        SettingsRow(title: title) {
            Text(value)
                .font(Theme.Fonts.mono(11))
                .foregroundStyle(ok == true ? Theme.Colors.ok : Theme.Colors.inkTertiary)
                .textSelection(.enabled)
                .lineLimit(1)
        }
    }

    private func diagnosticRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Colors.inkSecondary)
            Spacer(minLength: 12)
            Text(value)
                .font(Theme.Fonts.mono(11))
                .foregroundStyle(Theme.Colors.inkTertiary)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private var microphoneOptions: [(String, String)] {
        [(L("settings.sound.microphone.placeholder"), "")]
            + inputDevices.compactMap { $0["name"] as? String }.map { ($0, $0) }
    }

    private var outputOptions: [(String, String)] {
        [(L("settings.sound.outputDevice.placeholder"), "")]
            + outputDevices.compactMap { $0["name"] as? String }.map { ($0, $0) }
    }

    /// `~/Library/...` instead of the full home path, to keep rows short.
    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
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
        return SettingsRow(title: L("settings.general.shortcut.bindings.\(id).name")) {
            HStack(spacing: 8) {
                Button {
                    isRecording ? recorder.cancel() : recorder.begin(id)
                } label: {
                    ShortcutLabel(
                        combo: isRecording ? recorder.preview : bindingText(id),
                        tint: isRecording ? Theme.Colors.accent : Theme.Colors.inkSecondary
                    )
                    .frame(minWidth: 96, minHeight: 24, alignment: .leading)
                    .padding(.horizontal, 9)
                        .background(isRecording ? Theme.Colors.accentSoft : Theme.Colors.well)
                        .overlay(
                            Rectangle().strokeBorder(
                                isRecording ? Theme.Colors.accent : Theme.Colors.hairline,
                                lineWidth: 1
                            )
                        )
                }
                .buttonStyle(.plain)
                .help(L("settings.general.shortcut.pressKeys"))

                StudioIconButton(systemImage: "arrow.counterclockwise") {
                    do {
                        try Core.invoke("reset_binding", ["id": id])
                        store.load()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .disabled(isRecording)
            }
        }
    }

    private func previewButton(_ state: OverlayState, _ titleKey: String) -> some View {
        StudioButton(title: L(titleKey), kind: .ghost, height: 28) {
            OverlayController.shared.show(state)
        }
        .fixedSize()
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
            .appendingPathComponent("com.talkwtf.app")
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    static var recordingsDirectory: URL {
        dataDirectory.appendingPathComponent("recordings")
    }

    static var logDirectory: URL {
        FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs/com.talkwtf.app")
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
