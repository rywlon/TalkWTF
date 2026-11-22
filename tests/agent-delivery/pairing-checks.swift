import Foundation

func runPairingChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let pairing = try AgentPairing.create(root: root, provider: .codex, executable: "/Applications/TalkWTF.app/Contents/MacOS/TalkWTF", now: 100)
    check(pairing.prompt.contains(pairing.instructionsURL.path), "prompt must give the agent a readable connection document")
    let instructions = try String(contentsOf: pairing.instructionsURL, encoding: .utf8)
    check(instructions.contains("connect-agent"), "instructions must include the bundled connection command")
    let pending = try pairing.readResponse(now: 101)
    check(pending == nil, "no response must stay pending")
    let target = AgentTarget(name: "Current Codex", kind: .codex, address: "/usr/bin/true", conversation: UUID().uuidString, workingDirectory: root.path)
    try AgentPairing.register(requestURL: pairing.requestURL, target: target, now: 101)
    let connected = try pairing.readResponse(now: 102)
    check(connected?.id == pairing.request.targetID, "pairing must control the destination identity")
    check(connected?.conversation == target.conversation, "pairing must retain exact current session")
    do { _ = try pairing.readResponse(now: 701); fatalError("expired pairing accepted") }
    catch is AgentDeliveryError { }
    var response = try JSONDecoder().decode(PairingResponse.self, from: Data(contentsOf: pairing.responseURL))
    response.token = "wrong-token"
    try JSONEncoder().encode(response).write(to: pairing.responseURL)
    do { _ = try pairing.readResponse(now: 102); fatalError("forged pairing accepted") }
    catch is AgentDeliveryError { }
    response.token = pairing.request.token
    response.provider = .cursor
    try JSONEncoder().encode(response).write(to: pairing.responseURL)
    do { _ = try pairing.readResponse(now: 102); fatalError("wrong provider accepted") }
    catch is AgentDeliveryError { }
    try pairing.cancel()
    do { try AgentPairing.register(requestURL: pairing.requestURL, target: target, now: 102); fatalError("canceled pairing accepted") }
    catch { }
    let local = try AgentPairing.create(root: root, provider: .other, executable: "/Applications/TalkWTF.app/Contents/MacOS/TalkWTF", now: 100)
    let output = root.appendingPathComponent("received.txt")
    let adapter = AgentTarget(name: "Local adapter", kind: .command, address: "/usr/bin/tee", arguments: [output.path], conversation: "current-test-session")
    try AgentPairing.register(requestURL: local.requestURL, target: adapter, now: 101)
    let registered = try local.readResponse(now: 102)!
    try AgentTransport.deliver(to: registered, text: "配对后原样送达 $(echo no)")
    let delivered = try String(contentsOf: output, encoding: .utf8)
    check(delivered == "配对后原样送达 $(echo no)", "registered adapter must really receive the literal message")
    try local.cancel()
    print("Pairing lifecycle, exact session, token, provider, expiration and registered-adapter delivery checks passed")
}
