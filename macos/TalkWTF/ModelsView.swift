import SwiftUI

/// Model management: pick the active ASR model, download or delete, tune the
/// accelerator and the unload timeout.
struct ModelsView: View {
    let accelerators: [String: Any]
    @ObservedObject private var store = SettingsStore.shared

    @State private var models: [[String: Any]] = []
    @State private var current = ""
    @State private var downloaded: Set<String> = []
    @State private var progress: [String: Double] = [:]
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.err)
                    .textSelection(.enabled)
            }

            SettingsGroup(title: L("settings.models.title"), trailing: "\(models.count)") {
                ForEach(models.indices, id: \.self) { index in
                    modelRow(models[index])
                }

                SettingsRow(title: L("settings.models.rescan.label")) {
                    StudioButton(title: L("settings.models.rescan.label"), kind: .ghost, height: 28) {
                        _ = try? Core.invoke("rescan_local_models")
                        load()
                    }
                    .fixedSize()
                }
            }

            SettingsGroup(title: L("settings.advanced.groups.app")) {
                SettingsRow(
                    title: L("settings.advanced.acceleration.transcribe.title"),
                    detail: L("settings.advanced.acceleration.transcribe.description")
                ) {
                    Picker("", selection: transcribeSelection) {
                        ForEach(transcribeOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .tint(Theme.Colors.ink)
                }

                SettingsRow(
                    title: L("settings.advanced.acceleration.ort.title"),
                    detail: L("settings.advanced.acceleration.ort.description")
                ) {
                    Picker("", selection: store.binding("ort_accelerator", default: "auto")) {
                        ForEach(ortOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .tint(Theme.Colors.ink)
                }

                SettingsRow(title: L("settings.advanced.modelUnload.title")) {
                    Picker("", selection: store.binding("model_unload_timeout", default: "min5")) {
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
                    .labelsHidden()
                    .fixedSize()
                    .tint(Theme.Colors.ink)
                }

                SettingsRow(title: L("tray.unloadModel")) {
                    StudioButton(title: L("tray.unloadModel"), kind: .ghost, height: 28) {
                        try? Core.invoke("unload_model")
                    }
                    .fixedSize()
                }
            }
        }
        .task { load() }
    }

    private func modelRow(_ model: [String: Any]) -> some View {
        let id = model["id"] as? String ?? ""
        let name = model["name"] as? String ?? id
        let sizeMB = (model["size_mb"] as? NSNumber)?.doubleValue ?? 0
        let isDownloaded = downloaded.contains(id) || (model["is_downloaded"] as? Bool ?? false)
        let isCurrent = current == id

        return HStack(spacing: 12) {
            Button {
                do {
                    try Core.invoke("set_active_model", ["modelId": id])
                    store.load()
                    load()
                } catch {
                    if !BusyAlert.shared.handle(error) {
                        self.error = error.localizedDescription
                    }
                }
            } label: {
                Image(systemName: isCurrent ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isCurrent ? Theme.Colors.accent : Theme.Colors.inkTertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.Colors.ink)
                Text(Self.sizeLabel(sizeMB))
                    .font(Theme.Fonts.mono(10.5))
                    .foregroundStyle(Theme.Colors.inkTertiary)
            }

            Spacer(minLength: 12)

            if let value = progress[id] {
                ProgressView(value: value)
                    .progressViewStyle(.linear)
                    .frame(width: 110)
                actionButton(L("modelSelector.cancel"), tint: Theme.Colors.inkSecondary) {
                    _ = try? Core.invoke("cancel_download", ["modelId": id])
                    progress[id] = nil
                }
            } else if isDownloaded {
                actionButton(L("common.delete"), tint: Theme.Colors.inkSecondary) {
                    try? Core.invoke("delete_model", ["modelId": id])
                    load()
                }
            } else {
                actionButton(L("settings.models.availableModels"), tint: Theme.Colors.accent) {
                    download(id)
                }
            }
        }
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func actionButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
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

    private func download(_ id: String) {
        progress[id] = 0
        DispatchQueue.global(qos: .utility).async {
            defer { DispatchQueue.main.async { progress[id] = nil } }
            do {
                try Core.invoke("download_model", ["modelId": id])
                DispatchQueue.main.async { load() }
            } catch {
                DispatchQueue.main.async { self.error = error.localizedDescription }
            }
        }
    }

    private func load() {
        store.load()
        models = (try? Core.invoke("get_available_models") as? [[String: Any]]) ?? []
        // `get_current_model` is null until a model is loaded; the persisted
        // selection is what the user considers "current".
        current = (try? Core.invoke("get_current_model") as? String)
            ?? store.string("selected_model")
        downloaded = Set(models.compactMap { model in
            (model["is_downloaded"] as? Bool ?? false) ? model["id"] as? String : nil
        })
    }

    /// One entry in an accelerator picker.
    struct AcceleratorOption: Hashable {
        let value: String
        let label: String
    }

    /// transcribe.cpp exposes one combined choice: Auto, a specific GPU device,
    /// or CPU. It is stored as `transcribe_accelerator` plus
    /// `transcribe_gpu_device`, the same encoding the Tauri app used.
    private var transcribeOptions: [AcceleratorOption] {
        var options: [AcceleratorOption] = []
        let available = accelerators["transcribe"] as? [String] ?? []

        if available.contains("auto") {
            options.append(AcceleratorOption(
                value: "auto",
                label: L("settings.advanced.acceleration.gpuDevice.auto")
            ))
        }
        if available.contains("gpu") {
            for device in gpuDevices {
                guard let id = device["id"] as? String else { continue }
                let name = device["name"] as? String ?? id
                let vram = (device["total_vram_mb"] as? NSNumber)?.intValue ?? 0
                let vramLabel = vram >= 1024
                    ? String(format: "%.1f GB", Double(vram) / 1024)
                    : "\(vram) MB"
                options.append(
                    AcceleratorOption(value: "gpu:\(id)", label: "\(name) (\(vramLabel))")
                )
            }
        }
        if available.contains("cpu") {
            options.append(AcceleratorOption(value: "cpu", label: "CPU"))
        }
        return options.isEmpty
            ? [AcceleratorOption(
                value: "auto",
                label: L("settings.advanced.acceleration.gpuDevice.auto")
            )]
            : options
    }

    private var transcribeSelection: Binding<String> {
        Binding(
            get: {
                let accelerator = store.string("transcribe_accelerator", "auto")
                if accelerator == "gpu",
                   let device = store.settings["transcribe_gpu_device"] as? String {
                    return "gpu:\(device)"
                }
                return accelerator
            },
            set: { value in
                if value.hasPrefix("gpu:") {
                    store.patch([
                        "transcribe_accelerator": "gpu",
                        "transcribe_gpu_device": String(value.dropFirst(4)),
                    ])
                } else {
                    store.patch([
                        "transcribe_accelerator": value,
                        "transcribe_gpu_device": NSNull(),
                    ])
                }
            }
        )
    }

    private var ortOptions: [AcceleratorOption] {
        let available = accelerators["ort"] as? [String] ?? []
        let values = available.contains("auto") ? available : ["auto"] + available
        return values.map { value in
            AcceleratorOption(
                value: value,
                label: value == "auto"
                    ? L("settings.advanced.acceleration.gpuDevice.auto")
                    : value.uppercased()
            )
        }
    }

    private var gpuDevices: [[String: Any]] {
        accelerators["gpu_devices"] as? [[String: Any]] ?? []
    }

    static func sizeLabel(_ megabytes: Double) -> String {
        guard megabytes > 0 else { return "" }
        return megabytes >= 1024
            ? String(format: "%.1f GB", megabytes / 1024)
            : String(format: "%.0f MB", megabytes)
    }
}
