import Foundation

struct AgentTarget: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable { case http, command, codex }
    var id = UUID().uuidString
    var name: String
    var kind: Kind = .http
    var address: String = ""
    var arguments: [String] = []
    var conversation: String = ""
    var workingDirectory: String? = nil
    var provider: String? = nil
    /// Extra cue words this agent answers to ("claude", "reviewer", ...).
    var aliases: [String]? = nil
    /// What this agent is responsible for, used by the smart router.
    var scope: String? = nil
    /// Unix seconds of the last successful delivery — drives follow-up routing.
    var lastUsedAt: Double? = nil
    var bindingID: String { "agent_" + id }
}

enum AgentDeliveryError: LocalizedError {
    case invalid(String)
    case agentFailed(String, conversation: String)
    var errorDescription: String? {
        switch self {
        case .invalid(let message), .agentFailed(let message, _): return message
        }
    }
}

/// Delivery does not touch the clipboard, activate apps, or synthesize keys.
enum AgentTransport {
    static func validate(_ target: AgentTarget) throws {
        guard !target.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentDeliveryError.invalid("请给 Agent 起个名字。")
        }
        if target.kind == .http {
            guard let url = URL(string: target.address),
                  let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil,
                  url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)) else {
                throw AgentDeliveryError.invalid("请填写 HTTPS 接收地址；本机接口也可使用 HTTP。")
            }
        } else {
            if target.kind == .codex {
                var isDirectory: ObjCBool = false
                guard let directory = target.workingDirectory,
                      FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw AgentDeliveryError.invalid("工作文件夹找不到了，请重新选择。")
                }
            }
            guard target.address.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: target.address) else {
                throw AgentDeliveryError.invalid("请选择可执行文件的完整路径。")
            }
        }
    }

    static func request(for target: AgentTarget, text: String) throws -> URLRequest {
        try validate(target)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentDeliveryError.invalid("没有识别到内容，请重新录音。")
        }
        guard let url = URL(string: target.address) else { throw AgentDeliveryError.invalid("接收地址无效。") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text, "conversation": target.conversation, "source": "TalkWTF",
        ])
        return request
    }

    /// Must run off the main thread. No retries: a timed-out receiver may have
    /// already accepted the message, so resending could execute it twice.
    @discardableResult
    static func deliver(to target: AgentTarget, text: String) throws -> AgentReceipt {
        try validate(target)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentDeliveryError.invalid("没有识别到内容，请重新录音。")
        }
        if target.kind == .codex { return try CodexConnection.run(target, text: text) }
        if target.kind == .http {
            let request = try request(for: target, text: text)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForResource = 25
            let session = URLSession(configuration: configuration, delegate: NoAgentRedirects(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let result = DeliveryResult()
            let done = DispatchSemaphore(value: 0)
            session.dataTask(with: request) { _, response, error in
                result.error = error
                result.status = (response as? HTTPURLResponse)?.statusCode
                done.signal()
            }.resume()
            guard done.wait(timeout: .now() + 27) == .success else {
                throw AgentDeliveryError.invalid("发送超时，接收状态未知。请先检查 Agent，再决定是否重发。")
            }
            if let error = result.error { throw AgentDeliveryError.invalid("连接失败：" + error.localizedDescription + "。请检查接收状态。") }
            guard let status = result.status, (200..<300).contains(status) else {
                throw AgentDeliveryError.invalid("接收入口返回 HTTP \(result.status ?? 0)。内容已保留。")
            }
        } else {
            // A file handle avoids deadlocking on a full stdin pipe. Text is
            // never interpolated into a shell command.
            let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data(text.utf8).write(to: input, options: [.atomic, .completeFileProtectionUnlessOpen])
            defer { try? FileManager.default.removeItem(at: input) }
            let handle = try FileHandle(forReadingFrom: input)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: target.address)
            process.arguments = target.arguments
            var environment = ProcessInfo.processInfo.environment
            environment["TALKWTF_CONVERSATION"] = target.conversation
            process.environment = environment
            process.standardInput = handle
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let done = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in done.signal() }
            try process.run()
            guard done.wait(timeout: .now() + 30) == .success else {
                process.terminate()
                throw AgentDeliveryError.invalid("命令超过 30 秒，接收状态未知。内容已保留，请先检查 Agent。")
            }
            guard process.terminationStatus == 0 else {
                throw AgentDeliveryError.invalid("接收命令退出码 \(process.terminationStatus)。内容已保留。")
            }
        }
        return AgentReceipt()
    }
}

