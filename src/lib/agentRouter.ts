import type { AgentRouteCandidate, AgentRouteDecision, AgentTarget } from '../types';

const STICKY_WINDOW_MS = 5 * 60 * 1000; // 5 minutes

const CONTINUATION_CUES = [
  '顺便',
  '继续',
  '再把',
  '刚才',
  '刚刚',
  '还有',
  '另外',
  '接着',
  '然后把',
  '也跑一下',
  'also',
  'and then',
  'follow up',
  'continue',
  'next',
];

/**
 * Extracts normalized Chinese + English tokens and bigrams for lightweight
 * local semantic matching against Agent capability manifests.
 */
function extractTerms(text: string): string[] {
  const lowered = text.toLowerCase();
  const latin = lowered.match(/[a-z0-9_-]{2,}/g) ?? [];
  const cjkBlocks = lowered.match(/[\u4e00-\u9fff]{2,}/g) ?? [];
  const cjkGrams: string[] = [];

  for (const block of cjkBlocks) {
    cjkGrams.push(block);
    for (let i = 0; i <= block.length - 2; i++) {
      cjkGrams.push(block.slice(i, i + 2));
    }
  }
  return Array.from(new Set([...latin, ...cjkGrams]));
}

/**
 * Strips leading wake-word address phrases (e.g. "让 Codex 帮我把..." -> "把...")
 * so the dispatched instruction is crisp and directly executable.
 */
function stripWakePrefix(text: string, matchedAlias: string): string {
  const escaped = matchedAlias.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const pattern = new RegExp(
    `^(?:请|让|叫|发给|交给|给|告诉|ask|tell|send to|hey)?\\s*${escaped}\\s*(?:帮我|帮忙|去|来|一下|，|,|:|：)?\\s*`,
    'i',
  );
  const cleaned = text.replace(pattern, '').trim();
  return cleaned.length >= 2 ? cleaned : text.trim();
}

/**
 * Tiny Voice-to-Agent Dispatch Harness (Single-Turn Local Router):
 * - Tier 1 (0ms Deterministic Rule): Explicit wake alias or Agent name mention
 * - Tier 2 (0ms Sticky Continuity): Continuation cue within 5 min of last active Agent
 * - Tier 3 (Semantic Capability Manifest): Matches spoken intent against Agent scope,
 *   working directory, aliases, and provider metadata
 * - Confidence Gate: Auto-dispatch only when confidence >= 0.80 and unambiguous;
 *   otherwise holds for 1/2/3 user selection without guessing blindly.
 */
