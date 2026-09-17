import SwiftUI

/// P0/P2 spike: prove the SwiftUI → Rust core bridge against real engine data.
struct ContentView: View {
    @State private var version = "…"
    @State private var response = "—"
    @State private var lastEvent = "—"
    @State private var engine: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("TalkWTF").font(.largeTitle.bold())
                Text("Rust core connected: \(version)")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Divider()

            GroupBox("engine (via FFI)") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(engine.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        HStack(alignment: .firstTextBaseline) {
                            Text(key).foregroundStyle(.secondary).frame(width: 170, alignment: .leading)
                            Text(value).textSelection(.enabled)
                        }
                        .font(.system(.body, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("invoke") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(response)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    HStack {
                        Button("get_app_settings") { invoke("get_app_settings", "{}") }
                        Button("get_dashboard_stats") { invoke("get_dashboard_stats", "{}") }
                        Button("get_dictionary") { invoke("get_dictionary", "{}") }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("event channel") {
                Text(lastEvent)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            MigrationProgressView()

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 620)
        .onAppear(perform: boot)
        .onReceive(NotificationCenter.default.publisher(for: .talkWtfCoreEvent)) { notification in
            lastEvent = notification.object as? String ?? "—"
        }
    }

    /// Data dir / bundle resources / locale the core needs before it can boot.
    private func initPayload() -> String {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("com.pais.handy")
        let payload: [String: String] = [
            "dataDir": appSupport?.path ?? NSHomeDirectory(),
            "resourceDir": Bundle.main.resourceURL?.path ?? "",
            "locale": Locale.current.identifier,
        ]
        let data = try? JSONSerialization.data(withJSONObject: payload)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Boot the core engine, then read a few real values through the FFI.
    private func boot() {
        version = coreVersion()

        let initResult = call("init", initPayload())
        guard initResult.ok else {
            engine["init"] = "failed: \(initResult.raw)"
            return
        }

        let settings = call("get_app_settings", "{}")
        engine["theme"] = settings.string("theme")
        engine["polish_style"] = settings.string("polish_style")
        engine["learn_from_edits"] = settings.string("learn_from_edits")
        engine["translation_targets"] = settings.string("translation_targets")

        let dashboard = call("get_dashboard_stats", "{}")
        engine["total_recordings"] = dashboard.string("total_recordings")
        engine["total_chars"] = dashboard.string("total_chars")
        engine["asr_model"] = dashboard.string("services.asr_model")
        engine["personalization"] = dashboard.string("personalization.score")

        let dictionary = call("get_dictionary", "{}")
        engine["dictionary_words"] = dictionary.count("words")

        let history = call("get_history_entries", "{}")
        engine["history_entries"] = history.count("entries")
    }

    private struct CallResult {
        let raw: String
        let value: Any?
        var ok: Bool { value != nil }

        /// Read `ok.<dotted.path>` as a display string.
        func string(_ path: String) -> String {
            var current: Any? = value
            for component in path.split(separator: ".") {
                current = (current as? [String: Any])?[String(component)]
            }
            return Self.display(current)
        }

        /// Count of `ok.<path>` when it is an array.
        func count(_ path: String) -> String {
            guard let dict = value as? [String: Any], let array = dict[path] as? [Any] else {
                return "—"
            }
            return String(array.count)
        }

        private static func display(_ value: Any?) -> String {
            guard let value else { return "—" }
            if let string = value as? String { return string }
            if let bool = value as? Bool { return bool ? "true" : "false" }
            if let number = value as? NSNumber { return number.stringValue }
            if let array = value as? [Any] { return "[\(array.count)]" }
            if let dict = value as? [String: Any], let family = dict["family"] {
                return "\(family)"
            }
            return String(describing: value)
        }
    }

    private func call(_ command: String, _ payload: String) -> CallResult {
        guard let pointer = talkwtf_invoke(command, payload) else {
            return CallResult(raw: "no response", value: nil)
        }
        defer { talkwtf_free_string(pointer) }
        let raw = String(cString: pointer)
        guard
            let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return CallResult(raw: raw, value: nil)
        }
        return CallResult(raw: raw, value: object["ok"])
    }

    /// `talkwtf_version()` returns an owned C string we must free.
    private func coreVersion() -> String {
        guard let pointer = talkwtf_version() else { return "unknown" }
        defer { talkwtf_free_string(pointer) }
        return String(cString: pointer)
    }

    private func invoke(_ command: String, _ payload: String) {
        response = call(command, payload).raw
    }
}

#Preview {
    ContentView()
}
