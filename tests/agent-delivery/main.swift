import Foundation

// These checks exercise payloads, validation and actual background delivery.
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
let target = AgentTarget(name: "Research", kind: .http, address: "http://127.0.0.1:8765/inbox", arguments: [], conversation: "project-a")
let request = try AgentTransport.request(for: target, text: "检查 `a` 和 $(echo nope)\n下一步")
check(request.httpBody != nil, "delivery must contain the transcript payload")
let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
check(body["text"] as? String == "检查 `a` 和 $(echo nope)\n下一步", "transcript must survive unchanged")
check(body["conversation"] as? String == "project-a", "must route to the chosen conversation")
check(request.httpMethod == "POST", "delivery must post")
for address in ["", "file:///tmp/inbox", "http://example.com/inbox", "https://name:secret@example.com"] {
    var invalid = target; invalid.address = address
    do { _ = try AgentTransport.request(for: invalid, text: "hello"); fatalError("accepted invalid address: \(address)") }
    catch is AgentDeliveryError { }
}
do { _ = try AgentTransport.request(for: target, text: " \n"); fatalError("accepted empty transcript") }
catch is AgentDeliveryError { }
let data = try JSONEncoder().encode([target])
let decoded = try JSONDecoder().decode([AgentTarget].self, from: data)
check(decoded == [target], "targets must round-trip")

if CommandLine.arguments.count > 1 {
    var live = target; live.address = CommandLine.arguments[1]
    try AgentTransport.deliver(to: live, text: "原样发送 $(touch /tmp/talkwtf-should-not-exist)")
    live.address += "/fail"
    do { try AgentTransport.deliver(to: live, text: "fail"); fatalError("accepted HTTP failure") }
    catch is AgentDeliveryError { }
    live.address = CommandLine.arguments[1] + "/redirect"
    do { try AgentTransport.deliver(to: live, text: "private"); fatalError("followed redirect") }
    catch is AgentDeliveryError { }
}
var command = target
command.kind = .command
command.address = "/usr/bin/tee"
let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
command.arguments = [output]
try AgentTransport.deliver(to: command, text: "原样 $(echo no)\n第二行")
let received = try String(contentsOfFile: output, encoding: .utf8)
check(received == "原样 $(echo no)\n第二行", "command must receive literal stdin")
try FileManager.default.removeItem(atPath: output)
command.address = "/usr/bin/false"; command.arguments = []
do { try AgentTransport.deliver(to: command, text: "fail"); fatalError("accepted command failure") }
catch is AgentDeliveryError { }
print("Agent delivery checks passed")

let folder = "/tmp/project with spaces"
check(CodexConnection.arguments(directory: folder, conversation: "") == ["-C", folder, "-s", "workspace-write", "exec", "--skip-git-repo-check", "--json", "-"], "new voice agent must start in the chosen folder")
check(CodexConnection.arguments(directory: folder, conversation: "session-123") == ["-C", folder, "-s", "workspace-write", "exec", "resume", "--skip-git-repo-check", "--json", "session-123", "-"], "later messages must resume the same session")
let receipt = try CodexConnection.receipt(from: """
{"type":"thread.started","thread_id":"session-123"}
{"type":"item.completed","item":{"type":"agent_message","text":"已检查项目。"}}
{"type":"turn.completed"}
""")
check(receipt.conversation == "session-123", "must remember session identity")
check(receipt.reply == "已检查项目。", "must show agent reply")
do { _ = try CodexConnection.receipt(from: "{\"type\":\"turn.failed\",\"error\":{\"message\":\"login required\"}}"); fatalError("failed agent turn must not report success") }
catch is AgentDeliveryError { }
print("Built-in Codex connection checks passed")
if CommandLine.arguments.count > 3 {
    check(CodexConnection.isLoggedIn(executable: CommandLine.arguments[2]), "must recognize successful login status")
    check(!CodexConnection.isLoggedIn(executable: "/usr/bin/false"), "must reject unauthenticated status")
    let voice = AgentTarget(name: "Codex", kind: .codex, address: CommandLine.arguments[2], workingDirectory: CommandLine.arguments[3])
    let first = try AgentTransport.deliver(to: voice, text: "原样传递 $(echo no)\n继续")
    check(first.conversation == "fixture-session", "first delivery must return a reusable conversation")
    check(first.reply == "原样传递 $(echo no)\n继续", "built-in delivery must pass literal stdin and return the reply")
    var resumed = voice; resumed.conversation = first.conversation
    let second = try AgentTransport.deliver(to: resumed, text: "再来一条")
    check(second.reply == "再来一条", "must resume the same agent with the next message")
    do {
        _ = try CodexConnection.run(voice, text: "timeout", timeout: 0.3)
        fatalError("timeout must fail")
    } catch AgentDeliveryError.agentFailed(_, let conversation) {
        check(conversation == "fixture-session", "timeout must preserve already-created conversation")
    }
    print("Built-in process delivery and conversation resume checks passed")
}

try runPairingChecks()
