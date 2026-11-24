import Foundation

func check(_ condition: Bool, _ message: String) {
    if !condition {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

func runRouterChecks() {
    let now = Date(timeIntervalSince1970: 1_000_000)

    let codex = AgentTarget(name: "Codex", kind: .codex, address: "/usr/bin/true",
                            workingDirectory: "/Users/x/Documents/ChatGPT/review")
    let claude = AgentTarget(name: "Claude", kind: .http,
                             address: "https://localhost/hook",
                             provider: "Anthropic",
                             scope: "写作 文案 copywriting")

    // One agent: nothing to decide.
    let only = AgentRouter.route("随便说点什么", agents: [codex])
    check(only.target?.name == "Codex", "single agent must win")
    check(only.tier == RouteTier.direct, "single agent is a direct route")
    check(only.autoDispatch, "single agent dispatches")

    // Addressed by name, and the addressee is stripped from the prompt.
    let named = AgentRouter.route("交给 Codex 帮我把这个函数重构一下", agents: [codex, claude])
    check(named.target?.name == "Codex", "named agent must win")
    check(named.tier == RouteTier.direct, "naming is a direct route")
    check(named.rewrittenPrompt == "帮我把这个函数重构一下",
          "wake prefix must be stripped, got \(named.rewrittenPrompt)")

    // No name in the sentence: leave ordinary text alone.
    let plain = AgentRouter.route("请把这段改短一点", agents: [codex, claude])
    check(plain.rewrittenPrompt == "请把这段改短一点", "plain text must not be rewritten")

    // A follow-up stays with whoever ran last.
    var recent = codex
    recent.lastUsedAt = now.timeIntervalSince1970 - 60
    let followUp = AgentRouter.route("顺便把这个也跑一遍", agents: [recent, claude], now: now)
    check(followUp.target?.name == "Codex", "follow-up must stay with the last agent")
    check(followUp.tier == RouteTier.sticky, "follow-up is the sticky tier")

    // Word overlap with the folder / scope wins without a name.
    let semantic = AgentRouter.route("帮我看看这个 review 的 copywriting 文案", agents: [codex, claude], now: now)
    check(semantic.target != nil, "overlap must produce a target")
    check(semantic.autoDispatch, "a clear overlap dispatches")

    // Two strangers: stop and ask.
    let stranger = AgentTarget(name: "Zed", kind: .http, address: "https://localhost/zed")
    let other = AgentTarget(name: "Nova", kind: .http, address: "https://localhost/nova")
    let ambiguous = AgentRouter.route("明天天气怎么样", agents: [stranger, other], now: now)
    check(ambiguous.target == nil, "no evidence must not pick an agent")
    check(!ambiguous.autoDispatch, "ambiguous routes must not dispatch")
    check(ambiguous.candidates.count == 2, "both agents must be offered")

    print("router checks passed")
}
