import SwiftUI

/// Personalization: polish provider (BYOK), styles, scenes and translation.
struct PersonalizationView: View {
    @ObservedObject private var store = SettingsStore.shared

    @State private var styles: [[String: Any]] = []
    @State private var providers: [[String: Any]] = []
    @State private var scenes: [[String: Any]] = []
    @State private var languages: [[String: Any]] = []
    @State private var apiKey = ""
    @FocusState private var apiKeyFocused: Bool
    @State private var editing: SceneDraft?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.err)
                    .textSelection(.enabled)
            }
            polishSection
            styleSection
            sceneSection
            translationSection
        }
        .task { load() }
        .onChange(of: apiKeyFocused) { _, focused in
            // Persist on blur, like the provider fields did in the Tauri app.
            if !focused { store.patch(["post_process_api_keys": [currentProviderId: apiKey]]) }
        }
        .sheet(item: $editing) { draft in
            SceneEditor(draft: draft) { saved in
                save(draft: saved)
            }
        }
    }

    // MARK: - polish

    private var polishSection: some View {
        SettingsGroup(title: L("sidebar.postProcessing")) {
            SettingsRow(title: L("settings.postProcessing.api.provider.title")) {
                Picker("", selection: store.binding("post_process_provider_id", default: "")) {
                    Text(L("settings.postProcessing.scene.none")).tag("")
                    ForEach(providers.indices, id: \.self) { index in
                        if let id = providers[index]["id"] as? String,
                           let label = providers[index]["label"] as? String {
                            Text(label).tag(id)
                        }
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .tint(Theme.Colors.ink)
            }
            .onChange(of: store.string("post_process_provider_id")) { _, _ in
                apiKey = currentApiKey()
            }

            if !currentProviderId.isEmpty {
                SettingsRow(title: L("settings.postProcessing.api.baseUrl.title")) {
                    SettingsField(
                        text: Binding(
                            get: { currentProvider()["base_url"] as? String ?? "" },
                            set: { setProviderBaseURL($0) }
                        )
                    )
                    .frame(width: 248)
                    .disabled(!(currentProvider()["allow_base_url_edit"] as? Bool ?? false))
                }

                SettingsRow(title: L("settings.postProcessing.api.apiKey.title")) {
                    SettingsField(text: $apiKey, secure: true)
                        .focused($apiKeyFocused)
                        .frame(width: 248)
                }

                SettingsRow(title: L("settings.postProcessing.api.model.title")) {
                    SettingsField(
                        text: Binding(
                            get: { currentModels()[currentProviderId] as? String ?? "" },
                            set: { model in
                                var models = currentModels()
                                models[currentProviderId] = model
                                store.patch(["post_process_models": models])
                            }
                        )
                    )
                    .frame(width: 248)
                }

                SettingsRow(title: L("settings.postProcessing.thinking.title")) {
                    Toggle("", isOn: store.boolBinding("post_process_thinking"))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - styles

    private var styleSection: some View {
        SettingsGroup(title: "") {
            SettingsRow(
                title: L("settings.postProcessing.style.title"),
                detail: activeStyleDescription
            ) {
                Picker(
                    "",
                    selection: Binding(
                        get: { store.string("polish_style", "default") },
                        set: { style in
                            try? Core.invoke("change_polish_style", ["style": style])
                            store.load()
                        }
                    )
                ) {
                    ForEach(styles.indices, id: \.self) { index in
                        if let value = styles[index]["value"] as? String {
                            Text(styles[index]["label"] as? String ?? value).tag(value)
                        }
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .tint(Theme.Colors.ink)
            }
        }
    }

    // MARK: - scenes

    private var sceneSection: some View {
        SettingsGroup(title: L("settings.postProcessing.scene.title")) {
            ForEach(scenes.indices, id: \.self) { index in
                let scene = scenes[index]
                if let id = scene["id"] as? String {
                    let active = store.string("active_scene_id") == id
                    HStack(spacing: 12) {
                        Button {
                            try? Core.invoke("set_active_scene", ["id": id])
                            store.load()
                        } label: {
                            Image(systemName: active ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 13))
                                .foregroundStyle(active ? Theme.Colors.accent : Theme.Colors.inkTertiary)
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(scene["name"] as? String ?? id)
                                .font(.system(size: 13.5))
                                .foregroundStyle(Theme.Colors.ink)
                            if let description = scene["description"] as? String,
                               !description.isEmpty {
                                Text(description)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.Colors.inkTertiary)
                                    .lineLimit(2)
                            }
                        }

                        Spacer(minLength: 12)

                        plainAction(L("settings.postProcessing.scene.edit"), tint: Theme.Colors.inkSecondary) {
                            editing = SceneDraft(scene)
                        }
                        plainAction(L("common.delete"), tint: Theme.Colors.inkTertiary) {
                            try? Core.invoke("delete_scene", ["id": id])
                            load()
                        }
                    }
                    .padding(.vertical, 10)
                    .frame(minHeight: 44)
                    .overlay(alignment: .bottom) { Hairline() }
                }
            }

            SettingsRow(title: L("settings.postProcessing.prompts.createNew")) {
                HStack(spacing: 14) {
                    StudioButton(title: L("settings.postProcessing.prompts.createNew"), kind: .ghost, height: 28) {
                        editing = SceneDraft(id: nil, name: "", description: "", prompt: "")
                    }
                    StudioButton(title: L("settings.postProcessing.scene.restoreBuiltIn"), kind: .quiet, height: 28) {
                        _ = try? Core.invoke("restore_built_in_scenes")
                        load()
                    }
                    if store.string("active_scene_id") != "" {
                        StudioButton(title: L("settings.postProcessing.scene.none"), kind: .quiet, height: 28) {
                            try? Core.invoke("set_active_scene", ["id": NSNull()])
                            store.load()
                        }
                    }
                }
                .fixedSize()
            }
        }
    }

    // MARK: - translation

    private var translationSection: some View {
        SettingsGroup(title: L("settings.translation.title")) {
            ForEach(store.stringArray("translation_targets"), id: \.self) { code in
                let active = store.string("translation_active_target") == code
                HStack(spacing: 12) {
                    Button {
                        try? Core.invoke("set_active_translation_target", ["code": code])
                        store.load()
                    } label: {
                        Image(systemName: active ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 13))
                            .foregroundStyle(active ? Theme.Colors.accent : Theme.Colors.inkTertiary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Text(languageLabel(code))
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.Colors.ink)

                    Spacer(minLength: 12)

                    plainAction(L("settings.translation.targets.remove"), tint: Theme.Colors.inkTertiary) {
                        _ = try? Core.invoke("remove_translation_target", ["code": code])
                        store.load()
                    }
                }
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .overlay(alignment: .bottom) { Hairline() }
            }

            SettingsRow(title: L("settings.translation.targets.addPlaceholder")) {
                Menu(L("settings.translation.targets.addPlaceholder")) {
                    ForEach(availableLanguages, id: \.self) { code in
                        Button(languageLabel(code)) {
                            _ = try? Core.invoke("add_translation_target", ["code": code])
                            store.load()
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .tint(Theme.Colors.ink)
            }
        }
    }

    private func plainAction(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    // MARK: - data

    private func load() {
        store.load()
        styles = (try? Core.invoke("get_polish_styles") as? [[String: Any]]) ?? []
        providers = (try? Core.invoke("get_default_settings") as? [String: Any])
            .flatMap { $0["post_process_providers"] as? [[String: Any]] } ?? []
        scenes = store.array("scenes") as? [[String: Any]] ?? []
        languages = (try? Core.invoke("get_translation_languages") as? [[String: Any]]) ?? []
        apiKey = currentApiKey()
    }

    private func save(draft: SceneDraft) {
        let payload: [String: Any] = [
            "name": draft.name,
            "description": draft.description,
            "prompt": draft.prompt,
        ]
        do {
            if let id = draft.id {
                try Core.invoke("update_scene", payload.merging(["id": id]) { $1 })
            } else {
                try Core.invoke("add_scene", payload)
            }
            load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var currentProviderId: String {
        store.string("post_process_provider_id")
    }

    private func currentProvider() -> [String: Any] {
        providers.first { $0["id"] as? String == currentProviderId } ?? [:]
    }

    private func currentModels() -> [String: Any] {
        store.settings["post_process_models"] as? [String: Any] ?? [:]
    }

    private func currentApiKey() -> String {
        let keys = store.settings["post_process_api_keys"] as? [String: String] ?? [:]
        return keys[currentProviderId] ?? ""
    }

    private func setProviderBaseURL(_ url: String) {
        var updated = providers
        for index in updated.indices where updated[index]["id"] as? String == currentProviderId {
            updated[index]["base_url"] = url
        }
        store.patch(["post_process_providers": updated])
    }

    private var activeStyleDescription: String? {
        styles.first { $0["value"] as? String == store.string("polish_style") }?["description"] as? String
    }

    private var availableLanguages: [String] {
        let chosen = Set(store.stringArray("translation_targets"))
        return languages.compactMap { $0["value"] as? String }.filter { !chosen.contains($0) }
    }

    private func languageLabel(_ code: String) -> String {
        languages.first { $0["value"] as? String == code }?["label"] as? String ?? code
    }
}

/// Editable scene draft for the sheet.
struct SceneDraft: Identifiable {
    let id: String?
    var name: String
    var description: String
    var prompt: String

    init(_ dict: [String: Any]) {
        id = dict["id"] as? String
        name = dict["name"] as? String ?? ""
        description = dict["description"] as? String ?? ""
        prompt = dict["prompt"] as? String ?? ""
    }

    init(id: String?, name: String, description: String, prompt: String) {
        self.id = id
        self.name = name
        self.description = description
        self.prompt = prompt
    }
}

struct SceneEditor: View {
    @State var draft: SceneDraft
    let onSave: (SceneDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.id == nil ? L("settings.postProcessing.prompts.createPrompt") : L("settings.postProcessing.scene.edit")).font(.title3.bold())
            TextField(L("settings.postProcessing.prompts.promptLabel"), text: $draft.name)
            TextField(L("settings.postProcessing.scene.description"), text: $draft.description)
            TextEditor(text: $draft.prompt)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            HStack {
                Spacer()
                Button(L("settings.postProcessing.prompts.cancel")) { dismiss() }
                Button(L("settings.postProcessing.prompts.updatePrompt")) { onSave(draft); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
