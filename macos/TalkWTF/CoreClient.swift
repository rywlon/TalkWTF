import Foundation

/// Errors surfaced from the Rust core.
enum CoreError: LocalizedError {
    case command(String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .command(let message): return message
        case .decode(let raw): return "Could not decode core response: \(raw.prefix(200))"
        }
    }
}

/// Thin typed wrapper over the Rust core's C ABI.
enum Core {
    /// The core version, e.g. "0.9.6".
    static var version: String {
        guard let pointer = talkwtf_version() else { return "unknown" }
        defer { talkwtf_free_string(pointer) }
        return String(cString: pointer)
    }

    /// Call a core command. Throws `CoreError.command` when the core reports one.
    @discardableResult
    static func invoke(_ command: String, _ payload: [String: Any] = [:]) throws -> Any {
        let payloadJSON: String
        if payload.isEmpty {
            payloadJSON = "{}"
        } else {
            let data = try JSONSerialization.data(withJSONObject: payload)
            payloadJSON = String(data: data, encoding: .utf8) ?? "{}"
        }

        guard let pointer = talkwtf_invoke(command, payloadJSON) else {
            throw CoreError.command("no response from core")
        }
        defer { talkwtf_free_string(pointer) }

        let raw = String(cString: pointer)
        guard
            let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CoreError.decode(raw)
        }
        if let error = object["error"] as? String {
            throw CoreError.command(error)
        }
        return object["ok"] ?? NSNull()
    }

    /// Boot the engine: data dir, bundle resources, locale.
    static func initialize() throws {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("com.talkwtf.app")
        let payload: [String: Any] = [
            "dataDir": appSupport?.path ?? NSHomeDirectory(),
            "resourceDir": Bundle.main.resourceURL?.path ?? "",
            "locale": Locale.current.identifier,
        ]
        try invoke("init", payload)
    }

    /// A decoded dashboard snapshot. All of it is computed locally.
    struct Dashboard {
        struct Today {
            let recordings: Int
            let translations: Int
            let dictationMs: Int
            let chars: Int
        }

        struct Daily: Identifiable {
            let day: String
            let count: Int
            var id: String { day }
        }

        struct Recent: Identifiable {
            let id: Int
            let timestamp: Int
            let workflow: String
            let charCount: Int
            let preview: String
        }

        struct Tokens {
            let promptTokens: Int
            let completionTokens: Int
            let totalTokens: Int
            let requests: Int
        }

        struct Services {
            let asrModel: String
            let asrReady: Bool
            let llmModel: String
            let llmProvider: String
            let pasteEnabled: Bool
            let polishReady: Bool
        }

        struct PersonalizationItem: Identifiable {
            let id: String
            let done: Bool
        }

        let totalRecordings: Int
        let totalChars: Int
        let totalDictationMs: Int
        let avgCharsPerMin: Double
        let timeSavedMs: Int
        let translationCount: Int

        let today: Today
        let weekly: [Daily]
        let recent: [Recent]
        let tokensToday: Tokens
        let tokensWeek: Tokens
        let services: Services
        let personalizationScore: Int
        let personalizationItems: [PersonalizationItem]

        init(_ value: Any) throws {
            guard let dict = value as? [String: Any] else {
                throw CoreError.decode("dashboard is not an object")
            }
            func int(_ key: String) -> Int { (dict[key] as? NSNumber)?.intValue ?? 0 }

            totalRecordings = int("total_recordings")
            totalChars = int("total_chars")
            totalDictationMs = int("total_dictation_ms")
            avgCharsPerMin = (dict["avg_chars_per_min"] as? NSNumber)?.doubleValue ?? 0
            timeSavedMs = int("time_saved_ms")
            translationCount = int("translation_count")

            let todayDict = dict["today"] as? [String: Any] ?? [:]
            today = Today(
                recordings: (todayDict["recordings"] as? NSNumber)?.intValue ?? 0,
                translations: (todayDict["translations"] as? NSNumber)?.intValue ?? 0,
                dictationMs: (todayDict["dictation_ms"] as? NSNumber)?.intValue ?? 0,
                chars: (todayDict["chars"] as? NSNumber)?.intValue ?? 0
            )

            weekly = (dict["weekly"] as? [[String: Any]] ?? []).map { point in
                Daily(
                    day: point["day"] as? String ?? "",
                    count: (point["count"] as? NSNumber)?.intValue ?? 0
                )
            }

            recent = (dict["recent"] as? [[String: Any]] ?? []).map { entry in
                Recent(
                    id: (entry["id"] as? NSNumber)?.intValue ?? 0,
                    timestamp: (entry["timestamp"] as? NSNumber)?.intValue ?? 0,
                    workflow: entry["workflow"] as? String ?? "dictation",
                    charCount: (entry["char_count"] as? NSNumber)?.intValue ?? 0,
                    preview: entry["preview"] as? String ?? ""
                )
            }

            func tokens(_ key: String) -> Tokens {
                let usage = dict[key] as? [String: Any] ?? [:]
                return Tokens(
                    promptTokens: (usage["prompt_tokens"] as? NSNumber)?.intValue ?? 0,
                    completionTokens: (usage["completion_tokens"] as? NSNumber)?.intValue ?? 0,
                    totalTokens: (usage["total_tokens"] as? NSNumber)?.intValue ?? 0,
                    requests: (usage["requests"] as? NSNumber)?.intValue ?? 0
                )
            }
            tokensToday = tokens("tokens_today")
            tokensWeek = tokens("tokens_week")

            let serviceDict = dict["services"] as? [String: Any] ?? [:]
            services = Services(
                asrModel: serviceDict["asr_model"] as? String ?? "—",
                asrReady: serviceDict["asr_ready"] as? Bool ?? false,
                llmModel: serviceDict["llm_model"] as? String ?? "",
                llmProvider: serviceDict["llm_provider"] as? String ?? "",
                pasteEnabled: serviceDict["paste_enabled"] as? Bool ?? false,
                polishReady: serviceDict["polish_ready"] as? Bool ?? false
            )

            let personalization = dict["personalization"] as? [String: Any] ?? [:]
            personalizationScore = (personalization["score"] as? NSNumber)?.intValue ?? 0
            personalizationItems = (personalization["items"] as? [[String: Any]] ?? []).map { item in
                PersonalizationItem(
                    id: item["id"] as? String ?? "",
                    done: item["done"] as? Bool ?? false
                )
            }
        }
    }

    /// A history row.
    struct HistoryEntry: Identifiable {
        let id: Int
        let fileName: String
        let timestamp: Int
        let workflow: String
        let charCount: Int
        let durationMs: Int
        let saved: Bool
        let transcription: String
        let postProcessed: String?

        init(_ dict: [String: Any]) {
            id = (dict["id"] as? NSNumber)?.intValue ?? 0
            fileName = dict["file_name"] as? String ?? ""
            timestamp = (dict["timestamp"] as? NSNumber)?.intValue ?? 0
            workflow = dict["workflow"] as? String ?? "dictation"
            charCount = (dict["char_count"] as? NSNumber)?.intValue ?? 0
            durationMs = (dict["duration_ms"] as? NSNumber)?.intValue ?? 0
            saved = dict["saved"] as? Bool ?? false
            transcription = dict["transcription_text"] as? String ?? ""
            postProcessed = dict["post_processed_text"] as? String
        }

        /// What the user actually got (polished when available).
        var display: String {
            let polished = postProcessed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return polished.isEmpty ? transcription : polished
        }

        /// The raw transcript, shown only when polishing changed it.
        var rawIfDifferent: String? {
            let raw = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, raw != display.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return nil
            }
            return raw
        }
    }

    static func historyEntries(limit: Int = 50) throws -> [HistoryEntry] {
        let value = try invoke("get_history_entries", ["limit": limit])
        let dict = value as? [String: Any] ?? [:]
        let entries = dict["entries"] as? [[String: Any]] ?? []
        return entries.map(HistoryEntry.init)
    }

    /// Dictionary words and correction rules.
    struct DictionaryWord: Identifiable {
        let id: Int
        let word: String

        init(_ dict: [String: Any]) {
            id = (dict["id"] as? NSNumber)?.intValue ?? 0
            word = dict["word"] as? String ?? ""
        }
    }

    struct CorrectionRule: Identifiable {
        let id: Int
        let pattern: String
        let replacement: String
        let enabled: Bool

        init(_ dict: [String: Any]) {
            id = (dict["id"] as? NSNumber)?.intValue ?? 0
            pattern = dict["pattern"] as? String ?? ""
            replacement = dict["replacement"] as? String ?? ""
            enabled = dict["enabled"] as? Bool ?? true
        }
    }

    struct Dictionary {
        let words: [DictionaryWord]
        let rules: [CorrectionRule]

        init(_ value: Any) throws {
            let dict = value as? [String: Any] ?? [:]
            words = (dict["words"] as? [[String: Any]] ?? []).map(DictionaryWord.init)
            rules = (dict["rules"] as? [[String: Any]] ?? []).map(CorrectionRule.init)
        }
    }

    static func dictionary() throws -> Dictionary {
        try Dictionary(invoke("get_dictionary"))
    }

    /// One recorded learning attempt, for the debug pane.
    struct LearningAttempt: Identifiable {
        let id: Int
        let createdAt: String
        let bundleId: String?
        let fieldId: String?
        let pasted: String
        let finalText: String
        let source: String
        let llmRaw: String?
        let outcome: String
        let reason: String
        let strategy: String?

        init(_ dict: [String: Any]) {
            id = (dict["id"] as? NSNumber)?.intValue ?? 0
            createdAt = dict["created_at"] as? String ?? ""
            bundleId = dict["bundle_id"] as? String
            fieldId = dict["field_id"] as? String
            pasted = dict["pasted"] as? String ?? ""
            finalText = dict["final_text"] as? String ?? ""
            source = dict["source"] as? String ?? ""
            llmRaw = dict["llm_raw"] as? String
            outcome = dict["outcome"] as? String ?? ""
            reason = dict["reason"] as? String ?? ""
            strategy = dict["strategy"] as? String
        }
    }

    static func learningAttempts(limit: Int = 50) throws -> [LearningAttempt] {
        let value = try invoke("list_learning_attempts", ["limit": limit])
        let rows = value as? [[String: Any]] ?? []
        return rows.map(LearningAttempt.init)
    }

    static func clearLearningAttempts() throws {
        try invoke("clear_learning_attempts")
    }

    static func appSettings() throws -> [String: Any] {
        try invoke("get_app_settings") as? [String: Any] ?? [:]
    }

    /// Merge a partial settings patch.
    static func updateSettings(_ patch: [String: Any]) throws {
        try invoke("update_settings", patch)
    }
}
