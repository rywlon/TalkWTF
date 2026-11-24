import Foundation

/// How confident the router is, and why — surfaced to the user so a wrong
/// guess is always explainable.
enum RouteTier: String {
    case direct      // the sentence named an agent
    case sticky      // "继续" right after a delivery
    case semantic    // word overlap with what this agent does
    case ambiguous   // two plausible targets: stop and ask

    var label: String {
        switch self {
        case .direct: return "点名"
        case .sticky: return "接着上一句"
        case .semantic: return "内容匹配"
        case .ambiguous: return "需要确认"
        }
    }
}

struct RouteDecision {
    var target: AgentTarget?
    var confidence: Double = 0
    var tier: RouteTier = .ambiguous
    var reason: String = ""
    var rewrittenPrompt: String = ""
    var candidates: [AgentTarget] = []

    /// Only send by itself when a single target clearly won.
    var autoDispatch: Bool { target != nil && tier != .ambiguous }
}

/// Local-only routing for "one key → the right agent". No model call, no
/// network: three cheap tiers in the order a person would use them.
enum AgentRouter {
    /// A follow-up still belongs to the previous agent this long after it ran.
    static let stickyWindow: TimeInterval = 5 * 60

    private static let continuationCues = [
        "顺便", "继续", "再把", "刚才", "刚刚", "还有", "另外", "接着",
        "然后把", "也跑一下", "再跑", "同一个",
        "also", "and then", "follow up", "continue", "next",
    ]

    /// Patterns that address the assistant rather than say anything new.
    private static let wakePrefixes = [
        "请让", "请问", "帮我让", "发给", "交给", "告诉", "让", "请", "叫",
        "send to", "tell", "ask", "hey",
    ]

    static func route(
        _ raw: String,
        agents: [AgentTarget],
        now: Date = Date()
    ) -> RouteDecision {
        var decision = RouteDecision()
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = stripWakePrefix(trimmed, agents: agents)
        decision.rewrittenPrompt = text
        guard !text.isEmpty, !agents.isEmpty else { return decision }

        // One agent means there is nothing to decide.
        if agents.count == 1 {
            decision.target = agents[0]
            decision.confidence = 0.94
            decision.tier = .direct
            decision.reason = "只连了一个 Agent"
            return decision
        }

        // Names are matched against what the user actually said: the wake
        // prefix (and the agent name inside it) is only removed from the
        // prompt that gets delivered.
        let lowered = trimmed.lowercased()

        // Tier 1 — the sentence names an agent (or its provider).
        var hits: [(agent: AgentTarget, score: Double)] = []
        for agent in agents {
            var score = 0.0
            var names: [(String, Double)] = [(agent.name, 3)]
            if let provider = agent.provider, !provider.isEmpty { names.append((provider, 2)) }
            for alias in agent.aliases ?? [] where !alias.isEmpty { names.append((alias, 3)) }
            for (name, weight) in names {
                let needle = name.lowercased()
                guard let range = lowered.range(of: needle) else { continue }
                let position = lowered.distance(from: lowered.startIndex, to: range.lowerBound)
                score += weight + (position < 10 ? 2 : 0) + Double(needle.count) * 0.1
            }
            if score > 0 { hits.append((agent, score)) }
        }
        if let best = hits.max(by: { $0.score < $1.score }) {
            decision.target = best.agent
            decision.confidence = 0.96
            decision.tier = .direct
            decision.reason = "提到了 \(best.agent.name)"
            return decision
        }

        // Tier 2 — a follow-up right after a delivery stays with that agent.
        if continuationCues.contains(where: { lowered.contains($0) }),
           let recent = mostRecent(agents, now: now) {
            decision.target = recent
            decision.confidence = 0.88
            decision.tier = .sticky
            decision.reason = "接着刚才的 \(recent.name)"
            return decision
        }

        // Tier 3 — word overlap with the agent's name, provider, folder, scope.
        let terms = extractTerms(from: text)
        var scored: [(agent: AgentTarget, score: Double)] = []
        for agent in agents {
            var score = 0.0
            let haystack = [
                agent.name,
                agent.provider ?? "",
                agent.workingDirectory ?? "",
                agent.scope ?? "",
                (agent.aliases ?? []).joined(separator: " "),
            ].joined(separator: " ").lowercased()
            for term in terms where haystack.contains(term) {
                score += term.count >= 3 ? 0.32 : 0.22
            }
            if let stamp = agent.lastUsedAt, now.timeIntervalSince1970 - stamp < stickyWindow {
                score += 0.1
            }
            scored.append((agent, min(score, 0.92)))
        }
        scored.sort { $0.score > $1.score }

        let ranked = scored.filter { $0.score > 0 }.map { $0.agent }
        if ranked.count >= 2,
           let top = scored.first,
           top.score >= 0.44,
           top.score - scored[1].score >= 0.2 {
            decision.target = top.agent
            decision.confidence = min(max(0.72 + top.score * 0.25, 0.81), 0.91)
            decision.tier = .semantic
            decision.reason = "内容更像 \(top.agent.name)"
            return decision
        }

        decision.candidates = ranked.isEmpty ? Array(agents.prefix(3)) : Array(ranked.prefix(3))
        decision.reason = "有两个都说得通"
        return decision
    }

