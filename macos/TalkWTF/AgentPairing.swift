import Foundation

enum AgentChoice: String, Codable, CaseIterable, Identifiable {
    case codex = "Codex"
    case claude = "Claude Code"
    case opencode = "OpenCode"
    case cursor = "Cursor"
    case other = "其他本地 Agent"
    var id: String { rawValue }
}

struct PairingRequest: Codable {
    var id: String
    var token: String
    var provider: AgentChoice
    var expiresAt: TimeInterval
    var executable: String
    var targetID: String
}

struct PairingResponse: Codable {
    var requestID: String
    var token: String
    var provider: AgentChoice
    var target: AgentTarget
}

struct AgentPairing {
    let directory: URL
    var requestURL: URL { directory.appendingPathComponent("request.json") }
    var responseURL: URL { directory.appendingPathComponent("response.json") }
    var instructionsURL: URL { directory.appendingPathComponent("CONNECT.md") }
    let request: PairingRequest

    static func create(root: URL, provider: AgentChoice, executable: String,
                       targetID: String = UUID().uuidString, now: TimeInterval = Date().timeIntervalSince1970) throws -> AgentPairing {
        let request = PairingRequest(id: UUID().uuidString, token: UUID().uuidString + UUID().uuidString,
                                     provider: provider, expiresAt: now + 600, executable: executable, targetID: targetID)
        let directory = root.appendingPathComponent(request.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let pairing = AgentPairing(directory: directory, request: request)
        try writePrivate(JSONEncoder().encode(request), to: pairing.requestURL)
        try writePrivate(Data(pairing.instructions.utf8), to: pairing.instructionsURL)
        return pairing
    }

    func readResponse(now: TimeInterval = Date().timeIntervalSince1970) throws -> AgentTarget? {
        guard now < request.expiresAt else { throw AgentDeliveryError.invalid("连接提示词已过期，请重新生成。") }
        guard FileManager.default.fileExists(atPath: requestURL.path) else { throw AgentDeliveryError.invalid("连接已取消。") }
        guard FileManager.default.fileExists(atPath: responseURL.path) else { return nil }
        let response = try JSONDecoder().decode(PairingResponse.self, from: Data(contentsOf: responseURL))
        guard response.requestID == request.id, response.token == request.token,
              response.provider == request.provider, response.target.id == request.targetID else {
            throw AgentDeliveryError.invalid("连接信息不匹配，请重新生成提示词。")
        }
        try Self.validate(response.target, for: request.provider)
        return response.target
    }

    func cancel() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    static func register(requestURL: URL, target: AgentTarget, now: TimeInterval = Date().timeIntervalSince1970) throws {
        let request = try JSONDecoder().decode(PairingRequest.self, from: Data(contentsOf: requestURL))
        guard now < request.expiresAt else { throw AgentDeliveryError.invalid("连接请求已过期。请在 TalkWTF 重新生成。") }
        try validate(target, for: request.provider)
        let destination = requestURL.deletingLastPathComponent().appendingPathComponent("response.json")
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw AgentDeliveryError.invalid("连接回执已提交，请回到 TalkWTF 查看。")
        }
        var target = target
        target.id = request.targetID
        target.provider = request.provider.rawValue
        let response = PairingResponse(requestID: request.id, token: request.token, provider: request.provider, target: target)
        try writePrivate(JSONEncoder().encode(response), to: destination)
    }