private final class DeliveryResult: @unchecked Sendable {
    // Written before semaphore.signal; read only after semaphore.wait succeeds.
    var error: Error?
    var status: Int?
}

private final class NoAgentRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct AgentReceipt {
    var conversation: String = ""
    var reply: String = ""
}

enum CodexConnection {
    static func executable(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let fileManager = FileManager.default
        var candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/codex" }
        candidates += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", home.appendingPathComponent(".local/bin/codex").path]
        let versions = home.appendingPathComponent(".nvm/versions/node")
        if let names = try? fileManager.contentsOfDirectory(atPath: versions.path) {
            candidates += names.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
                .map { versions.appendingPathComponent($0 + "/bin/codex").path }
        }
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    static func process(executable: String, arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = URL(fileURLWithPath: executable).deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    static func isLoggedIn(executable: String) -> Bool {
        let process = process(executable: executable, arguments: ["login", "status"])
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return false }
        guard done.wait(timeout: .now() + 8) == .success else { process.terminate(); return false }
        return process.terminationStatus == 0
    }

    static func arguments(directory: String, conversation: String) -> [String] {
        var arguments = ["-C", directory, "-s", "workspace-write", "exec"]
        if !conversation.isEmpty { arguments.append("resume") }
        arguments += ["--skip-git-repo-check", "--json"]
        if !conversation.isEmpty { arguments.append(conversation) }
        arguments.append("-")
        return arguments
    }

    static func receipt(from output: String) throws -> AgentReceipt {
        var receipt = AgentReceipt()
        var completed = false
        var failure: String?
        for line in output.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "thread.started": receipt.conversation = event["thread_id"] as? String ?? ""
            case "item.completed":
                if let item = event["item"] as? [String: Any], item["type"] as? String == "agent_message" {
                    receipt.reply = item["text"] as? String ?? ""
                }
            case "turn.completed": completed = true
            case "turn.failed":
                failure = (event["error"] as? [String: Any])?["message"] as? String ?? "任务未完成。"
            default: break
            }
        }
        guard completed, failure == nil else {
            throw AgentDeliveryError.agentFailed("Codex 未完成任务：" + (failure ?? "请确认已登录 Codex，再重新尝试。"), conversation: receipt.conversation)
        }
        return receipt
    }

    static func run(_ target: AgentTarget, text: String, timeout: TimeInterval = 600) throws -> AgentReceipt {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input")
        let outputURL = directory.appendingPathComponent("output")
        try Data(text.utf8).write(to: inputURL)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let input = try FileHandle(forReadingFrom: inputURL)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? input.close(); try? output.close() }
        let process = process(executable: target.address,
                              arguments: arguments(directory: target.workingDirectory ?? "", conversation: target.conversation))
        process.currentDirectoryURL = target.workingDirectory.map { URL(fileURLWithPath: $0) }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        guard done.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            let events = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
            var conversation = target.conversation
            do { conversation = try receipt(from: events).conversation }
            catch AgentDeliveryError.agentFailed(_, let started) {
                if !started.isEmpty { conversation = started }
            }
            throw AgentDeliveryError.agentFailed("Codex 仍未返回结果，任务状态未知。请先检查任务，内容已保留。", conversation: conversation)
        }
        let events = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        let result = try receipt(from: events)
        guard process.terminationStatus == 0 else {
            throw AgentDeliveryError.agentFailed("Codex 未正常结束，内容已保留。", conversation: result.conversation)
        }
        return result
    }
}
