import React, { useEffect, useState } from 'react';
import {
  AlertCircle,
  Check,
  CheckCircle2,
  ChevronDown,
  ChevronRight,
  Copy,
  Globe,
  Loader2,
  Mic,
  Plus,
  SlidersHorizontal,
  Terminal,
  Trash2,
  X,
} from 'lucide-react';
import { AGENT_CHOICES } from '../data/defaults';
import { useAppStore } from '../store/AppStore';
import type { AgentChoice, AgentTarget } from '../types';
import { KeycapCombo, ResilientImage } from './ui/Controls';

const WAVEGUIDE_IMG = '/src/assets/images/agent_acoustic_waveguide_1795522819992.jpg';

export const AgentsView: React.FC = () => {
  const {
    agents,
    agentDelivery,
    settings,
    saveAgent,
    removeAgent,
    deliverToAgent,
    clearAgentStatus,
    updateBinding,
    openDictation,
    t,
  } = useAppStore();

  const [pairingTarget, setPairingTarget] = useState<AgentTarget | null>(null);
  const [capturingBinding, setCapturingBinding] = useState<string | null>(null);
  const [copiedFailed, setCopiedFailed] = useState(false);

  useEffect(() => {
    if (!capturingBinding) return;
    const onKeyDown = (e: KeyboardEvent) => {
      e.preventDefault();
      e.stopPropagation();
      if (e.key === 'Escape') {
        setCapturingBinding(null);
        return;
      }
      if (['Shift', 'Control', 'Alt', 'Meta'].includes(e.key)) return;
      const parts: string[] = [];
      if (e.metaKey) parts.push('Cmd');
      if (e.ctrlKey) parts.push('Ctrl');
      if (e.altKey) parts.push('Alt');
      if (e.shiftKey) parts.push('Shift');
      const keyName = e.key === ' ' ? 'Space' : e.key.length === 1 ? e.key.toUpperCase() : e.key;
      parts.push(keyName);
      updateBinding(capturingBinding, parts.join('+'));
      setCapturingBinding(null);
    };
    window.addEventListener('keydown', onKeyDown, true);
    return () => window.removeEventListener('keydown', onKeyDown, true);
  }, [capturingBinding, updateBinding]);

  const shortcutFor = (target: AgentTarget): string =>
    settings.bindings[target.bindingID]?.current_binding ?? '';

  const openNewPairing = () => {
    const id = `agent-${Date.now()}`;
    setPairingTarget({
      id,
      name: '',
      kind: 'codex',
      provider: 'Codex',
      address: '',
      conversation: '',
      bindingID: `agent_${Date.now()}`,
    });
  };

  const copyFailedText = async () => {
    if (!agentDelivery.failedText) return;
    try {
      await navigator.clipboard.writeText(agentDelivery.failedText);
      setCopiedFailed(true);
      window.setTimeout(() => setCopiedFailed(false), 1600);
    } catch {
      // ignore
    }
  };

  return (
    <div className="h-full overflow-y-auto">
      <div className="max-w-[1160px] mx-auto px-6 lg:px-10 py-8 lg:py-10 space-y-10">
        {/* Sharp-Edged Editorial Hero with Architectural Waveguide Photography */}
        <section
          className="relative overflow-hidden border min-h-[216px] flex items-end"
          style={{ borderColor: 'var(--border-hairline)', backgroundColor: '#111214' }}
        >
          <ResilientImage
            src={WAVEGUIDE_IMG}
            alt="Machined slate acoustic waveguide fins with vermilion optical channel"
            className="absolute inset-0 w-full h-full object-cover"
            fallbackLabel="Voice to Agent Routing"
          />
          <div
            className="absolute inset-0"
            style={{
              background:
                'linear-gradient(95deg, rgba(11,12,14,0.94) 0%, rgba(11,12,14,0.72) 56%, rgba(11,12,14,0.36) 100%)',
            }}
          />

          <div className="relative z-10 w-full p-7 lg:p-9 flex flex-wrap items-end justify-between gap-6 text-[#f2f3f5]">
            <div className="space-y-2.5 max-w-[56ch]">
              <div className="text-[12px] font-mono-tabular text-white/60">
                {settings.app_language === 'zh'
                  ? '后台直达 / 固定会话目标 / 失败可恢复'
                  : 'BACKGROUND DELIVERY / FIXED TARGET / RECOVERABLE'}
              </div>
              <h1
                className="font-display headline-balance font-semibold tracking-[-0.03em] leading-[1.1]"
                style={{ fontSize: 'clamp(1.85rem, 3vw, 2.6rem)' }}
              >
                {t('agents.bannerTitle')}
              </h1>
              <p className="text-[14.5px] text-white/75 leading-relaxed">
                {t('agents.bannerSub')}
              </p>
            </div>

            <button
              type="button"
              onClick={openNewPairing}
              className="btn-accent h-11 px-5 text-[13.5px] flex items-center gap-2 cursor-pointer"
            >
              <Plus className="w-4 h-4" />
              <span>{t('agents.connect')}</span>
            </button>
          </div>
        </section>

        {/* Live Delivery Receipt / Recoverable Failure Strip */}
        {agentDelivery.status && (
          <section
            className="border-y py-5 space-y-3"
            style={{ borderColor: 'var(--border-strong)' }}
          >
            <div className="flex items-center justify-between gap-3">
              <div
                className="flex items-center gap-2 text-[13.5px] font-medium"
                style={{
                  color: agentDelivery.failedText
                    ? 'var(--status-warn)'
                    : 'var(--ink-primary)',
                }}
              >
                {agentDelivery.sending ? (
                  <Loader2 className="w-4 h-4 animate-spin" style={{ color: 'var(--accent)' }} />
                ) : agentDelivery.failedText ? (
                  <AlertCircle className="w-4 h-4" style={{ color: 'var(--status-warn)' }} />
                ) : (
                  <CheckCircle2 className="w-4 h-4" style={{ color: 'var(--status-ok)' }} />
                )}
                <span>{agentDelivery.status}</span>
              </div>
              <button
                type="button"
                onClick={clearAgentStatus}
                className="text-[12px] hover:underline cursor-pointer"
                style={{ color: 'var(--ink-secondary)' }}
              >
                {settings.app_language === 'zh' ? '收起' : 'Dismiss'}
              </button>
            </div>

            {agentDelivery.reply && (
              <p
                className="text-[13.5px] leading-relaxed select-text"
                style={{ color: 'var(--ink-secondary)' }}
              >
                {agentDelivery.reply}
              </p>
            )}

            {agentDelivery.failedText && (
              <div className="space-y-3 pt-1">
                <p className="studio-well p-3.5 text-[13.5px] select-text">
                  {agentDelivery.failedText}
                </p>
                <div className="flex flex-wrap items-center gap-2">
                  <button
                    type="button"
                    onClick={() => void copyFailedText()}
                    className="btn-ghost h-9 px-3.5 text-[12.5px] cursor-pointer"
                  >
                    {copiedFailed
                      ? t('common.copied')
                      : settings.app_language === 'zh'
                        ? '复制保留内容'
                        : 'Copy Preserved Text'}
                  </button>
                  {agentDelivery.failedTarget && (
                    <button
                      type="button"
                      onClick={() =>
                        deliverToAgent(agentDelivery.failedText!, agentDelivery.failedTarget!, false)
                      }
                      className="btn-accent h-9 px-3.5 text-[12.5px] cursor-pointer"
                    >
                      {settings.app_language === 'zh' ? '手动重试发送' : 'Retry Delivery'}
                    </button>
                  )}
                </div>
                <p className="text-[12px]" style={{ color: 'var(--ink-tertiary)' }}>
                  {settings.app_language === 'zh'
                    ? '发送结果可能未知，请先检查接收端，避免重复执行。TalkWTF 不会自动重发。'
                    : 'Delivery outcome is unconfirmed. Check the receiving Agent before retrying; TalkWTF never auto-resends.'}
                </p>
              </div>
            )}
          </section>
        )}

        {/* Open Hairline-Ruled Paired Conversations Directory */}
        <section className="space-y-3 pb-8">
          <div className="flex items-center justify-between">
            <h2 className="text-[12.5px] font-semibold tracking-wide" style={{ color: 'var(--ink-secondary)' }}>
              {settings.app_language === 'zh' ? '已配对会话' : 'Paired Conversations'}
            </h2>
            <span className="font-mono-tabular text-[12px]" style={{ color: 'var(--ink-tertiary)' }}>
              {agents.length}
            </span>
          </div>

          {agents.length === 0 ? (
            <div className="border-t py-10 space-y-4" style={{ borderColor: 'var(--border-hairline)' }}>
              <h3 className="font-display text-[22px] font-semibold">{t('agents.emptyTitle')}</h3>
              <p className="text-[14px] max-w-[54ch]" style={{ color: 'var(--ink-secondary)' }}>
                {t('agents.emptySub')}
              </p>
              <button
                type="button"
                onClick={openNewPairing}
                className="btn-accent h-10 px-4 text-[13.5px] cursor-pointer"
              >
                {t('agents.connect')}
              </button>
            </div>
          ) : (
            <div
              className="border-y divide-y"
              style={{ borderColor: 'var(--border-hairline)' }}
            >
              {agents.map((target) => {
                const combo = shortcutFor(target);
                const isCapturing = capturingBinding === target.bindingID;
                return (
                  <div
                    key={target.id}
                    className="py-5 px-2 -mx-2 flex flex-wrap items-center gap-4 transition-colors hover:bg-[var(--bg-hover)]"
                    style={{ borderColor: 'var(--border-hairline)' }}
                  >
                    <div
                      className="w-10 h-10 flex items-center justify-center shrink-0 border"
                      style={{
                        borderColor: 'var(--border-hairline)',
                        color: 'var(--accent)',
                      }}
                    >
                      {target.kind === 'http' ? (
                        <Globe className="w-4 h-4" />
                      ) : (
                        <Terminal className="w-4 h-4" />
                      )}
                    </div>

                    <div className="min-w-0 flex-1 space-y-1">
                      <div className="text-[15px] font-semibold truncate">{target.name}</div>
                      <div
                        className="flex flex-wrap items-center gap-2 text-[12.5px]"
                        style={{ color: 'var(--ink-secondary)' }}
                      >
                        <span>{target.provider}</span>
                        <span aria-hidden="true">·</span>
                        <span>{t('agents.paired')}</span>
                        <span aria-hidden="true">·</span>
                        <span className="font-mono-tabular" style={{ color: 'var(--ink-tertiary)' }}>
                          {target.conversation.slice(0, 14)}
                        </span>
                      </div>
                    </div>

                    <div className="flex flex-wrap items-center gap-2.5 shrink-0">
                      <button
                        type="button"
                        onClick={() => openDictation('agent', target)}
                        className="btn-accent h-9 px-3.5 text-[13px] flex items-center gap-1.5 cursor-pointer"
                      >
                        <Mic className="w-3.5 h-3.5" />
                        <span>{t('agents.speakTo')}</span>
                      </button>

                      <button
                        type="button"
                        onClick={() =>
                          setCapturingBinding(isCapturing ? null : target.bindingID)
                        }
                        className="btn-ghost h-9 px-3 text-[12.5px] flex items-center gap-1.5 cursor-pointer"
                        style={
                          isCapturing
                            ? { borderColor: 'var(--accent)', color: 'var(--accent)' }
                            : undefined
                        }
                      >
                        {isCapturing ? (
                          <span className="font-mono-tabular">{t('common.pressKeys')}</span>
                        ) : combo ? (
                          <KeycapCombo combo={combo} />
                        ) : (
                          <span>{t('agents.setShortcut')}</span>
                        )}
                      </button>

                      <button
                        type="button"
                        onClick={() => setPairingTarget(target)}
                        className="btn-ghost h-9 w-9 flex items-center justify-center cursor-pointer"
                        style={{ color: 'var(--ink-secondary)' }}
                        title={t('agents.edit')}
                        aria-label={t('agents.edit')}
                      >
                        <SlidersHorizontal className="w-4 h-4" />
                      </button>

                      <button
                        type="button"
                        onClick={() => removeAgent(target.id)}
                        className="btn-ghost h-9 w-9 flex items-center justify-center cursor-pointer"
                        style={{ color: 'var(--status-err)' }}
                        title={t('agents.remove')}
                        aria-label={t('agents.remove')}
                      >
                        <Trash2 className="w-4 h-4" />
                      </button>
                    </div>
                  </div>
                );
              })}
            </div>
          )}

          <p className="text-[12.5px]" style={{ color: 'var(--ink-tertiary)' }}>
            {t('agents.footerHint')}
          </p>
        </section>
      </div>

      {pairingTarget && (
        <AgentPairingModal
          initialTarget={pairingTarget}
          onClose={() => setPairingTarget(null)}
          onPaired={(saved) => saveAgent(saved)}
          onRequestShortcut={(bindingID) => {
            setPairingTarget(null);
            setCapturingBinding(bindingID);
          }}
        />
      )}
    </div>
  );
};

