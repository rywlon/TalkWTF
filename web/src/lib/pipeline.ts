import type { CorrectionRule, DictionaryWord, Scene, SoundTheme } from '../types';

/**
 * Local deterministic dictation polishing pipeline modeled after core/core/src/pipeline.rs:
 * - Applies enabled dictionary correction rules
 * - Enforces canonical casing for custom vocabulary words
 * - Strips filler words when enabled
 * - Handles simple spoken list markers and self-correction cues
 * - Applies active scene or polish style formatting
 */
export function runLocalPolishPipeline(params: {
  rawText: string;
  words: DictionaryWord[];
  rules: CorrectionRule[];
  fillerRemoval: boolean;
  polishStyle: string;
  activeScene: Scene | null;
  appendTrailingSpace: boolean;
}): string {
  let text = params.rawText.trim();
  if (!text) return '';

  // 1. Apply enabled correction rules (longest pattern first)
  const enabledRules = [...params.rules]
    .filter((r) => r.enabled && r.pattern.trim().length > 0)
    .sort((a, b) => b.pattern.length - a.pattern.length);

  for (const rule of enabledRules) {
    const escaped = rule.pattern.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    text = text.replace(new RegExp(escaped, 'gi'), rule.replacement);
  }

  // 2. Normalize custom vocabulary casing for Latin words
  for (const item of params.words) {
    const w = item.word.trim();
    if (!w) continue;
    if (/^[A-Za-z0-9._-]+$/.test(w)) {
      const escaped = w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      text = text.replace(new RegExp(`\\b${escaped}\\b`, 'gi'), w);
    }
  }

  // 3. Remove common filler words when enabled
  if (params.fillerRemoval) {
    text = text
      .replace(/^(嗯+|啊+|呃+|那个|就是说)[，,、\s]*/g, '')
      .replace(/[，,\s]+(嗯+|呃+|那个|就是说)[，,\s]+/g, '，')
      .replace(/\b(um+|uh+|like,\s|you know,?\s)/gi, '')
      .replace(/\s{2,}/g, ' ')
      .trim();
  }

  // 4. Handle basic Chinese/English enumeration into numbered list for structured/meeting scenes
  const wantsStructured =
    params.polishStyle === 'structured' ||
    params.activeScene?.id === 'builtin_meeting_notes' ||
    params.activeScene?.id === 'builtin_product_spec_notes';

  if (wantsStructured && /(首先|第一).*(然后|第二)/.test(text)) {
    const parts = text
      .split(/(?:首先|第一[，,、]?|然后|第二[，,、]?|最后|第三[，,、]?)/)
      .map((s) => s.replace(/^[，,、。\s]+|[，,、。\s]+$/g, ''))
      .filter(Boolean);
    if (parts.length >= 2) {
      text = parts.map((p, idx) => `${idx + 1}. ${p}`).join('\n');
    }
  }

  // 5. Spoken punctuation replacements
  text = text
    .replace(/「?逗号」?/g, '，')
    .replace(/「?句号」?/g, '。')
    .replace(/「?问号」?/g, '？');

  // 6. Match TalkWTF rule: strip terminal period "." or "。"
  text = text.replace(/[。.]$/, '');

  // 7. Scene-specific framing
  if (params.activeScene?.id === 'builtin_professional_email' && !text.includes('\n')) {
    text = `您好，\n\n${text}\n\n顺祝商祺`;
  } else if (params.activeScene?.id === 'builtin_code_comment' && !text.startsWith('建议')) {
    text = `[Review] ${text}`;
  }

  if (params.appendTrailingSpace && text.length > 0) {
    text += ' ';
  }

  return text;
}

/**
 * Lightweight local translation fallback for web preview without a server-side LLM key.
 * Clearly marks target language when real cloud translation isn't configured.
 */
export function runLocalTranslationFallback(
  polishedText: string,
  targetCode: string,
  targetLabel: string,
): string {
  const cleaned = polishedText.trim();
  if (!cleaned) return '';

  // Common demo phrase dictionary for instant preview
  const quickMap: Record<string, Record<string, string>> = {
    en: {
      你好: 'Hello',
      谢谢: 'Thank you',
      今天天气不错: 'The weather is nice today',
    },
    ja: {
      你好: 'こんにちは',
      谢谢: 'ありがとうございます',
    },
  };

  if (quickMap[targetCode]?.[cleaned]) {
    return quickMap[targetCode][cleaned];
  }

  return `[${targetLabel} · Local Preview] ${cleaned}`;
}

/**
 * Synthesizes subtle macOS-like start/stop audio chimes (Marimba / Pop) via Web Audio API.
 */
export function playFeedbackChime(
  kind: 'start' | 'stop',
  theme: SoundTheme,
  volume: number,
): void {
  if (volume <= 0.01) return;
  try {
    const AudioCtx =
      window.AudioContext || (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext;
    if (!AudioCtx) return;
    const ctx = new AudioCtx();
    const now = ctx.currentTime;
    const gain = ctx.createGain();
    const osc = ctx.createOscillator();

    const baseFreq = theme === 'pop' ? (kind === 'start' ? 520 : 390) : kind === 'start' ? 587.33 : 440;
    const secondFreq = theme === 'pop' ? (kind === 'start' ? 740 : 300) : kind === 'start' ? 880 : 329.63;

    osc.type = theme === 'pop' ? 'sine' : 'triangle';
    osc.frequency.setValueAtTime(baseFreq, now);
    osc.frequency.exponentialRampToValueAtTime(secondFreq, now + 0.09);

    gain.gain.setValueAtTime(0.001, now);
    gain.gain.exponentialRampToValueAtTime(Math.min(0.25, volume * 0.22), now + 0.015);
    gain.gain.exponentialRampToValueAtTime(0.0001, now + 0.16);

    osc.connect(gain);
    gain.connect(ctx.destination);
    osc.start(now);
    osc.stop(now + 0.18);
    window.setTimeout(() => {
      void ctx.close();
    }, 250);
  } catch {
    // Ignore autoplay / AudioContext restrictions
  }
}

export function formatDuration(ms: number): string {
  const totalSeconds = Math.max(0, Math.floor(ms / 1000));
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  if (hours > 0) return `${hours}h ${minutes}m`;
  if (minutes > 0) return `${minutes}m ${seconds}s`;
  return `${seconds}s`;
}

export function formatRelativeTime(timestampSec: number, locale: 'zh' | 'en'): string {
  const diff = Math.max(0, Math.floor(Date.now() / 1000) - timestampSec);
  if (diff < 60) return locale === 'zh' ? '刚刚' : 'just now';
  const mins = Math.floor(diff / 60);
  if (mins < 60) return locale === 'zh' ? `${mins} 分钟前` : `${mins}m ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return locale === 'zh' ? `${hours} 小时前` : `${hours}h ago`;
  const days = Math.floor(hours / 24);
  return locale === 'zh' ? `${days} 天前` : `${days}d ago`;
}
