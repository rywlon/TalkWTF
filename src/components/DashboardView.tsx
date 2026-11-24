import React, { useMemo, useState } from 'react';
import {
  ArrowRight,
  ArrowUpRight,
  Check,
  ChevronDown,
  ChevronUp,
  Copy,
  Languages,
  Mic,
  RefreshCw,
} from 'lucide-react';
import { POLISH_STYLES } from '../data/defaults';
import { formatDuration, formatRelativeTime } from '../lib/pipeline';
import { useAppStore } from '../store/AppStore';
import type { SettingsPane } from '../types';
import { AcousticCanvas, KeycapCombo, ResilientImage } from './ui/Controls';

const STUDIO_MIC_IMG = '/src/assets/images/studio_acoustic_mic_1795522819279.jpg';

interface DashboardViewProps {
  onOpenAgents: () => void;
  onOpenLibrary: () => void;
  onOpenSettingsPane: (pane: SettingsPane) => void;
}

export const DashboardView: React.FC<DashboardViewProps> = ({
  onOpenAgents,
  onOpenLibrary,
  onOpenSettingsPane,
}) => {
  const {
    settings,
    history,
    models,
    agents,
    levels,
    overlay,
    openDictation,
    retranscribeHistoryEntry,
    t,
  } = useAppStore();

  const [copiedId, setCopiedId] = useState<number | null>(null);
  const [expandedId, setExpandedId] = useState<number | null>(null);

  const stats = useMemo(() => {
    const startOfToday = new Date();
    startOfToday.setHours(0, 0, 0, 0);
    const startSec = Math.floor(startOfToday.getTime() / 1000);

    const todayEntries = history.filter((e) => e.timestamp >= startSec);
    const recordings = todayEntries.length;
    const chars = todayEntries.reduce((sum, e) => sum + e.charCount, 0);
    const translations = todayEntries.filter((e) => e.workflow === 'translate').length;
    const dictationMs = todayEntries.reduce((sum, e) => sum + e.durationMs, 0);

    const activeModel = models.find((m) => m.id === settings.selected_model);
    const activeProvider = settings.post_process_providers.find(
      (p) => p.id === settings.post_process_provider_id,
    );
    const activeScene = settings.scenes.find((s) => s.id === settings.active_scene_id);
    const activeStyle = POLISH_STYLES.find((s) => s.value === settings.polish_style);

    return {
      recordings,
      chars,
      translations,
      dictationMs,
      recent: history.slice(0, 6),
      asrModel: activeModel?.name ?? 'Qwen3-ASR 0.6B',
      asrReady: Boolean(activeModel?.isDownloaded),
      llmProvider: activeProvider?.label ?? t('dashboard.services.none'),
      polishModeLabel: activeScene
        ? activeScene.name
        : activeStyle?.label ?? settings.polish_style,
      primaryAgent: agents[0] ?? null,
    };
  }, [
    agents,
    history,
    models,
    settings.active_scene_id,
    settings.polish_style,
    settings.post_process_provider_id,
    settings.post_process_providers,
    settings.scenes,
    settings.selected_model,
    t,
  ]);

  const isLiveRecording = overlay.type === 'recording' || overlay.type === 'streaming';
  const dictationShortcut = settings.bindings.transcribe?.current_binding || 'Alt+Space';
  const translateShortcut = settings.bindings.translate?.current_binding || 'Alt+Shift+Space';

  const handleCopy = async (id: number, text: string) => {
    try {
      await navigator.clipboard.writeText(text);
      setCopiedId(id);
      window.setTimeout(() => setCopiedId((cur) => (cur === id ? null : cur)), 1500);
    } catch {
      // ignore
    }
  };

  return (
    <div className="h-full overflow-y-auto">
      <div className="max-w-[1160px] mx-auto px-6 lg:px-10 py-8 lg:py-10 space-y-12">
        {/* Open-Canvas Asymmetric Editorial Stage (No Heavy Rounded Cards) */}
        <section className="grid grid-cols-1 lg:grid-cols-12 gap-8 lg:gap-10 items-stretch">
          {/* Left 7 Cols: Direct-on-Canvas Typography + Hairline-Ruled Acoustic Strip */}
          <div className="lg:col-span-7 flex flex-col justify-between gap-7 py-1">
            <div className="space-y-4">
              <div
                className="flex flex-wrap items-center gap-2 text-[12.5px] font-mono-tabular"
                style={{ color: 'var(--ink-secondary)' }}
              >
                <span>{stats.asrModel}</span>
                <span aria-hidden="true">/</span>
                <span>{stats.polishModeLabel}</span>
                <span aria-hidden="true">/</span>
                <span>
                  {settings.app_language === 'zh'
                    ? `${agents.length} Agent`
                    : `${agents.length} Agents`}
                </span>
              </div>

              <h1
                className="font-display headline-balance font-semibold tracking-[-0.035em] leading-[1.06]"
                style={{ fontSize: 'clamp(2.25rem, 3.6vw, 3.25rem)' }}
              >
                {t('dashboard.heroTitle')}
              </h1>

              <p
                className="text-[15px] leading-relaxed max-w-[52ch]"
                style={{ color: 'var(--ink-secondary)' }}
              >
                {t('dashboard.heroSubtitle')}
              </p>
            </div>

            {/* Open Hairline-Ruled Acoustic Oscilloscope Strip */}
            <div
              onClick={() => openDictation('dictation')}
              role="button"
              tabIndex={0}
              onKeyDown={(e) => {
                if (e.key === 'Enter' || e.key === ' ') {
                  e.preventDefault();
                  openDictation('dictation');
                }
              }}
              className="border-y py-4 cursor-pointer group transition-colors duration-150 hover:bg-[var(--bg-hover)] px-1"
              style={{ borderColor: 'var(--border-hairline)' }}
              aria-label={t('dashboard.startDictation')}
            >
              <div className="flex items-center justify-between mb-2 text-[12px]">
                <span style={{ color: 'var(--ink-secondary)' }}>
                  {isLiveRecording
                    ? settings.app_language === 'zh'
                      ? '正在聆听麦克风信号'
                      : 'Capturing microphone signal'
                    : settings.app_language === 'zh'
                      ? '点击声波或按快捷键立即开始听写'
                      : 'Click waveform or press shortcut to dictate'}
                </span>
                <KeycapCombo combo={dictationShortcut} muted />
              </div>
              <AcousticCanvas levels={levels} active={isLiveRecording} height={62} barCount={48} />
            </div>

            {/* Primary CTA + Crisp Secondary Actions */}
            <div className="flex flex-wrap items-center gap-3">
              <button
                type="button"
                onClick={() => openDictation('dictation')}
                className="btn-accent h-11 px-6 text-[14px] flex items-center gap-2.5 cursor-pointer"
              >
                <Mic className="w-4 h-4 shrink-0" />
                <span>{t('dashboard.startDictation')}</span>
              </button>

              <button
                type="button"
                onClick={() => openDictation('translate')}
                className="btn-ghost h-11 px-4 text-[13.5px] flex items-center gap-2 cursor-pointer"
              >
                <Languages className="w-4 h-4 shrink-0" style={{ color: 'var(--ink-secondary)' }} />
                <span>{t('dashboard.startTranslate')}</span>
                <span className="hidden sm:inline-flex ml-1">
                  <KeycapCombo combo={translateShortcut} muted />
                </span>
              </button>

              {stats.primaryAgent ? (
                <button
                  type="button"
                  onClick={() => openDictation('agent', stats.primaryAgent)}
                  className="btn-ghost h-11 px-4 text-[13.5px] flex items-center gap-2 cursor-pointer"
                >
                  <ArrowUpRight className="w-4 h-4 shrink-0" style={{ color: 'var(--accent)' }} />
                  <span className="truncate max-w-[150px]">{stats.primaryAgent.name}</span>
                </button>
              ) : (
                <button
                  type="button"
                  onClick={onOpenAgents}
                  className="btn-ghost h-11 px-4 text-[13.5px] flex items-center gap-2 cursor-pointer"
                >
                  <ArrowUpRight className="w-4 h-4 shrink-0" />
                  <span>{t('dashboard.addAgent')}</span>
                </button>
              )}
            </div>
          </div>

          {/* Right 5 Cols: Sharp-Edged Editorial Studio Photography + Signal Chain */}
          <div
            className="lg:col-span-5 relative overflow-hidden border min-h-[340px] flex flex-col justify-end"
            style={{ borderColor: 'var(--border-hairline)', backgroundColor: '#111214' }}
          >
            <ResilientImage
              src={STUDIO_MIC_IMG}
              alt="Anodized aluminum studio condenser microphone with vermilion ring"
              className="absolute inset-0 w-full h-full object-cover"
              fallbackLabel="TalkWTF Acoustic Engine"
            />
            <div
              className="absolute inset-0"
              style={{
                background:
                  'linear-gradient(to top, rgba(11,12,14,0.96) 0%, rgba(11,12,14,0.7) 48%, rgba(11,12,14,0.16) 100%)',
              }}
            />

            <div className="relative z-10 p-6 space-y-4 text-[#f2f3f5]">
              <div className="flex items-center justify-between">
                <span className="text-[12px] font-medium text-white/65">
                  {settings.app_language === 'zh' ? '当前语音链路' : 'Active Signal Chain'}
                </span>
                <span className="font-mono-tabular text-[11px] text-white/55">
                  {stats.asrReady
                    ? settings.app_language === 'zh'
                      ? 'LOCAL READY'
                      : 'LOCAL READY'
                    : settings.app_language === 'zh'
                      ? 'PENDING'
                      : 'PENDING'}
                </span>
              </div>

              <div className="divide-y divide-white/12 border-t border-white/12">
                <button
                  type="button"
                  onClick={() => onOpenSettingsPane('models')}
                  className="w-full py-3 flex items-center justify-between gap-3 text-left group cursor-pointer"
                >
                  <div className="min-w-0">
                    <div className="text-[11.5px] text-white/55">{t('dashboard.services.asr')}</div>
                    <div className="text-[14px] font-medium truncate text-white">
                      {stats.asrModel}
                    </div>
                  </div>
                  <ArrowRight className="w-4 h-4 shrink-0 text-white/45 group-hover:text-white group-hover:translate-x-0.5 transition-all" />
                </button>

                <button
                  type="button"
                  onClick={() => onOpenSettingsPane('personalization')}
                  className="w-full py-3 flex items-center justify-between gap-3 text-left group cursor-pointer"
                >
                  <div className="min-w-0">
                    <div className="text-[11.5px] text-white/55">{t('dashboard.services.llm')}</div>
                    <div className="text-[14px] font-medium truncate text-white">
                      {stats.llmProvider} · {stats.polishModeLabel}
                    </div>
                  </div>
                  <ArrowRight className="w-4 h-4 shrink-0 text-white/45 group-hover:text-white group-hover:translate-x-0.5 transition-all" />
                </button>

                <button
                  type="button"
                  onClick={onOpenAgents}
                  className="w-full pt-3 pb-1 flex items-center justify-between gap-3 text-left group cursor-pointer"
                >
                  <div className="min-w-0">
                    <div className="text-[11.5px] text-white/55">Voice to Agent</div>
                    <div className="text-[14px] font-medium truncate text-white">
                      {stats.primaryAgent
                        ? stats.primaryAgent.name
                        : settings.app_language === 'zh'
                          ? '点击配对你的本地 Agent'
                          : 'Pair a local Agent'}
                    </div>
                  </div>
                  <ArrowRight className="w-4 h-4 shrink-0 text-white/45 group-hover:text-white group-hover:translate-x-0.5 transition-all" />
                </button>
              </div>
            </div>
          </div>
        </section>

        {/* Open Swiss Hairline-Ruled 4-Column Metric Strip (Zero Outer Box) */}
        <section className="space-y-4">
          <div className="flex items-center justify-between">
            <h2 className="text-[12.5px] font-semibold tracking-wide" style={{ color: 'var(--ink-secondary)' }}>
              {t('dashboard.today.title')}
            </h2>
            <span className="text-[12px] font-mono-tabular" style={{ color: 'var(--ink-tertiary)' }}>
              {new Date().toLocaleDateString(settings.app_language === 'zh' ? 'zh-CN' : 'en-US', {
                month: 'short',
                day: 'numeric',
              })}
            </span>
          </div>

          <div
            className="grid grid-cols-2 md:grid-cols-4 border-y"
            style={{ borderColor: 'var(--border-hairline)' }}
          >
            {[
              {
                label: t('dashboard.today.recordings'),
                value: String(stats.recordings),
                unit: settings.app_language === 'zh' ? '次' : 'runs',
              },
              {
                label: t('dashboard.today.chars'),
                value: stats.chars.toLocaleString(),
                unit: settings.app_language === 'zh' ? '字符' : 'chars',
              },
              {
                label: t('dashboard.today.translations'),
                value: String(stats.translations),
                unit: settings.app_language === 'zh' ? '次' : 'runs',
              },
              {
                label: t('dashboard.today.dictationTime'),
                value: formatDuration(stats.dictationMs),
                unit: settings.app_language === 'zh' ? '语音' : 'audio',
              },
            ].map((item, idx) => (
              <div
                key={item.label}
                className="py-6 px-5 first:pl-0 flex flex-col gap-2"
                style={{
                  borderLeft: idx > 0 ? '1px solid var(--border-hairline)' : undefined,
                }}
              >
                <span className="text-[12.5px]" style={{ color: 'var(--ink-secondary)' }}>
                  {item.label}
                </span>
                <div className="flex items-baseline gap-2">
                  <span className="font-display text-[34px] font-semibold leading-none tracking-[-0.03em] tabular-nums">
                    {item.value}
                  </span>
                  <span
                    className="text-[12px] font-mono-tabular"
                    style={{ color: 'var(--ink-tertiary)' }}
                  >
                    {item.unit}
                  </span>
                </div>
              </div>
            ))}
          </div>
        </section>

        {/* Open Editorial Recent Activity Ledger */}
        <section className="space-y-3 pb-8">
          <div className="flex items-center justify-between gap-4">
            <h2 className="text-[12.5px] font-semibold tracking-wide" style={{ color: 'var(--ink-secondary)' }}>
              {t('dashboard.recent.title')}
            </h2>
            <button
              type="button"
              onClick={onOpenLibrary}
              className="text-[12.5px] font-medium flex items-center gap-1 hover:underline cursor-pointer"
              style={{ color: 'var(--accent)' }}
            >
              <span>{settings.app_language === 'zh' ? '查看全部资料库' : 'Open full library'}</span>
              <ArrowRight className="w-3.5 h-3.5" />
            </button>
          </div>

          <div className="border-t" style={{ borderColor: 'var(--border-hairline)' }}>
            {stats.recent.length === 0 ? (
              <div className="py-12 text-center space-y-3">
                <p className="text-[14px]" style={{ color: 'var(--ink-secondary)' }}>
                  {t('dashboard.recent.empty')}
                </p>
                <button
                  type="button"
                  onClick={() => openDictation('dictation')}
                  className="btn-accent h-9 px-4 text-[13px] cursor-pointer"
                >
                  {t('dashboard.startDictation')}
                </button>
              </div>
            ) : (
              <div className="divide-y" style={{ borderColor: 'var(--border-hairline)' }}>
                {stats.recent.map((entry) => {
                  const display = entry.postProcessed ?? entry.transcription;
                  const hasDiff =
                    Boolean(entry.postProcessed) &&
                    entry.postProcessed?.trim() !== entry.transcription.trim();
                  const isExpanded = expandedId === entry.id;

                  return (
                    <div
                      key={entry.id}
                      className="py-4 px-2 -mx-2 transition-colors duration-150 hover:bg-[var(--bg-hover)]"
                      style={{ borderColor: 'var(--border-hairline)' }}
                    >
                      <div className="flex items-start justify-between gap-4">
                        <div className="min-w-0 flex-1 space-y-1.5">
                          <p className="text-[14.5px] leading-relaxed whitespace-pre-wrap select-text">
                            {display}
                          </p>
                          <div
                            className="flex flex-wrap items-center gap-2 text-[12px]"
                            style={{ color: 'var(--ink-tertiary)' }}
                          >
                            <span style={{ color: 'var(--ink-secondary)' }}>
                              {t(`dashboard.workflow.${entry.workflow}`)}
                            </span>
                            {entry.targetLabel && (
                              <>
                                <span aria-hidden="true">·</span>
                                <span>{entry.targetLabel}</span>
                              </>
                            )}
                            <span aria-hidden="true">·</span>
                            <span className="font-mono-tabular">
                              {t('dashboard.recent.chars', { count: entry.charCount })}
                            </span>
                            <span aria-hidden="true">·</span>
                            <span className="font-mono-tabular">
                              {formatDuration(entry.durationMs)}
                            </span>
                            <span aria-hidden="true">·</span>
                            <span>{formatRelativeTime(entry.timestamp, settings.app_language)}</span>
                            {hasDiff && (
                              <>
                                <span aria-hidden="true">·</span>
                                <button
                                  type="button"
                                  onClick={() => setExpandedId(isExpanded ? null : entry.id)}
                                  className="inline-flex items-center gap-0.5 hover:underline cursor-pointer"
                                  style={{ color: 'var(--ink-secondary)' }}
                                >
                                  <span>
                                    {settings.app_language === 'zh' ? '原始转写' : 'Raw transcript'}
                                  </span>
                                  {isExpanded ? (
                                    <ChevronUp className="w-3.5 h-3.5" />
                                  ) : (
                                    <ChevronDown className="w-3.5 h-3.5" />
                                  )}
                                </button>
                              </>
                            )}
                          </div>

                          {isExpanded && hasDiff && (
                            <p
                              className="mt-2 pt-2 border-t text-[13px] leading-relaxed"
                              style={{
                                borderColor: 'var(--border-hairline)',
                                color: 'var(--ink-secondary)',
                              }}
                            >
                              {entry.transcription}
                            </p>
                          )}
                        </div>

                        <div
                          className="flex items-center gap-1 shrink-0"
                          style={{ color: 'var(--ink-secondary)' }}
                        >
                          <button
                            type="button"
                            onClick={() => void handleCopy(entry.id, display)}
                            className="p-2 hover:bg-[var(--bg-active)] cursor-pointer transition-colors"
                            aria-label={t('common.copy')}
                            title={t('common.copy')}
                          >
                            {copiedId === entry.id ? (
                              <Check className="w-4 h-4" style={{ color: 'var(--status-ok)' }} />
                            ) : (
                              <Copy className="w-4 h-4" />
                            )}
                          </button>
                          <button
                            type="button"
                            onClick={() => retranscribeHistoryEntry(entry.id)}
                            className="p-2 hover:bg-[var(--bg-active)] cursor-pointer transition-colors"
                            aria-label="Re-polish"
                            title={settings.app_language === 'zh' ? '重新润色' : 'Re-polish'}
                          >
                            <RefreshCw className="w-4 h-4" />
                          </button>
                        </div>
                      </div>
                    </div>
                  );
                })}
              </div>
            )}
          </div>
        </section>
      </div>
    </div>
  );
};
