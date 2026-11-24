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
        Form {
            if let error {
                Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled)
            }
            polishSection
            styleSection
            sceneSection
            translationSection
        }
        .formStyle(.grouped)
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
        Section(header: Text(L("sidebar.postProcessing")).font(Theme.Fonts.sectionHeader)) {
            Picker(
                L("settings.postProcessing.api.provider.title"),
                selection: store.binding("post_process_provider_id", default: "")
            ) {
                Text(L("settings.postProcessing.scene.none")).tag("")
                ForEach(providers.indices, id: \.self) { index in
                    if let id = providers[index]["id"] as? String,
                       let label = providers[index]["label"] as? String {
                        Text(label).tag(id)
                    }
                }
            }
            .pickerStyle(.menu)
            .onChange(of: store.string("post_process_provider_id")) { _, _ in
                apiKey = currentApiKey()
            }

            if !currentProviderId.isEmpty {
                LabeledContent(L("settings.postProcessing.api.baseUrl.title")) {
                    TextField(
                        "",
                        text: Binding(
                            get: { currentProvider()["base_url"] as? String ?? "" },
                            set: { setProviderBaseURL($0) }
                        )
                    )
                    .disabled(!(currentProvider()["allow_base_url_edit"] as? Bool ?? false))
                }
                LabeledContent(L("settings.postProcessing.api.apiKey.title")) {
                    SecureField("", text: $apiKey)
                    .focused($apiKeyFocused)
                }
                LabeledContent(L("settings.postProcessing.api.model.title")) {
                    TextField(
                        "",
                        text: Binding(
                            get: { currentModels()[currentProviderId] as? String ?? "" },
                            set: { model in
                                var models = currentModels()
                                models[currentProviderId] = model
                                store.patch(["post_process_models": models])
                            }
                        )
                    )
                }
                Toggle(
                    L("settings.postProcessing.thinking.title"),
                    isOn: store.boolBinding("post_process_thinking")
                )
            }
        }
    }

    // MARK: - styles

    private var styleSection: some View {
        Section(header: Text(L("settings.postProcessing.style.title")).font(Theme.Fonts.sectionHeader)) {
            Picker(
                L("settings.postProcessing.style.title"),
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
            if let description = activeStyleDescription {
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - scenes

    private var sceneSection: some View {
        Section(header: Text(L("settings.postProcessing.scene.title")).font(Theme.Fonts.sectionHeader)) {
            ForEach(scenes.indices, id: \.self) { index in
                let scene = scenes[index]
                if let id = scene["id"] as? String {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: store.string("active_scene_id") == id
                              ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(.tint)
                            .onTapGesture {
                                try? Core.invoke("set_active_scene", ["id": id])
                                store.load()
                            }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(scene["name"] as? String ?? id).font(.headline)
                            if let description = scene["description"] as? String,
                               !description.isEmpty {
                                Text(description).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(L("settings.postProcessing.scene.edit")) {
                            editing = SceneDraft(scene)
                        }
                        .buttonStyle(.link)
                        Button(L("common.delete")) {
                            try? Core.invoke("delete_scene", ["id": id])
                            load()
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            HStack {
                Button(L("settings.postProcessing.prompts.createNew")) {
                    editing = SceneDraft(id: nil, name: "", description: "", prompt: "")
                }
                Button(L("settings.postProcessing.scene.restoreBuiltIn")) {
                    _ = try? Core.invoke("restore_built_in_scenes")
                    load()
                }
                if store.string("active_scene_id") != "" {
                    Button(L("settings.postProcessing.scene.none")) {
                        try? Core.invoke("set_active_scene", ["id": NSNull()])
                        store.load()
                    }
                }
            }
        }
    }

    // MARK: - translation

    private var translationSection: some View {
        Section(header: Text(L("settings.translation.title")).font(Theme.Fonts.sectionHeader)) {
            ForEach(store.stringArray("translation_targets"), id: \.self) { code in
                HStack {
                    Image(systemName: store.string("translation_active_target") == code
                          ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(.tint)
                        .onTapGesture {
                            try? Core.invoke("set_active_translation_target", ["code": code])
                            store.load()
                        }
                    Text(languageLabel(code))
                    Spacer()
                    Button(L("settings.translation.targets.remove")) {
                        _ = try? Core.invoke("remove_translation_target", ["code": code])
                        store.load()
                    }
                    .buttonStyle(.link)
                }
            }
            Menu(L("settings.translation.targets.addPlaceholder")) {
                ForEach(availableLanguages, id: \.self) { code in
                    Button(languageLabel(code)) {
                        _ = try? Core.invoke("add_translation_target", ["code": code])
                        store.load()
                    }
                }
            }
            .frame(width: 220)
        }
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