export function routeToLocalAgent(
  polishedText: string,
  agents: AgentTarget[],
  locale: 'zh' | 'en' = 'zh',
  nowMs: number = Date.now(),
): AgentRouteDecision {
  const trimmed = polishedText.trim();
  if (!trimmed || agents.length === 0) {
    return {
      target: null,
      confidence: 0,
      tier: 'none',
      reason:
        locale === 'zh'
          ? '尚未配对任何本地 Agent，请先连接至少一个会话。'
          : 'No local Agents paired yet.',
      rewrittenPrompt: trimmed,
      candidates: [],
      autoDispatch: false,
    };
  }

  // Single paired agent: always route directly with high confidence
  if (agents.length === 1) {
    const sole = agents[0];
    return {
      target: sole,
      confidence: 0.94,
      tier: 'rule',
      reason:
        locale === 'zh'
          ? `当前仅配对了「${sole.name}」，直接投递`
          : `Only one paired Agent (${sole.name})`,
      rewrittenPrompt: trimmed,
      candidates: [{ agent: sole, score: 0.94, reason: sole.scope || sole.provider }],
      autoDispatch: true,
    };
  }

  const lower = trimmed.toLowerCase();

  // Tier 1: Deterministic explicit wake alias / provider / name hit
  const ruleHits: Array<{ agent: AgentTarget; matched: string; priority: number }> = [];
  for (const agent of agents) {
    const aliases = (agent.aliases ?? []).filter((a) => a.trim().length > 0);
    const directTokens = [
      ...aliases.map((a) => ({ token: a.trim(), weight: 3 })),
      { token: agent.provider, weight: 2 },
      { token: agent.name, weight: 3 },
    ];

    for (const item of directTokens) {
      const needle = item.token.toLowerCase();
      if (needle.length < 2) continue;
      if (lower.includes(needle)) {
        // Favor matches near the beginning of the sentence ("让后端把...")
        const idx = lower.indexOf(needle);
        const posBoost = idx < 10 ? 2 : 0;
        ruleHits.push({ agent, matched: item.token, priority: item.weight + posBoost + needle.length * 0.1 });
        break;
      }
    }
  }

  if (ruleHits.length === 1) {
    const hit = ruleHits[0];
    const rewritten = stripWakePrefix(trimmed, hit.matched);
    const others = agents
      .filter((a) => a.id !== hit.agent.id)
      .map((a) => ({
        agent: a,
        score: 0.2,
        reason: a.scope || a.workingDirectory || a.provider,
      }));
    return {
      target: hit.agent,
      confidence: 0.96,
      tier: 'rule',
      reason:
        locale === 'zh'
          ? `命中唤醒词「${hit.matched}」`
          : `Matched wake alias "${hit.matched}"`,
      rewrittenPrompt: rewritten,
      candidates: [
        {
          agent: hit.agent,
          score: 0.96,
          reason:
            locale === 'zh'
              ? `命中唤醒词「${hit.matched}」`
              : `Matched alias "${hit.matched}"`,
        },
        ...others,
      ],
      autoDispatch: true,
    };
  }

  // Tier 2: Sticky Session Continuity (continuation cue within 5 minutes of last dispatch)
  const recentlyUsed = [...agents]
    .filter((a) => a.lastUsedAt && nowMs - a.lastUsedAt <= STICKY_WINDOW_MS)
    .sort((a, b) => (b.lastUsedAt ?? 0) - (a.lastUsedAt ?? 0))[0];

  const hasContinuationCue = CONTINUATION_CUES.some((cue) => lower.includes(cue));
  if (recentlyUsed && hasContinuationCue && ruleHits.length === 0) {
    const minsAgo = Math.max(1, Math.round((nowMs - (recentlyUsed.lastUsedAt ?? nowMs)) / 60000));
    const others = agents
      .filter((a) => a.id !== recentlyUsed.id)
      .map((a) => ({
        agent: a,
        score: 0.25,
        reason: a.scope || a.workingDirectory || a.provider,
      }));
    return {
      target: recentlyUsed,
      confidence: 0.88,
      tier: 'sticky',
      reason:
        locale === 'zh'
          ? `延续 ${minsAgo} 分钟前活跃会话（上下文承接）`
          : `Continuing active session from ${minsAgo}m ago`,
      rewrittenPrompt: trimmed,
      candidates: [
        {
          agent: recentlyUsed,
          score: 0.88,
          reason:
            locale === 'zh' ? '最近活跃会话承接' : 'Recent active session',
        },
        ...others,
      ],
      autoDispatch: true,
    };
  }

  // Tier 3: Semantic Capability Manifest Scoring
  const inputTerms = extractTerms(trimmed);
  const scored: AgentRouteCandidate[] = agents
    .map((agent) => {
      const manifestText = [
        agent.name,
        agent.provider,
        agent.scope ?? '',
        agent.workingDirectory ?? '',
        ...(agent.aliases ?? []),
      ].join(' ');
      const manifestTerms = extractTerms(manifestText);
      const matchedTerms: string[] = [];

      let rawScore = 0;
      for (const term of inputTerms) {
        if (manifestTerms.includes(term)) {
          matchedTerms.push(term);
          rawScore += term.length >= 3 ? 0.32 : 0.22;
        }
      }

      // If multiple rule hits existed, give them extra weight
      if (ruleHits.some((h) => h.agent.id === agent.id)) {
        rawScore += 0.45;
      }

      // Light recency prior
      if (agent.lastUsedAt && nowMs - agent.lastUsedAt <= STICKY_WINDOW_MS) {
        rawScore += 0.1;
      }

      const normalized = Math.min(0.92, rawScore);
      const topMatches = matchedTerms.slice(0, 3).join(' / ');
      const reason =
        matchedTerms.length > 0
          ? locale === 'zh'
            ? `职责匹配：${topMatches}`
            : `Matched scope: ${topMatches}`
          : agent.scope || agent.workingDirectory || agent.provider;

      return { agent, score: normalized, reason };
    })
    .sort((a, b) => b.score - a.score);

  const top = scored[0];
  const second = scored[1];
  const margin = top ? top.score - (second?.score ?? 0) : 0;

  if (top && top.score >= 0.44 && margin >= 0.2) {
    const confidence = Math.min(0.91, Math.max(0.81, 0.72 + top.score * 0.25));
    return {
      target: top.agent,
      confidence,
      tier: 'semantic',
      reason: top.reason,
      rewrittenPrompt: trimmed,
      candidates: scored,
      autoDispatch: true,
    };
  }

  // Ambiguous: hold dispatch and ask user to tap 1 / 2 / 3
  return {
    target: top?.agent ?? null,
    confidence: Math.min(0.68, Math.max(0.35, top?.score ?? 0.35)),
    tier: 'ambiguous',
    reason:
      locale === 'zh'
        ? '多个 Agent 均可能适用，按数字键 1 / 2 / 3 或点击确认投递目标'
        : 'Multiple Agents could handle this — press 1 / 2 / 3 or click to dispatch',
    rewrittenPrompt: trimmed,
    candidates: scored,
    autoDispatch: false,
  };
}