    private static func validate(_ target: AgentTarget, for provider: AgentChoice) throws {
        try AgentTransport.validate(target)
        guard !target.conversation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentDeliveryError.invalid("必须提供当前会话标识，不能创建一个替代的新会话。")
        }
        if target.kind == .codex {
            guard provider == .codex, UUID(uuidString: target.conversation) != nil else {
                throw AgentDeliveryError.invalid("Codex 连接必须使用当前会话的有效编号。")
            }
        }
        if target.kind == .http {
            let host = URL(string: target.address)?.host ?? ""
            guard ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) else {
                throw AgentDeliveryError.invalid("自动连接只接受本机接收入口。")
            }
        }
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    var prompt: String {
        "请按本机说明「\(instructionsURL.path)」将当前 \(request.provider.rawValue) 会话连接到 TalkWTF。"
    }

    private var instructions: String {
        let command = Self.quote(request.executable) + " connect-agent --request " + Self.quote(requestURL.path)
        return """
        # Connect this existing \(request.provider.rawValue) conversation to TalkWTF

        The user copied this request from their local TalkWTF app. It expires in 10 minutes.
        Read this whole document. Connect only the CURRENT conversation. Do not create or guess a different conversation, do not choose the newest session, do not disable approvals or permissions, do not modify unrelated settings. Ask the user before any host permission change.

        ## Codex
        Discover this conversation's exact UUID from your provided session context or CODEX_THREAD_ID, and its working directory. Do not guess. If unavailable, report that connection needs a supported session identifier.
        Run the bundled registration command:
        \(command) --kind codex --name 'Codex' --conversation <CURRENT_UUID> --directory <CURRENT_WORKING_DIRECTORY>
        TalkWTF discovers the existing Codex installation; it uses exec resume with this exact conversation when sending voice messages. This registers a session continuation, not a guarantee that every desktop client refreshes live. Only register when this route fits the current host. If continuing a currently running turn could race, report the limitation instead of claiming a live inbox.

        ## Other local agents / alternative adapters
        Identify a supported way to receive new user messages in this exact conversation. You may configure a small local adapter using the host's documented extension/hook/session API. Use existing local tools, no downloads, no credentials in connection data, no remote services. Do not fake a connection by just writing a receipt.
        Verify that adapter addresses the current conversation, then register one of:
        \(command) --kind http --name <DISPLAY_NAME> --conversation <CURRENT_SESSION> --address <LOOPBACK_HTTP_MESSAGE_ENDPOINT>
        \(command) --kind command --name <DISPLAY_NAME> --conversation <CURRENT_SESSION> --address <ABSOLUTE_ADAPTER_EXECUTABLE> --arguments <JSON_STRING_ARRAY>

        HTTP receives POST JSON {"text":"voice transcript","conversation":"session id","source":"TalkWTF"}; return 2xx only after accepting that message. The local command receives literal transcript on stdin and TALKWTF_CONVERSATION in its environment; return 0 after accepting, within 30 seconds. Queue when busy using the host's supported mechanism; don't synthesize foreground keystrokes or paste into an arbitrary window.

        The bundled command writes a one-time local receipt. Its success means the receipt was submitted. Ask the user to return to TalkWTF to see completion and set a shortcut. If your host cannot support this, explain clearly what is unavailable; do not submit an unusable connection. Do not send an actual task as a probe without user instruction.
        """
    }

    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    /// Same executable, CLI-only path: handled before SwiftUI boot.
    static func handleCommandLine(_ arguments: [String]) -> Int32? {
        guard arguments.dropFirst().first == "connect-agent" else { return nil }
        do {
            var options: [String: String] = [:]
            let input = Array(arguments.dropFirst(2))
            guard input.count.isMultiple(of: 2) else { throw AgentDeliveryError.invalid("Connection arguments must be flag/value pairs.") }
            for index in stride(from: 0, to: input.count, by: 2) { options[input[index]] = input[index + 1] }
            guard let path = options["--request"], let kindString = options["--kind"],
                  let kind = AgentTarget.Kind(rawValue: kindString),
                  let conversation = options["--conversation"] else {
                throw AgentDeliveryError.invalid("Required: --request, --kind, --conversation.")
            }
            let address = kind == .codex ? CodexConnection.executable() : options["--address"]
            guard let address else { throw AgentDeliveryError.invalid("Cannot find the Agent executable or receiving address.") }
            let extra = try JSONDecoder().decode([String].self, from: Data((options["--arguments"] ?? "[]").utf8))
            let target = AgentTarget(name: options["--name"] ?? "Agent", kind: kind, address: address,
                                     arguments: extra, conversation: conversation, workingDirectory: options["--directory"])
            try register(requestURL: URL(fileURLWithPath: path), target: target)
            print("Connection receipt submitted. Return to TalkWTF to finish and choose a shortcut.")
            return 0
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            return 1
        }
    }
}
