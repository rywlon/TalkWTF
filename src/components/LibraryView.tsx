import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  ArrowRight,
  Check,
  Copy,
  Download,
  HardDrive,
  RefreshCw,
  RotateCcw,
  Search,
  Trash2,
  Upload,
  Wifi,
  WifiOff,
} from 'lucide-react';
import { formatBytes } from '../lib/audioVault';
import { formatDuration, formatRelativeTime } from '../lib/pipeline';
import { useAppStore } from '../store/AppStore';
import type {
  AgentTarget,
  CorrectionRule,
  DictionaryWord,
  LibraryTab,
  RecoveredRecording,
} from '../types';
import { TactileSwitch } from './ui/Controls';

interface LibraryViewProps {
  activeTab?: LibraryTab;
  onTabChange?: (tab: LibraryTab) => void;
}

export const LibraryView: React.FC<LibraryViewProps> = ({ activeTab, onTabChange }) => {
  const {
    settings,
    isOnline,
    history,
    deleteHistoryEntry,
    retranscribeHistoryEntry,
    recoveryVault,
    updateRecoveredTranscript,
    recoverRecordingItem,
    deleteRecoveredRecording,
    getRecoveredAudioBlob,
    agents,
    words,
    rules,
    rejections,
    addWord,
    updateWord,
    deleteWord,
    addRule,
    updateRule,
    toggleRule,
    deleteRule,
    forgetRejection,
    clearRejections,
    importDictionaryJson,
    exportDictionaryJson,
    t,
  } = useAppStore();

  const [localTab, setLocalTab] = useState<LibraryTab>(activeTab ?? 'history');
  const tab = activeTab ?? localTab;
  const setTab = (next: LibraryTab) => {
    setLocalTab(next);
    onTabChange?.(next);
  };

  const [query, setQuery] = useState('');
  const [sort, setSort] = useState<'newest' | 'oldest'>('newest');
  const [copiedId, setCopiedId] = useState<number | null>(null);

  const [newWord, setNewWord] = useState('');
  const [newPattern, setNewPattern] = useState('');
  const [newReplacement, setNewReplacement] = useState('');
  const [editingWord, setEditingWord] = useState<DictionaryWord | null>(null);
  const [editingRule, setEditingRule] = useState<CorrectionRule | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const fileInputRef = useRef<HTMLInputElement | null>(null);

  const pendingVault = useMemo(
    () => recoveryVault.filter((r) => r.status !== 'recording_draft'),
    [recoveryVault],
  );

  const filteredEntries = useMemo(() => {
    const needle = query.trim().toLowerCase();
    const matches = needle
      ? history.filter(
          (e) =>
            e.transcription.toLowerCase().includes(needle) ||
            (e.postProcessed ?? '').toLowerCase().includes(needle),
        )
      : history;
    return [...matches].sort((a, b) =>
      sort === 'newest' ? b.timestamp - a.timestamp : a.timestamp - b.timestamp,
    );
  }, [history, query, sort]);

  const handleCopy = async (id: number, text: string) => {
    try {
      await navigator.clipboard.writeText(text);
      setCopiedId(id);
      window.setTimeout(() => setCopiedId((cur) => (cur === id ? null : cur)), 1500);
    } catch {
      // ignore
    }
  };

  const handleExport = () => {
    const json = exportDictionaryJson();
    const blob = new Blob([json], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'talkwtf-dictionary.json';
    a.click();
    URL.revokeObjectURL(url);
    setNotice(
      settings.app_language === 'zh' ? '词典已导出为 JSON。' : 'Dictionary exported as JSON.',
    );
    setError(null);
  };

  const handleImportFile = async (event: React.ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    if (!file) return;
    try {
      const text = await file.text();
      const report = importDictionaryJson(text);
      setNotice(
        settings.app_language === 'zh'
          ? `已导入 ${report.accepted} 条，跳过重复 ${report.duplicates} 条，无效 ${report.invalid} 条。`
          : `Imported ${report.accepted}, skipped ${report.duplicates} duplicates, ${report.invalid} invalid.`,
      );
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Invalid JSON file');
    } finally {
      event.target.value = '';
    }
  };

  const handleRetryAllVault = () => {
    let recovered = 0;
    let skipped = 0;
    for (const item of pendingVault) {
      if (item.partialTranscript.trim()) {
        const res = recoverRecordingItem(item.id, item.partialTranscript);
        if (res.ok) recovered++;
        else skipped++;
      } else {
        skipped++;
      }
    }
    if (recovered > 0) {
      setNotice(
        settings.app_language === 'zh'
          ? `已重新识别并恢复 ${recovered} 条录音${skipped > 0 ? `，另有 ${skipped} 条需先回放补充文字` : ''}。`
          : `Recovered ${recovered} recording(s)${skipped > 0 ? `; ${skipped} need transcript text first` : ''}.`,
      );
      setError(null);
    } else if (skipped > 0) {
      setError(
        settings.app_language === 'zh'
          ? '待恢复录音暂无识别草稿，请先回放音频并补充文字后再恢复。'
          : 'No transcript draft on pending items yet — listen back and add text before recovering.',
      );
    }
  };

  return (
    <div className="h-full overflow-y-auto">
      <div className="max-w-[1160px] mx-auto px-6 lg:px-10 py-8 lg:py-10 space-y-8">
        {/* Header + Crisp Underline Tabs */}
        <div
          className="flex flex-wrap items-end justify-between gap-4 border-b pb-4"
          style={{ borderColor: 'var(--border-hairline)' }}
        >
          <div className="space-y-1">
            <h1 className="font-display text-[32px] font-semibold tracking-[-0.03em] leading-tight">
              {t('sidebar.library')}
            </h1>
            <p className="text-[14px]" style={{ color: 'var(--ink-secondary)' }}>
              {t('library.subtitle')}
            </p>
          </div>

          <div className="flex items-center gap-6 -mb-[17px]">
            {(['history', 'recovery', 'dictionary'] as const).map((item) => {
              const active = tab === item;
              const count =
                item === 'history'
                  ? history.length
                  : item === 'recovery'
                    ? pendingVault.length
                    : words.length + rules.length;
              return (
                <button
                  key={item}
                  type="button"
                  onClick={() => setTab(item)}
                  className="relative pb-4 text-[14px] font-medium flex items-center gap-2 transition-colors whitespace-nowrap cursor-pointer"
                  style={{
                    color: active ? 'var(--ink-primary)' : 'var(--ink-secondary)',
                  }}
                >
                  <span>
                    {item === 'history'
                      ? t('sidebar.history')
                      : item === 'recovery'
                        ? t('sidebar.recovery')
                        : t('sidebar.dictionary')}
                  </span>
                  <span
                    className="font-mono-tabular text-[12px]"
                    style={{
                      color:
                        item === 'recovery' && count > 0
                          ? 'var(--accent)'
                          : 'var(--ink-tertiary)',
                      fontWeight: item === 'recovery' && count > 0 ? 600 : 400,
                    }}
                  >
                    {count}
                  </span>
                  {active && (
                    <span
                      className="absolute left-0 right-0 bottom-0 h-[2px]"
                      style={{ backgroundColor: 'var(--accent)' }}
                    />
                  )}
                </button>
              );
            })}
          </div>
        </div>

        {error && (
          <div className="text-[13px]" style={{ color: 'var(--status-err)' }}>
            {error}
          </div>
        )}
        {notice && (
          <div className="text-[13px]" style={{ color: 'var(--ink-secondary)' }}>
            {notice}
          </div>
        )}

        {tab === 'history' ? (
          <div className="space-y-6 pb-8">
            {/* Architectural Underline Search */}
            <div className="flex flex-wrap items-center justify-between gap-4">
              <div
                className="flex items-center gap-2.5 flex-1 min-w-[220px] max-w-[380px] border-b transition-colors focus-within:border-[var(--accent)]"
                style={{ borderColor: 'var(--border-strong)' }}
              >
                <Search className="w-4 h-4 shrink-0" style={{ color: 'var(--ink-tertiary)' }} />
                <input
                  type="text"
                  value={query}
                  onChange={(e) => setQuery(e.target.value)}
                  placeholder={t('library.searchPlaceholder')}
                  className="w-full bg-transparent py-2 text-[13.5px] outline-none placeholder:text-[var(--ink-tertiary)]"
                  style={{ color: 'var(--ink-primary)' }}
                />
              </div>

              <select
                value={sort}
                onChange={(e) => setSort(e.target.value as 'newest' | 'oldest')}
                className="studio-select"
              >
                <option value="newest">{t('library.sort.newest')}</option>
                <option value="oldest">{t('library.sort.oldest')}</option>
              </select>
            </div>

            {filteredEntries.length === 0 ? (
              <div
                className="border-t py-14 text-center text-[14px]"
                style={{ borderColor: 'var(--border-hairline)', color: 'var(--ink-secondary)' }}
              >
                {query ? t('library.noMatches') : t('library.empty')}
              </div>
            ) : (
              <div
                className="border-y divide-y"
                style={{ borderColor: 'var(--border-hairline)' }}
              >
                {filteredEntries.map((entry) => {
                  const display = entry.postProcessed || entry.transcription;
                  const showRaw =
                    entry.postProcessed &&
                    entry.postProcessed.trim() !== entry.transcription.trim();

                  return (
                    <div
                      key={entry.id}
                      className="py-5 px-2 -mx-2 space-y-2.5 transition-colors hover:bg-[var(--bg-hover)]"
                      style={{ borderColor: 'var(--border-hairline)' }}
                    >
                      <div className="flex items-start justify-between gap-5">
                        <div className="space-y-1.5 min-w-0 flex-1">
                          <p className="text-[15px] leading-relaxed whitespace-pre-wrap select-text">
                            {display}
                          </p>
                          {showRaw && (
                            <p
                              className="text-[13px] leading-relaxed"
                              style={{ color: 'var(--ink-secondary)' }}
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
                            className="p-2 hover:bg-[var(--bg-active)] cursor-pointer"
                            title={t('common.copy')}
                            aria-label={t('common.copy')}
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
                            className="p-2 hover:bg-[var(--bg-active)] cursor-pointer"
                            title={settings.app_language === 'zh' ? '重新润色' : 'Re-polish'}
                            aria-label="Re-polish"
                          >
                            <RefreshCw className="w-4 h-4" />
                          </button>
                          <button
                            type="button"
                            onClick={() => deleteHistoryEntry(entry.id)}
                            className="p-2 hover:bg-[var(--bg-active)] cursor-pointer"
                            style={{ color: 'var(--status-err)' }}
                            title={t('common.delete')}
                            aria-label={t('common.delete')}
                          >
                            <Trash2 className="w-4 h-4" />
                          </button>
                        </div>
                      </div>

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
                        <span>{formatRelativeTime(entry.timestamp, settings.app_language)}</span>
                        {entry.durationMs > 0 && (
                          <>
                            <span aria-hidden="true">·</span>
                            <span className="font-mono-tabular">
                              {formatDuration(entry.durationMs)}
                            </span>
                          </>
                        )}
                      </div>
                    </div>
                  );
                })}
              </div>
            )}
          </div>
        ) : tab === 'recovery' ? (
          <div className="space-y-6 pb-10">
            {/* Black-Box Vault Status Header Strip */}
            <div
              className="flex flex-wrap items-center justify-between gap-4 pb-5 border-b"
              style={{ borderColor: 'var(--border-hairline)' }}
            >
              <div className="space-y-1 max-w-2xl">
                <div className="flex items-center gap-2.5 text-[12.5px] font-mono-tabular">
                  {isOnline ? (
                    <span
                      className="inline-flex items-center gap-1.5"
                      style={{ color: 'var(--status-ok)' }}
                    >
                      <Wifi className="w-3.5 h-3.5" />
                      <span>
                        {settings.app_language === 'zh'
                          ? '在线 · 可重新识别'
                          : 'ONLINE · READY TO RECOVER'}
                      </span>
                    </span>
                  ) : (
                    <span
                      className="inline-flex items-center gap-1.5"
                      style={{ color: 'var(--status-warn)' }}
                    >
                      <WifiOff className="w-3.5 h-3.5" />
                      <span>
                        {settings.app_language === 'zh'
                          ? '离线 · 音频已安全写入 IndexedDB'
                          : 'OFFLINE · AUDIO SAFELY STORED IN INDEXEDDB'}
                      </span>
                    </span>
                  )}
                  <span style={{ color: 'var(--ink-tertiary)' }}>·</span>
                  <span style={{ color: 'var(--ink-secondary)' }}>
                    {settings.app_language === 'zh'
                      ? `${pendingVault.length} 段待恢复`
                      : `${pendingVault.length} pending`}
                  </span>
                </div>
                <p className="text-[13.5px]" style={{ color: 'var(--ink-secondary)' }}>
                  {t('recovery.subtitle')}
                </p>
              </div>

              {pendingVault.length > 0 && (
                <button
                  type="button"
                  disabled={!isOnline}
                  onClick={handleRetryAllVault}
                  className="btn-accent h-9 px-4 text-[13px] flex items-center gap-1.5 cursor-pointer shrink-0"
                >
                  <RotateCcw className="w-3.5 h-3.5" />
                  <span>{t('recovery.retryAll')}</span>
                </button>
              )}
            </div>

            {pendingVault.length === 0 ? (
              <div className="py-16 text-center space-y-2.5">
                <HardDrive
                  className="w-6 h-6 mx-auto"
                  style={{ color: 'var(--ink-tertiary)' }}
                />
                <p className="text-[14px]" style={{ color: 'var(--ink-secondary)' }}>
                  {t('recovery.empty')}
                </p>
              </div>
            ) : (
              <div
                className="border-y divide-y"
                style={{ borderColor: 'var(--border-hairline)' }}
              >
                {pendingVault.map((item) => (
                  <RecoveryVaultRow
                    key={item.id}
                    item={item}
                    agents={agents}
                    isOnline={isOnline}
                    locale={settings.app_language}
                    t={t}
                    getAudioBlob={getRecoveredAudioBlob}
                    onTranscriptChange={(val) => updateRecoveredTranscript(item.id, val)}
                    onRecover={(text, agent) => {
                      const res = recoverRecordingItem(item.id, text, agent);
                      if (res.ok) {
                        setNotice(
                          settings.app_language === 'zh'
                            ? '录音已成功恢复并写入历史记录。'
                            : 'Recording recovered and saved to history.',
                        );
                        setError(null);
                      } else {
                        setError(
                          settings.app_language === 'zh'
                            ? '请先回放音频并在输入框中补充文字，再执行恢复。'
                            : 'Listen back and enter transcript text before recovering.',
                        );
                      }
                    }}
                    onDelete={() => deleteRecoveredRecording(item.id)}
                  />
                ))}
              </div>
            )}
          </div>
        ) : (
          <div className="grid grid-cols-1 lg:grid-cols-12 gap-10 pb-8">
            {/* Left 5 Cols: Custom Vocabulary + Rejections */}
            <div className="lg:col-span-5 space-y-10">
              <section className="space-y-4">
                <div className="flex items-center justify-between gap-2">
                  <h2
                    className="text-[13px] font-semibold tracking-wide"
                    style={{ color: 'var(--ink-secondary)' }}
                  >
                    {t('library.wordsTitle')}
                  </h2>
                  <div className="flex items-center gap-2">
                    <input
                      ref={fileInputRef}
                      type="file"
                      accept="application/json,.json"
                      onChange={(e) => void handleImportFile(e)}
                      className="hidden"
                    />
                    <button
                      type="button"
                      onClick={() => fileInputRef.current?.click()}
                      className="btn-ghost h-8 px-2.5 text-[12px] flex items-center gap-1.5 cursor-pointer"
                    >
                      <Upload className="w-3.5 h-3.5" />
                      <span>{t('library.import')}</span>
                    </button>
                    <button
                      type="button"
                      disabled={words.length === 0 && rules.length === 0}
                      onClick={handleExport}
                      className="btn-ghost h-8 px-2.5 text-[12px] flex items-center gap-1.5 cursor-pointer"
                    >
                      <Download className="w-3.5 h-3.5" />
                      <span>{t('library.export')}</span>
                    </button>
                  </div>
                </div>

                <form
                  onSubmit={(e) => {
                    e.preventDefault();
                    if (!newWord.trim()) return;
                    addWord(newWord);
                    setNewWord('');
                  }}
                  className="flex items-end gap-3"
                >
                  <input
                    type="text"
                    value={newWord}
                    onChange={(e) => setNewWord(e.target.value)}
                    placeholder={t('library.wordsPlaceholder')}
                    className="studio-input flex-1 min-w-0"
                  />
                  <button
                    type="submit"
                    disabled={!newWord.trim()}
                    className="btn-accent h-9 px-4 text-[13px] cursor-pointer"
                  >
                    {t('library.add')}
                  </button>
                </form>

                <div
                  className="border-t divide-y"
                  style={{ borderColor: 'var(--border-hairline)' }}
                >
                  {words.map((item) => (
                    <div
                      key={item.id}
                      className="flex items-center justify-between py-2.5 text-[14px]"
                      style={{ borderColor: 'var(--border-hairline)' }}
                    >
                      <span className="font-medium truncate pr-3">{item.word}</span>
                      <div className="flex items-center gap-3 text-[12.5px] shrink-0">
                        <button
                          type="button"
                          onClick={() => setEditingWord(item)}
                          className="hover:underline cursor-pointer"
                          style={{ color: 'var(--ink-secondary)' }}
                        >
                          {t('common.edit')}
                        </button>
                        <button
                          type="button"
                          onClick={() => deleteWord(item.id)}
                          className="hover:underline cursor-pointer"
                          style={{ color: 'var(--status-err)' }}
                        >
                          {t('common.delete')}
                        </button>
                      </div>
                    </div>
                  ))}
                </div>
              </section>

              {/* Rejections */}
              <section
                className="border-t pt-6 space-y-3"
                style={{ borderColor: 'var(--border-hairline)' }}
              >
                <div className="space-y-1">
                  <h2
                    className="text-[13px] font-semibold tracking-wide"
                    style={{ color: 'var(--ink-secondary)' }}
                  >
                    {t('library.rejectedTitle')}
                  </h2>
                  <p className="text-[12.5px]" style={{ color: 'var(--ink-secondary)' }}>
                    {t('library.rejectedDescription')}
                  </p>
                </div>

                {rejections.length > 0 ? (
                  <>
                    <div className="divide-y" style={{ borderColor: 'var(--border-hairline)' }}>
                      {rejections.map((pattern) => (
                        <div
                          key={pattern}
                          className="flex items-center justify-between py-2.5 text-[13.5px]"
                          style={{ borderColor: 'var(--border-hairline)' }}
                        >
                          <span>{pattern}</span>
                          <button
                            type="button"
                            onClick={() => forgetRejection(pattern)}
                            className="text-[12.5px] hover:underline cursor-pointer"
                            style={{ color: 'var(--accent)' }}
                          >
                            {t('library.rejectedRestore')}
                          </button>
                        </div>
                      ))}
                    </div>
                    <button
                      type="button"
                      onClick={clearRejections}
                      className="btn-ghost h-8 px-3 text-[12px] cursor-pointer"
                    >
                      {t('library.rejectedClear')}
                    </button>
                  </>
                ) : (
                  <p className="text-[12.5px]" style={{ color: 'var(--ink-tertiary)' }}>
                    {settings.app_language === 'zh' ? '当前名单为空。' : 'No excluded terms.'}
                  </p>
                )}
              </section>
            </div>

            {/* Right 7 Cols: Correction Rules */}
            <section
              className="lg:col-span-7 lg:border-l lg:pl-10 space-y-4 h-fit"
              style={{ borderColor: 'var(--border-hairline)' }}
            >
              <div className="flex items-center justify-between">
                <h2
                  className="text-[13px] font-semibold tracking-wide"
                  style={{ color: 'var(--ink-secondary)' }}
                >
                  {t('library.rulesTitle')}
                </h2>
                <span
                  className="font-mono-tabular text-[12px]"
                  style={{ color: 'var(--ink-tertiary)' }}
                >
                  {rules.filter((r) => r.enabled).length} / {rules.length}
                </span>
              </div>

              <form
                onSubmit={(e) => {
                  e.preventDefault();
                  if (!newPattern.trim() || !newReplacement.trim()) return;
                  addRule(newPattern, newReplacement, 'manual');
                  setNewPattern('');
                  setNewReplacement('');
                }}
                className="flex flex-wrap items-end gap-3"
              >
                <input
                  type="text"
                  value={newPattern}
                  onChange={(e) => setNewPattern(e.target.value)}
                  placeholder={t('library.patternPlaceholder')}
                  className="studio-input flex-1 min-w-[140px]"
                />
                <ArrowRight
                  className="w-4 h-4 shrink-0 mb-2"
                  style={{ color: 'var(--ink-tertiary)' }}
                />
                <input
                  type="text"
                  value={newReplacement}
                  onChange={(e) => setNewReplacement(e.target.value)}
                  placeholder={t('library.replacementPlaceholder')}
                  className="studio-input flex-1 min-w-[140px]"
                />
                <button
                  type="submit"
                  disabled={!newPattern.trim() || !newReplacement.trim()}
                  className="btn-accent h-9 px-4 text-[13px] cursor-pointer"
                >
                  {t('library.add')}
                </button>
              </form>

              <div className="border-t divide-y" style={{ borderColor: 'var(--border-hairline)' }}>
                {rules.map((rule) => (
                  <div
                    key={rule.id}
                    className="flex items-center gap-3.5 py-3 text-[14px]"
                    style={{ borderColor: 'var(--border-hairline)' }}
                  >
                    <TactileSwitch
                      size="sm"
                      checked={rule.enabled}
                      onChange={(next) => toggleRule(rule.id, next)}
                      ariaLabel={`Toggle rule ${rule.pattern}`}
                    />
                    <div className="flex items-center gap-2 min-w-0 flex-1">
                      <span
                        className="truncate"
                        style={{
                          color: rule.enabled ? 'var(--ink-secondary)' : 'var(--ink-tertiary)',
                        }}
                      >
                        {rule.pattern}
                      </span>
                      <ArrowRight
                        className="w-3.5 h-3.5 shrink-0"
                        style={{ color: 'var(--ink-tertiary)' }}
                      />
                      <span className="font-medium truncate">{rule.replacement}</span>
                      {rule.source === 'learned' && (
                        <span
                          className="text-[11.5px] shrink-0"
                          style={{ color: 'var(--ink-tertiary)' }}
                        >
                          · {settings.app_language === 'zh' ? '自动学词' : 'Auto-learned'}
                        </span>
                      )}
                    </div>

                    <div className="flex items-center gap-3 text-[12.5px] shrink-0">
                      <button
                        type="button"
                        onClick={() => setEditingRule(rule)}
                        className="hover:underline cursor-pointer"
                        style={{ color: 'var(--ink-secondary)' }}
                      >
                        {t('common.edit')}
                      </button>
                      <button
                        type="button"
                        onClick={() => deleteRule(rule.id)}
                        className="hover:underline cursor-pointer"
                        style={{ color: 'var(--status-err)' }}
                      >
                        {t('common.delete')}
                      </button>
                    </div>
                  </div>
                ))}
              </div>
            </section>
          </div>
        )}
      </div>

      {editingWord && (
        <WordEditModal
          initialWord={editingWord.word}
          onClose={() => setEditingWord(null)}
          onSave={(val) => {
            updateWord(editingWord.id, val);
            setEditingWord(null);
          }}
        />
      )}

      {editingRule && (
        <RuleEditModal
          rule={editingRule}
          onClose={() => setEditingRule(null)}
          onSave={(pattern, replacement) => {
            updateRule(editingRule.id, pattern, replacement);
            setEditingRule(null);
          }}
        />
      )}
    </div>
  );
};

const RecoveryVaultRow: React.FC<{
  item: RecoveredRecording;
  agents: AgentTarget[];
  isOnline: boolean;
  locale: 'zh' | 'en';
  t: (key: string, params?: Record<string, string | number>) => string;
  getAudioBlob: (id: string) => Promise<Blob | null>;
  onTranscriptChange: (val: string) => void;
  onRecover: (transcript: string, overrideAgent?: AgentTarget | null) => void;
  onDelete: () => void;
}> = ({
  item,
  agents,
  isOnline,
  locale,
  t,
  getAudioBlob,
  onTranscriptChange,
  onRecover,
  onDelete,
}) => {
  const [audioUrl, setAudioUrl] = useState<string | null>(null);
  const [audioBlob, setAudioBlob] = useState<Blob | null>(null);
  const [selectedAgentId, setSelectedAgentId] = useState<string>(item.targetAgentId ?? '');

  useEffect(() => {
    let active = true;
    let createdUrl: string | null = null;
    if (item.hasAudioBlob) {
      void getAudioBlob(item.id).then((blob) => {
        if (!active || !blob) return;
        setAudioBlob(blob);
        createdUrl = URL.createObjectURL(blob);
        setAudioUrl(createdUrl);
      });
    }
    return () => {
      active = false;
      if (createdUrl) URL.revokeObjectURL(createdUrl);
    };
  }, [getAudioBlob, item.hasAudioBlob, item.id]);

  const handleDownloadAudio = () => {
    if (!audioBlob) return;
    const ext = item.mimeType.includes('wav')
      ? 'wav'
      : item.mimeType.includes('mp4')
        ? 'm4a'
        : item.mimeType.includes('ogg')
          ? 'ogg'
          : 'webm';
    const url = URL.createObjectURL(audioBlob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `talkwtf-rescued-${item.id}.${ext}`;
    a.click();
    URL.revokeObjectURL(url);
  };

  const isAgentFlow = item.workflow === 'agent' || item.workflow === 'agent_auto';
  const overrideAgent = agents.find((a) => a.id === selectedAgentId) ?? null;

  return (
    <div className="py-6 space-y-4" style={{ borderColor: 'var(--border-hairline)' }}>
      {/* Meta Line */}
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex flex-wrap items-center gap-2 text-[12.5px]">
          <span
            className="font-semibold"
            style={{
              color:
                item.status === 'offline_pending' ? 'var(--status-warn)' : 'var(--accent)',
            }}
          >
            {t(`recovery.status.${item.status}`)}
          </span>
          <span style={{ color: 'var(--ink-tertiary)' }}>·</span>
          <span style={{ color: 'var(--ink-secondary)' }}>
            {t(`dashboard.workflow.${item.workflow}`)}
            {item.targetName ? ` (${item.targetName})` : ''}
          </span>
          <span style={{ color: 'var(--ink-tertiary)' }}>·</span>
          <span className="font-mono-tabular" style={{ color: 'var(--ink-secondary)' }}>
            {formatDuration(item.durationMs)}
          </span>
          {item.sizeBytes > 0 && (
            <>
              <span style={{ color: 'var(--ink-tertiary)' }}>·</span>
              <span className="font-mono-tabular" style={{ color: 'var(--ink-tertiary)' }}>
                {formatBytes(item.sizeBytes)}
              </span>
            </>
          )}
          <span style={{ color: 'var(--ink-tertiary)' }}>·</span>
          <span style={{ color: 'var(--ink-tertiary)' }}>
            {formatRelativeTime(Math.floor(item.createdAt / 1000), locale)}
          </span>
        </div>

        <button
          type="button"
          onClick={onDelete}
          className="text-[12px] flex items-center gap-1 hover:underline cursor-pointer"
          style={{ color: 'var(--status-err)' }}
        >
          <Trash2 className="w-3.5 h-3.5" />
          <span>{t('common.delete')}</span>
        </button>
      </div>

      {item.failureReason && (
        <p className="text-[12.5px]" style={{ color: 'var(--ink-secondary)' }}>
          {item.failureReason}
        </p>
      )}

      {/* Real Rescued Audio Playback */}
      {audioUrl && (
        <div className="max-w-[520px]">
          <audio controls src={audioUrl} className="w-full h-9" />
        </div>
      )}

      {/* Editable Rescued Transcript */}
      <div className="space-y-1.5">
        <label className="text-[12px] font-medium" style={{ color: 'var(--ink-secondary)' }}>
          {locale === 'zh'
            ? '保留的口语草稿（可边听回放边补充/修正，然后一键恢复）'
            : 'Saved Transcript Draft (listen back to refine before recovery)'}
        </label>
        <textarea
          value={item.partialTranscript}
          onChange={(e) => onTranscriptChange(e.target.value)}
          rows={2}
          placeholder={
            locale === 'zh'
              ? '原录音未产生识别文字，请回放音频后在此补充内容…'
              : 'No text captured yet — play the rescued audio and enter text here…'
          }
          className="studio-textarea w-full resize-none leading-relaxed"
        />
      </div>

      {/* Recovery Actions */}
      <div className="flex flex-wrap items-center justify-between gap-3 pt-1">
        <div className="flex flex-wrap items-center gap-2.5">
          {isAgentFlow && agents.length > 0 && (
            <select
              value={selectedAgentId}
              onChange={(e) => setSelectedAgentId(e.target.value)}
              className="studio-select"
            >
              <option value="">
                {locale === 'zh' ? '自动路由给最合适的 Agent' : 'Auto-Route to Best Agent'}
              </option>
              {agents.map((a) => (
                <option key={a.id} value={a.id}>
                  {a.name}
                </option>
              ))}
            </select>
          )}

          {audioBlob && (
            <button
              type="button"
              onClick={handleDownloadAudio}
              className="btn-ghost h-9 px-3 text-[12.5px] flex items-center gap-1.5 cursor-pointer"
            >
              <Download className="w-3.5 h-3.5" />
              <span>{t('recovery.download')}</span>
            </button>
          )}
        </div>

        <button
          type="button"
          disabled={!item.partialTranscript.trim() || !isOnline}
          onClick={() => onRecover(item.partialTranscript, overrideAgent)}
          className="btn-accent h-9 px-4 text-[13px] flex items-center gap-1.5 cursor-pointer"
        >
          <RotateCcw className="w-3.5 h-3.5" />
          <span>
            {isAgentFlow
              ? locale === 'zh'
                ? '恢复并发送给 Agent'
                : 'Recover & Dispatch to Agent'
              : t('recovery.retryOne')}
          </span>
        </button>
      </div>
    </div>
  );
};

const WordEditModal: React.FC<{
  initialWord: string;
  onClose: () => void;
  onSave: (val: string) => void;
}> = ({ initialWord, onClose, onSave }) => {
  const { t } = useAppStore();
  const [val, setVal] = useState(initialWord);
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 backdrop-blur-[3px] p-4">
      <div className="w-full max-w-[380px] studio-panel p-6 shadow-2xl space-y-5">
        <h3 className="font-display text-[18px] font-semibold">{t('library.wordsTitle')}</h3>
        <input
          type="text"
          value={val}
          onChange={(e) => setVal(e.target.value)}
          className="studio-input w-full"
          autoFocus
        />
        <div className="flex justify-end gap-2">
          <button
            type="button"
            onClick={onClose}
            className="btn-ghost h-9 px-3.5 text-[13px] cursor-pointer"
          >
            {t('common.cancel')}
          </button>
          <button
            type="button"
            disabled={!val.trim()}
            onClick={() => onSave(val)}
            className="btn-accent h-9 px-4 text-[13px] cursor-pointer"
          >
            {t('common.save')}
          </button>
        </div>
      </div>
    </div>
  );
};

const RuleEditModal: React.FC<{
  rule: CorrectionRule;
  onClose: () => void;
  onSave: (pattern: string, replacement: string) => void;
}> = ({ rule, onClose, onSave }) => {
  const { t } = useAppStore();
  const [pattern, setPattern] = useState(rule.pattern);
  const [replacement, setReplacement] = useState(rule.replacement);
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 backdrop-blur-[3px] p-4">
      <div className="w-full max-w-[440px] studio-panel p-6 shadow-2xl space-y-5">
        <h3 className="font-display text-[18px] font-semibold">{t('library.rulesTitle')}</h3>
        <div className="space-y-4">
          <input
            type="text"
            value={pattern}
            onChange={(e) => setPattern(e.target.value)}
            placeholder={t('library.patternPlaceholder')}
            className="studio-input w-full"
          />
          <input
            type="text"
            value={replacement}
            onChange={(e) => setReplacement(e.target.value)}
            placeholder={t('library.replacementPlaceholder')}
            className="studio-input w-full"
          />
        </div>
        <div className="flex justify-end gap-2 pt-1">
          <button
            type="button"
            onClick={onClose}
            className="btn-ghost h-9 px-3.5 text-[13px] cursor-pointer"
          >
            {t('common.cancel')}
          </button>
          <button
            type="button"
            disabled={!pattern.trim() || !replacement.trim()}
            onClick={() => onSave(pattern, replacement)}
            className="btn-accent h-9 px-4 text-[13px] cursor-pointer"
          >
            {t('common.save')}
          </button>
        </div>
      </div>
    </div>
  );
};