    private static func mostRecent(_ agents: [AgentTarget], now: Date) -> AgentTarget? {
        agents
            .compactMap { agent -> (AgentTarget, Double)? in
                guard let stamp = agent.lastUsedAt else { return nil }
                return (agent, stamp)
            }
            .filter { now.timeIntervalSince1970 - $0.1 < stickyWindow }
            .max { $0.1 < $1.1 }
            .map { $0.0 }
    }

    /// Latin words (2+ chars) plus CJK runs and their bigrams — enough to
    /// match a folder or a project name without a tokenizer.
    static func extractTerms(from text: String) -> [String] {
        var terms: [String] = []
        var latin = ""
        var han = ""
        func flushLatin() {
            if latin.count >= 2 { terms.append(latin) }
            latin = ""
        }
        func flushHan() {
            let characters = Array(han)
            if characters.count >= 2 {
                terms.append(han)
                if characters.count > 2 {
                    for index in 0..<(characters.count - 1) {
                        terms.append(String(characters[index...index + 1]))
                    }
                }
            }
            han = ""
        }
        for character in text {
            if character.isLetter || character.isNumber {
                if character.unicodeScalars.allSatisfy({ $0.value >= 0x4E00 && $0.value <= 0x9FFF }) {
                    flushLatin()
                    han.append(character)
                } else {
                    flushHan()
                    latin.append(Character(character.lowercased()))
                }
            } else {
                flushLatin()
                flushHan()
            }
        }
        flushLatin()
        flushHan()
        return Array(Set(terms))
    }

    /// "交给 Codex 帮我审一下" → "帮我审一下": drop the addressee, keep the
    /// instruction. Only fires when a real agent name follows the prefix, so a
    /// plain "请把这段改短" is left untouched.
    static func stripWakePrefix(_ text: String, agents: [AgentTarget]) -> String {
        let lowered = text.lowercased()
        var names: [String] = []
        for agent in agents {
            names.append(agent.name)
            if let provider = agent.provider, !provider.isEmpty { names.append(provider) }
            names.append(contentsOf: agent.aliases ?? [])
        }
        for prefix in wakePrefixes where lowered.hasPrefix(prefix.lowercased()) {
            var rest = String(text.dropFirst(prefix.count))
            rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: "，,。.：: ").union(.whitespaces))
            let restLowered = rest.lowercased()
            guard names.contains(where: { !$0.isEmpty && restLowered.hasPrefix($0.lowercased()) }) else {
                continue
            }
            if let name = names.first(where: { !$0.isEmpty && restLowered.hasPrefix($0.lowercased()) }) {
                rest = String(rest.dropFirst(name.count))
                rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: "，,。.：: ").union(.whitespaces))
            }
            if !rest.isEmpty { return rest }
        }
        return text
    }
}