interface AgentPairingModalProps {
  initialTarget: AgentTarget;
  onClose: () => void;
  onPaired: (target: AgentTarget) => void;
  onRequestShortcut: (bindingID: string) => void;
}

const AgentPairingModal: React.FC<AgentPairingModalProps> = ({
  initialTarget,
  onClose,
  onPaired,
  onRequestShortcut,
}) => {
  const [step, setStep] = useState<'pick' | 'prompt' | 'connected'>('pick');
  const [choice, setChoice] = useState<AgentChoice>(initialTarget.provider || 'Codex');
  const [sessionId] = useState(() =>
    typeof crypto !== 'undefined' && 'randomUUID' in crypto
      ? crypto.randomUUID()
      : `req-${Date.now()}`,
  );
  const [copied, setCopied] = useState(false);
  const [showFullPrompt, setShowFullPrompt] = useState(false);
  const [connectedTarget, setConnectedTarget] = useState<AgentTarget | null>(null);

  const promptText = `请按本机说明「~/Library/Application Support/com.talkwtf.app/agent-pairings/${sessionId}/CONNECT.md」将当前 ${choice} 会话连接到 TalkWTF。`;

  const copyPrompt = async () => {
    try {
      await navigator.clipboard.writeText(promptText);
    } catch {
      // ignore
    }
    setCopied(true);
  };

  const simulateAgentConfirmation = () => {
    const convUuid =
      typeof crypto !== 'undefined' && 'randomUUID' in crypto
        ? crypto.randomUUID()
        : `conv-${Date.now()}`;
    const target: AgentTarget = {
      id: initialTarget.id,
      name: initialTarget.name || `${choice} · 会话 ${convUuid.slice(0, 6)}`,
      kind: choice === 'Codex' ? 'codex' : 'http',
      provider: choice,
      address:
        choice === 'Codex' ? '/usr/local/bin/codex' : 'http://127.0.0.1:47821/talkwtf/inbox',
      conversation: convUuid,
      workingDirectory: '~/workspace/project',
      bindingID: initialTarget.bindingID,
    };
    onPaired(target);
    setConnectedTarget(target);
    setStep('connected');
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/55 backdrop-blur-[3px] p-4">
      <div
        className="w-full max-w-[540px] studio-panel p-7 shadow-2xl space-y-6"
        style={{ borderColor: 'var(--border-strong)' }}
      >
        {/* Step Progress Bar */}
        <div className="flex items-center justify-between gap-4">
          <div
            className="flex items-center gap-2 text-[12px] font-mono-tabular"
            style={{ color: 'var(--ink-secondary)' }}
          >
            <span style={{ color: step === 'pick' ? 'var(--accent)' : 'var(--ink-tertiary)' }}>
              01. 选择
            </span>
            <span aria-hidden="true">/</span>
            <span style={{ color: step === 'prompt' ? 'var(--accent)' : 'var(--ink-tertiary)' }}>
              02. 配对
            </span>
            <span aria-hidden="true">/</span>
            <span style={{ color: step === 'connected' ? 'var(--accent)' : 'var(--ink-tertiary)' }}>
              03. 热键
            </span>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="p-1.5 hover:bg-[var(--bg-hover)] cursor-pointer"
            style={{ color: 'var(--ink-secondary)' }}
            aria-label="Close modal"
          >
            <X className="w-4 h-4" />
          </button>
        </div>

        {step === 'pick' && (
          <>
            <div className="space-y-1.5">
              <h3 className="font-display text-[22px] font-semibold">你正在用哪个 Agent？</h3>
              <p className="text-[13.5px]" style={{ color: 'var(--ink-secondary)' }}>
                选好后，复制一句话发给它，就能开始连接当前会话。
              </p>
            </div>

            <div className="divide-y border-y" style={{ borderColor: 'var(--border-hairline)' }}>
              {AGENT_CHOICES.map((item) => {
                const selected = choice === item;
                return (
                  <button
                    key={item}
                    type="button"
                    onClick={() => setChoice(item)}
                    className="w-full flex items-center justify-between gap-3 px-3 py-3.5 text-left text-[14px] transition-colors cursor-pointer"
                    style={{
                      backgroundColor: selected ? 'var(--accent-soft)' : 'transparent',
                      borderColor: 'var(--border-hairline)',
                    }}
                  >
                    <span className="font-medium">{item}</span>
                    {selected && (
                      <CheckCircle2 className="w-4 h-4 shrink-0" style={{ color: 'var(--accent)' }} />
                    )}
                  </button>
                );
              })}
            </div>

            <p className="text-[12px]" style={{ color: 'var(--ink-tertiary)' }}>
              适用于能读取本机文件、执行命令的 Agent。仅网页聊天的客户端暂不支持。
            </p>

            <div className="flex items-center justify-between pt-1">
              <button
                type="button"
                onClick={onClose}
                className="btn-ghost h-10 px-4 text-[13px] cursor-pointer"
              >
                取消
              </button>
              <button
                type="button"
                onClick={() => setStep('prompt')}
                className="btn-accent h-10 px-5 text-[13px] cursor-pointer"
              >
                生成连接提示词
              </button>
            </div>
          </>
        )}

        {step === 'prompt' && (
          <>
            <div className="space-y-1.5">
              <h3 className="font-display text-[22px] font-semibold">把这句话发给 {choice}</h3>
              <p className="text-[13.5px]" style={{ color: 'var(--ink-secondary)' }}>
                粘贴到你想接收语音的会话，让 Agent 完成本地连接（10 分钟内有效）。
              </p>
            </div>

            <div className="studio-well p-4 space-y-1.5">
              <div className="text-[14.5px] font-semibold">
                请将当前 {choice} 会话连接到 TalkWTF。
              </div>
              <p className="text-[12.5px]" style={{ color: 'var(--ink-secondary)' }}>
                完整连接说明路径将随提示词一起复制。
              </p>
            </div>

            <div>
              <button
                type="button"
                onClick={() => setShowFullPrompt((v) => !v)}
                className="flex items-center gap-1 text-[12.5px] cursor-pointer"
                style={{ color: 'var(--ink-secondary)' }}
              >
                {showFullPrompt ? (
                  <ChevronDown className="w-3.5 h-3.5" />
                ) : (
                  <ChevronRight className="w-3.5 h-3.5" />
                )}
                查看完整提示词
              </button>
              {showFullPrompt && (
                <pre
                  className="mt-2 p-3.5 text-[11.5px] font-mono-tabular whitespace-pre-wrap break-all select-text studio-well"
                  style={{ color: 'var(--ink-secondary)' }}
                >
                  {promptText}
                </pre>
              )}
            </div>

            <button
              type="button"
              onClick={() => void copyPrompt()}
              className="btn-accent w-full h-11 text-[13.5px] flex items-center justify-center gap-2 cursor-pointer"
            >
              {copied ? <Check className="w-4 h-4" /> : <Copy className="w-4 h-4" />}
              <span>{copied ? '已复制，再复制一次' : '复制连接提示词'}</span>
            </button>

            <div className="flex items-center justify-between gap-2 text-[12.5px]">
              <div className="flex items-center gap-2" style={{ color: 'var(--ink-secondary)' }}>
                <Loader2 className="w-3.5 h-3.5 animate-spin" style={{ color: 'var(--accent)' }} />
                <span>{copied ? '发给 Agent 后，这里会自动确认连接。' : '等待 Agent 连接…'}</span>
              </div>
              <button
                type="button"
                onClick={simulateAgentConfirmation}
                className="font-medium hover:underline cursor-pointer"
                style={{ color: 'var(--accent)' }}
              >
                模拟回执完成配对
              </button>
            </div>

            <div className="flex items-center justify-between pt-1">
              <button
                type="button"
                onClick={() => {
                  setCopied(false);
                  setStep('pick');
                }}
                className="btn-ghost h-9 px-3.5 text-[13px] cursor-pointer"
              >
                重新选择
              </button>
              <button
                type="button"
                onClick={onClose}
                className="btn-ghost h-9 px-3.5 text-[13px] cursor-pointer"
              >
                取消
              </button>
            </div>
          </>
        )}

        {step === 'connected' && connectedTarget && (
          <>
            <CheckCircle2 className="w-9 h-9" style={{ color: 'var(--status-ok)' }} />
            <div className="space-y-1.5">
              <h3 className="font-display text-[22px] font-semibold">
                已连接 {connectedTarget.name}
              </h3>
              <p className="text-[13.5px]" style={{ color: 'var(--ink-secondary)' }}>
                最后，给这个会话设置一个快捷键。以后按键说话，就能直接发给它。
              </p>
            </div>
            <div className="flex justify-end gap-2">
              <button
                type="button"
                onClick={onClose}
                className="btn-ghost h-10 px-4 text-[13px] cursor-pointer"
              >
                稍后设置
              </button>
              <button
                type="button"
                onClick={() => onRequestShortcut(connectedTarget.bindingID)}
                className="btn-accent h-10 px-5 text-[13px] cursor-pointer"
              >
                设置快捷键
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  );
};
