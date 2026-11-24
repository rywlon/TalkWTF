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
        Form {
            if let error {
                Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled)
            }
            Section(header: Text(L("settings.models.title")).font(Theme.Fonts.sectionHeader)) {
                ForEach(models.indices, id: \.self) { index in
                    modelRow(models[index])
                }
                Button(L("settings.models.rescan.label")) {
                    _ = try? Core.invoke("rescan_local_models")
                    load()
                }
            }
            Section(header: Text(L("settings.advanced.groups.app")).font(Theme.Fonts.sectionHeader)) {
                Picker(L("settings.advanced.acceleration.transcribe.title"), selection: transcribeSelection) {
                    ForEach(transcribeOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .pickerStyle(.menu)
                Text(L("settings.advanced.acceleration.transcribe.description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(L("settings.advanced.acceleration.ort.title"), selection: store.binding("ort_accelerator", default: "auto")) {
                    ForEach(ortOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .pickerStyle(.menu)
                Text(L("settings.advanced.acceleration.ort.description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

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

                Button(L("tray.unloadModel")) {
                    try? Core.invoke("unload_model")
                }
            }
        }
        .formStyle(.grouped)
        .task { load() }
    }

    private func modelRow(_ model: [String: Any]) -> some View {
        let id = model["id"] as? String ?? ""
        let name = model["name"] as? String ?? id
        let sizeMB = (model["size_mb"] as? NSNumber)?.doubleValue ?? 0
        let isDownloaded = downloaded.contains(id) || (model["is_downloaded"] as? Bool ?? false)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: current == id ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(.tint)
                .onTapGesture {
                    do {
                        try Core.invoke("set_active_model", ["modelId": id])
                        store.load()
                        load()
                    } catch {
                        if !BusyAlert.shared.handle(error) {
                            self.error = error.localizedDescription
                        }
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.headline)
                Text(Self.sizeLabel(sizeMB)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let value = progress[id] {
                ProgressView(value: value).frame(width: 120)
                Button(L("modelSelector.cancel")) {
                    _ = try? Core.invoke("cancel_download", ["modelId": id])
                    progress[id] = nil
                }
                .buttonStyle(.link)
            } else if isDownloaded {
                Button(L("common.delete")) {
                    try? Core.invoke("delete_model", ["modelId": id])
                    load()
                }
                .buttonStyle(.link)
            } else {
                Button(L("settings.models.availableModels")) { download(id) }
                    .buttonStyle(.link)
            }
        }
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
