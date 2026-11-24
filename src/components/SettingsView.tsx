import React, { useEffect, useState } from 'react';
import { RotateCcw } from 'lucide-react';
import { RECOGNITION_LANGUAGES } from '../data/defaults';
import { playFeedbackChime } from '../lib/pipeline';
import { useAppStore } from '../store/AppStore';
import type {
  AutoSubmitKey,
  ClipboardHandling,
  LogLevel,
  OverlayPosition,
  OverlayStyle,
  PasteMethod,
  RecordingRetentionPeriod,
  SettingsPane,
  ShortcutActivation,
  SoundTheme,
  ThemeMode,
  VadBackend,
} from '../types';
import { ModelsView } from './ModelsView';
import { PersonalizationView } from './PersonalizationView';
import { KeycapCombo, TactileSwitch } from './ui/Controls';

interface SettingsViewProps {
  pane: SettingsPane;
}

export const SettingsView: React.FC<SettingsViewProps> = ({ pane }) => {
  const {
    settings,
    updateSettings,
    updateBinding,
    resetBinding,
    showOverlay,
    setLevels,
    learningAttempts,
    clearLearningAttempts,
    resetAllData,
    t,
  } = useAppStore();

  const [capturingId, setCapturingId] = useState<string | null>(null);
  const [audioInputs, setAudioInputs] = useState<MediaDeviceInfo[]>([]);
  const [audioOutputs, setAudioOutputs] = useState<MediaDeviceInfo[]>([]);
  const [diagRunning, setDiagRunning] = useState(false);
  const [diagCounts, setDiagCounts] = useState({ keyDown: 0, keyUp: 0, pointer: 0 });
  const [micPermission, setMicPermission] = useState<string>('unknown');

  useEffect(() => {
    if (pane !== 'audio' && pane !== 'debug') return;
    if (navigator.mediaDevices?.enumerateDevices) {
      navigator.mediaDevices
        .enumerateDevices()
        .then((devices) => {
          setAudioInputs(devices.filter((d) => d.kind === 'audioinput'));
          setAudioOutputs(devices.filter((d) => d.kind === 'audiooutput'));
        })
        .catch(() => {
          // ignore
        });
    }
    if (navigator.permissions?.query) {
      navigator.permissions
        .query({ name: 'microphone' as PermissionName })
        .then((res) => setMicPermission(res.state))
        .catch(() => setMicPermission('prompt'));
    }
  }, [pane]);

  useEffect(() => {
    if (!capturingId) return;
    const onKeyDown = (e: KeyboardEvent) => {
      e.preventDefault();
      e.stopPropagation();
      if (e.key === 'Escape') {
        setCapturingId(null);
        return;
      }
      if (['Shift', 'Control', 'Alt', 'Meta'].includes(e.key)) return;
      const parts: string[] = [];
      if (e.metaKey) parts.push('Cmd');
      if (e.ctrlKey) parts.push('Ctrl');
      if (e.altKey) parts.push('Alt');
      if (e.shiftKey) parts.push('Shift');
      const key = e.key === ' ' ? 'Space' : e.key.length === 1 ? e.key.toUpperCase() : e.key;
      parts.push(key);
      updateBinding(capturingId, parts.join('+'));
      setCapturingId(null);
    };
    window.addEventListener('keydown', onKeyDown, true);
    return () => window.removeEventListener('keydown', onKeyDown, true);
  }, [capturingId, updateBinding]);

  useEffect(() => {
    if (!diagRunning) return;
    const onDown = () => setDiagCounts((c) => ({ ...c, keyDown: c.keyDown + 1 }));
    const onUp = () => setDiagCounts((c) => ({ ...c, keyUp: c.keyUp + 1 }));
    const onClick = () => setDiagCounts((c) => ({ ...c, pointer: c.pointer + 1 }));
    window.addEventListener('keydown', onDown);
    window.addEventListener('keyup', onUp);
    window.addEventListener('pointerdown', onClick);
    return () => {
      window.removeEventListener('keydown', onDown);
      window.removeEventListener('keyup', onUp);
      window.removeEventListener('pointerdown', onClick);
    };
  }, [diagRunning]);

  const previewOverlay = (kind: string) => {
    if (kind === 'recording') {
      setLevels([0.9, 0.78, 0.65, 0.52, 0.4, 0.3, 0.22, 0.16, 0.14]);
      showOverlay({ type: 'recording', targetName: 'Cursor', workflow: 'dictation' }, 6000);
    } else if (kind === 'streaming') {
      setLevels([0.85, 0.72, 0.58, 0.48, 0.36, 0.28, 0.2, 0.15, 0.13]);
      showOverlay({ type: 'streaming', targetName: 'TalkWTF' }, 6000);
    } else if (kind === 'transcribing') {
      showOverlay({ type: 'transcribing' }, 5000);
    } else if (kind === 'processing') {
      showOverlay({ type: 'processing' }, 5000);
    } else if (kind === 'translating') {
      showOverlay({ type: 'translating', label: 'English' }, 5000);
    } else if (kind === 'learned') {
      showOverlay({ type: 'learned', pattern: '浏览起', replacement: '浏览器', count: 1 });
    } else if (kind === 'translation_failed') {
      showOverlay({ type: 'translation_failed', label: 'English' });
    } else if (kind === 'notice') {
      showOverlay({ type: 'notice', kind: 'no_target' });
    }
  };

  return (
    <div className="flex-1 overflow-y-auto">
      <div className="max-w-[1080px] mx-auto px-6 lg:px-10 py-8 lg:py-10 space-y-10">
        <div className="space-y-1">
          <h1 className="font-display text-[32px] font-semibold tracking-[-0.03em] leading-tight">
            {t(`settings.panes.${pane}`)}
          </h1>
          <p className="text-[14px]" style={{ color: 'var(--ink-secondary)' }}>
            {t('settings.subtitle')}
          </p>
        </div>

        {pane === 'general' && (
          <div className="space-y-12 pb-8">
            <SettingsGroup title={t('settings.general.title')}>
              <Row label={t('settings.general.appLanguage')}>
                <select
                  value={settings.app_language}
                  onChange={(e) =>
                    updateSettings({ app_language: e.target.value as 'zh' | 'en' })
                  }
                  className="studio-select min-w-[200px]"
                >
                  <option value="zh">简体中文</option>
                  <option value="en">English</option>
                </select>
              </Row>

              <div className="py-4 space-y-1.5" style={{ borderColor: 'var(--border-hairline)' }}>
                <div className="flex flex-wrap items-center justify-between gap-4">
                  <span className="text-[14px]">{t('settings.general.recognitionLanguage')}</span>
                  <select
                    value={settings.selected_language}
                    onChange={(e) => updateSettings({ selected_language: e.target.value })}
                    className="studio-select min-w-[200px]"
                  >
                    {RECOGNITION_LANGUAGES.map((lang) => (
                      <option key={lang.value} value={lang.value}>
                        {lang.label}
                      </option>
                    ))}
                  </select>
                </div>
                <p className="text-[12px]" style={{ color: 'var(--ink-tertiary)' }}>
                  {t('settings.general.recognitionDesc')}
                </p>
              </div>

              <Row label={t('settings.general.theme')}>
                <select
                  value={settings.theme}
                  onChange={(e) => updateSettings({ theme: e.target.value as ThemeMode })}
                  className="studio-select min-w-[200px]"
                >
                  <option value="system">{t('settings.general.theme.system')}</option>
                  <option value="light">{t('settings.general.theme.light')}</option>
                  <option value="dark">{t('settings.general.theme.dark')}</option>
                </select>
              </Row>
            </SettingsGroup>

            <SettingsGroup
              title={t('settings.general.shortcutsGroup')}
              description={t('settings.general.holdThresholdDesc')}
            >
              <Row label={t('settings.general.shortcutActivation')}>
                <select
                  value={settings.shortcut_activation}
                  onChange={(e) =>
                    updateSettings({
                      shortcut_activation: e.target.value as ShortcutActivation,
                    })
                  }
                  className="studio-select min-w-[220px]"
                >
                  <option value="hold_or_toggle">
                    {t('settings.general.activation.hold_or_toggle')}
                  </option>
                  <option value="push_to_talk">
                    {t('settings.general.activation.push_to_talk')}
                  </option>
                  <option value="toggle">{t('settings.general.activation.toggle')}</option>
                </select>
              </Row>

              {settings.shortcut_activation === 'hold_or_toggle' && (
                <div
                  className="py-4 flex items-center gap-4"
                  style={{ borderColor: 'var(--border-hairline)' }}
                >
                  <span className="text-[14px] shrink-0">
                    {t('settings.general.holdThreshold')}
                  </span>
                  <input
                    type="range"
                    min={100}
                    max={1000}
                    step={50}
                    value={settings.hold_threshold_ms}
                    onChange={(e) =>
                      updateSettings({ hold_threshold_ms: Number(e.target.value) })
                    }
                    className="studio-range flex-1"
                  />
                  <span
                    className="text-[12.5px] font-mono-tabular w-16 text-right"
                    style={{ color: 'var(--ink-secondary)' }}
                  >
                    {settings.hold_threshold_ms} ms
                  </span>
                </div>
              )}

              {(['transcribe', 'transcribe_with_post_process', 'translate', 'cancel'] as const).map(
                (id) => {
                  const b = settings.bindings[id];
                  const isCapturing = capturingId === id;
                  return (
                    <div
                      key={id}
                      className="flex items-center justify-between gap-3 py-3.5"
                      style={{ borderColor: 'var(--border-hairline)' }}
                    >
                      <span className="text-[14px]">{b?.name ?? id}</span>
                      <div className="flex items-center gap-2">
                        <button
                          type="button"
                          onClick={() => setCapturingId(isCapturing ? null : id)}
                          className="btn-ghost h-8 px-3 text-[12px] min-w-[128px] flex items-center justify-center cursor-pointer"
                          style={
                            isCapturing
                              ? { borderColor: 'var(--accent)', color: 'var(--accent)' }
                              : undefined
                          }
                        >
                          {isCapturing ? (
                            <span className="font-mono-tabular">{t('common.pressKeys')}</span>
                          ) : b?.current_binding ? (
                            <KeycapCombo combo={b.current_binding} />
                          ) : (
                            <span style={{ color: 'var(--ink-tertiary)' }}>{t('common.none')}</span>
                          )}
                        </button>
                        <button
                          type="button"
                          onClick={() => resetBinding(id)}
                          title={t('common.reset')}
                          aria-label={t('common.reset')}
                          className="p-2 hover:bg-[var(--bg-hover)] cursor-pointer"
                          style={{ color: 'var(--ink-secondary)' }}
                        >
                          <RotateCcw className="w-3.5 h-3.5" />
                        </button>
                      </div>
                    </div>
                  );
                },
              )}
            </SettingsGroup>

            <SettingsGroup title={t('settings.general.behaviorGroup')}>
              <ToggleRow
                label={t('settings.general.startHidden')}
                checked={settings.start_hidden}
                onChange={(v) => updateSettings({ start_hidden: v })}
              />
              <ToggleRow
                label={t('settings.general.autostart')}
                checked={settings.autostart_enabled}
                onChange={(v) => updateSettings({ autostart_enabled: v })}
              />
              <Row label={t('settings.general.overlayStyle')}>
                <select
                  value={settings.overlay_style}
                  onChange={(e) =>
                    updateSettings({ overlay_style: e.target.value as OverlayStyle })
                  }
                  className="studio-select min-w-[200px]"
                >
                  <option value="none">None</option>
                  <option value="minimal">Minimal</option>
                  <option value="live">Live</option>
                </select>
              </Row>
              <Row label={t('settings.general.overlayPosition')}>
                <select
                  value={settings.overlay_position}
                  onChange={(e) =>
                    updateSettings({ overlay_position: e.target.value as OverlayPosition })
                  }
                  className="studio-select min-w-[200px]"
                >
                  <option value="top">{t('settings.general.overlayPosition.top')}</option>
                  <option value="bottom">{t('settings.general.overlayPosition.bottom')}</option>
                </select>
              </Row>
            </SettingsGroup>
          </div>
        )}

        {pane === 'personalization' && <PersonalizationView />}

        {pane === 'models' && <ModelsView />}

        {pane === 'audio' && (
          <div className="space-y-12 pb-8">
            <SettingsGroup title={settings.app_language === 'zh' ? '麦克风' : 'Microphone'}>
              <Row label={settings.app_language === 'zh' ? '输入设备' : 'Input Device'}>
                <select
                  value={settings.selected_microphone}
                  onChange={(e) => updateSettings({ selected_microphone: e.target.value })}
                  className="studio-select min-w-[240px]"
                >
                  <option value="">
                    {settings.app_language === 'zh'
                      ? '系统默认麦克风'
                      : 'System Default Microphone'}
                  </option>
                  {audioInputs.map((d, i) => (
                    <option key={d.deviceId || i} value={d.deviceId}>
                      {d.label || `Microphone ${i + 1}`}
                    </option>
                  ))}
                </select>
              </Row>
              <Row label={settings.app_language === 'zh' ? '输入声道' : 'Input Channel'}>
                <select
                  value={settings.selected_channel}
                  onChange={(e) => updateSettings({ selected_channel: Number(e.target.value) })}
                  className="studio-select min-w-[200px]"
                >
                  <option value={0}>Average</option>
                  <option value={1}>Channel 1</option>
                  <option value={2}>Channel 2</option>
                </select>
              </Row>
              <ToggleRow
                label={settings.app_language === 'zh' ? '常驻开启麦克风' : 'Always-On Microphone'}
                checked={settings.always_on_microphone}
                onChange={(v) => updateSettings({ always_on_microphone: v })}
              />
              <ToggleRow
                label={
                  settings.app_language === 'zh' ? '录音时静音系统音频' : 'Mute While Recording'
                }
                checked={settings.mute_while_recording}
                onChange={(v) => updateSettings({ mute_while_recording: v })}
              />
            </SettingsGroup>

            <SettingsGroup
              title={settings.app_language === 'zh' ? '提示音与输出' : 'Audio Feedback & Output'}
            >
              <Row label={settings.app_language === 'zh' ? '输出设备' : 'Output Device'}>
                <select
                  value={settings.selected_output_device}
                  onChange={(e) => updateSettings({ selected_output_device: e.target.value })}
                  className="studio-select min-w-[240px]"
                >
                  <option value="">
                    {settings.app_language === 'zh' ? '系统默认输出' : 'System Default Output'}
                  </option>
                  {audioOutputs.map((d, i) => (
                    <option key={d.deviceId || i} value={d.deviceId}>
                      {d.label || `Output ${i + 1}`}
                    </option>
                  ))}
                </select>
              </Row>
              <ToggleRow
                label={settings.app_language === 'zh' ? '开始/结束提示音' : 'Audio Feedback'}
                checked={settings.audio_feedback}
                onChange={(v) => updateSettings({ audio_feedback: v })}
              />
              <Row label={settings.app_language === 'zh' ? '提示音主题' : 'Sound Theme'}>
                <select
                  value={settings.sound_theme}
                  onChange={(e) => {
                    const next = e.target.value as SoundTheme;
                    updateSettings({ sound_theme: next });
                    playFeedbackChime('start', next, settings.audio_feedback_volume);
                  }}
                  className="studio-select min-w-[200px]"
                >
                  <option value="marimba">Marimba</option>
                  <option value="pop">Pop</option>
                  <option value="custom">Custom</option>
                </select>
              </Row>
              <div
                className="py-4 flex items-center gap-4"
                style={{ borderColor: 'var(--border-hairline)' }}
              >
                <span className="text-[14px] shrink-0">
                  {settings.app_language === 'zh' ? '提示音量' : 'Volume'}
                </span>
                <input
                  type="range"
                  min={0}
                  max={1}
                  step={0.05}
                  value={settings.audio_feedback_volume}
                  onChange={(e) =>
                    updateSettings({ audio_feedback_volume: Number(e.target.value) })
                  }
                  className="studio-range flex-1"
                />
                <span
                  className="text-[12.5px] font-mono-tabular w-12 text-right"
                  style={{ color: 'var(--ink-secondary)' }}
                >
                  {Math.round(settings.audio_feedback_volume * 100)}%
                </span>
              </div>
            </SettingsGroup>
          </div>
        )}

        {pane === 'advanced' && (
          <div className="space-y-12 pb-8">
            <SettingsGroup title={settings.app_language === 'zh' ? '输出与粘贴' : 'Output & Paste'}>
              <Row label={settings.app_language === 'zh' ? '粘贴方式' : 'Paste Method'}>
                <select
                  value={settings.paste_method}
                  onChange={(e) =>
                    updateSettings({ paste_method: e.target.value as PasteMethod })
                  }
                  className="studio-select min-w-[200px]"
                >
                  <option value="ctrl_v">Clipboard (⌘V)</option>
                  <option value="shift_insert">Shift + Insert</option>
                  <option value="ctrl_shift_v">⌘⇧V</option>
                  <option value="direct">Direct Input</option>
                  <option value="none">None</option>
                </select>
              </Row>
              <Row label={settings.app_language === 'zh' ? '剪贴板行为' : 'Clipboard Handling'}>
                <select
                  value={settings.clipboard_handling}
                  onChange={(e) =>
                    updateSettings({ clipboard_handling: e.target.value as ClipboardHandling })
                  }
                  className="studio-select min-w-[220px]"
                >
                  <option value="dont_modify">Restore Previous Clipboard</option>
                  <option value="copy_to_clipboard">Keep Transcript in Clipboard</option>
                </select>
              </Row>
              <Row label={settings.app_language === 'zh' ? '自动提交按键' : 'Auto-Submit Key'}>
                <select
                  value={settings.auto_submit_key}
                  onChange={(e) =>
                    updateSettings({ auto_submit_key: e.target.value as AutoSubmitKey })
                  }
                  className="studio-select min-w-[200px]"
                >
                  <option value="off">Off</option>
                  <option value="enter">Enter</option>
                  <option value="ctrl_enter">Ctrl + Enter</option>
                  <option value="cmd_enter">Cmd + Enter</option>
                </select>
              </Row>
              <ToggleRow
                label={settings.app_language === 'zh' ? '末尾追加空格' : 'Append Trailing Space'}
                checked={settings.append_trailing_space}
                onChange={(v) => updateSettings({ append_trailing_space: v })}
              />
            </SettingsGroup>

            <SettingsGroup
              title={settings.app_language === 'zh' ? '转写与学词' : 'Transcription & Learning'}
            >
              <ToggleRow
                label="Voice Activity Detection (VAD)"
                checked={settings.vad_enabled}
                onChange={(v) => updateSettings({ vad_enabled: v })}
              />
              <Row label="VAD Backend">
                <select
                  value={settings.vad_backend}
                  onChange={(e) => updateSettings({ vad_backend: e.target.value as VadBackend })}
                  className="studio-select min-w-[200px]"
                >
                  <option value="silero">Silero VAD v4</option>
                  <option value="earshot">Earshot</option>
                </select>
              </Row>
              <ToggleRow
                label={
                  settings.app_language === 'zh'
                    ? '移除口头禅（嗯/那个/um）'
                    : 'Filler Word Removal'
                }
                checked={settings.filler_word_removal_enabled}
                onChange={(v) => updateSettings({ filler_word_removal_enabled: v })}
              />
              <ToggleRow
                label={
                  settings.app_language === 'zh' ? '从手动修改中自动学词' : 'Auto-Learn from Edits'
                }
                checked={settings.learn_from_edits}
                onChange={(v) => updateSettings({ learn_from_edits: v })}
              />
              <div
                className="py-4 flex items-center gap-4"
                style={{ borderColor: 'var(--border-hairline)' }}
              >
                <span className="text-[14px] shrink-0">
                  {settings.app_language === 'zh' ? '词汇纠错灵敏度' : 'Word Correction Threshold'}
                </span>
                <input
                  type="range"
                  min={0.01}
                  max={1}
                  step={0.01}
                  value={settings.word_correction_threshold}
                  onChange={(e) =>
                    updateSettings({ word_correction_threshold: Number(e.target.value) })
                  }
                  className="studio-range flex-1"
                />
                <span
                  className="text-[12.5px] font-mono-tabular w-12 text-right"
                  style={{ color: 'var(--ink-secondary)' }}
                >
                  {Math.round(settings.word_correction_threshold * 100)}%
                </span>
              </div>
            </SettingsGroup>

            <SettingsGroup
              title={settings.app_language === 'zh' ? '历史保留策略' : 'History & Retention'}
            >
              <Row label={settings.app_language === 'zh' ? '历史条数上限' : 'History Limit'}>
                <input
                  type="number"
                  min={1}
                  max={1000}
                  value={settings.history_limit}
                  onChange={(e) =>
                    updateSettings({
                      history_limit: Math.max(1, Math.min(1000, Number(e.target.value) || 1)),
                    })
                  }
                  className="studio-input w-24 text-right font-mono-tabular"
                />
              </Row>
              <Row label={settings.app_language === 'zh' ? '录音保留周期' : 'Recording Retention'}>
                <select
                  value={settings.recording_retention_period}
                  onChange={(e) =>
                    updateSettings({
                      recording_retention_period: e.target.value as RecordingRetentionPeriod,
                    })
                  }
                  className="studio-select min-w-[200px]"
                >
                  <option value="preserve_limit">Preserve Limit</option>
                  <option value="never">Never Delete</option>
                  <option value="days3">3 Days</option>
                  <option value="weeks2">2 Weeks</option>
                  <option value="month1">1 Month</option>
                  <option value="months3">3 Months</option>
                </select>
              </Row>
            </SettingsGroup>
          </div>
        )}

        {pane === 'debug' && (
          <div className="space-y-12 pb-8">
            <SettingsGroup
              title={settings.app_language === 'zh' ? '悬浮窗状态预览' : 'Overlay State Preview'}
              description={
                settings.app_language === 'zh'
                  ? '点击下方按钮直接触发悬浮窗的 8 种状态（包含撤销与重试交互）。'
                  : 'Trigger any of the 8 floating overlay states to preview layout and actions.'
              }
            >
              <div className="py-2 flex flex-wrap gap-2">
                {[
                  ['recording', 'Recording'],
                  ['streaming', 'Streaming'],
                  ['transcribing', 'Transcribing'],
                  ['processing', 'Processing'],
                  ['translating', 'Translating'],
                  ['learned', 'Learned (Undo)'],
                  ['translation_failed', 'Translation Failed'],
                  ['notice', 'No Target Notice'],
                ].map(([key, label]) => (
                  <button
                    key={key}
                    type="button"
                    onClick={() => previewOverlay(key)}
                    className="btn-ghost h-8 px-3 text-[12px] cursor-pointer"
                  >
                    {label}
                  </button>
                ))}
              </div>
            </SettingsGroup>

            <SettingsGroup
              title={settings.app_language === 'zh' ? '日志与权限诊断' : 'Logging & Diagnostics'}
            >
              <Row label="Log Level">
                <select
                  value={settings.log_level}
                  onChange={(e) => updateSettings({ log_level: e.target.value as LogLevel })}
                  className="studio-select min-w-[180px]"
                >
                  <option value="trace">Trace</option>
                  <option value="debug">Debug</option>
                  <option value="info">Info</option>
                  <option value="warn">Warn</option>
                  <option value="error">Error</option>
                </select>
              </Row>
              <Row label="Browser Microphone Permission">
                <span className="text-[13px] font-mono-tabular" style={{ color: 'var(--ink-secondary)' }}>
                  {micPermission}
                </span>
              </Row>
              <div
                className="py-4 flex flex-wrap items-center justify-between gap-3"
                style={{ borderColor: 'var(--border-hairline)' }}
              >
                <button
                  type="button"
                  onClick={() => {
                    if (!diagRunning) setDiagCounts({ keyDown: 0, keyUp: 0, pointer: 0 });
                    setDiagRunning((v) => !v);
                  }}
                  className={
                    diagRunning
                      ? 'btn-accent h-8 px-3.5 text-[12px] cursor-pointer'
                      : 'btn-ghost h-8 px-3.5 text-[12px] cursor-pointer'
                  }
                >
                  {diagRunning
                    ? settings.app_language === 'zh'
                      ? '停止按键诊断'
                      : 'Stop Keyboard Diagnostic'
                    : settings.app_language === 'zh'
                      ? '开始按键诊断'
                      : 'Run Keyboard Diagnostic'}
                </button>
                <span
                  className="text-[12px] font-mono-tabular"
                  style={{ color: 'var(--ink-secondary)' }}
                >
                  keyDown: {diagCounts.keyDown} · keyUp: {diagCounts.keyUp} · pointer:{' '}
                  {diagCounts.pointer}
                </span>
              </div>
            </SettingsGroup>

            <SettingsGroup
              title={settings.app_language === 'zh' ? '自动学词记录' : 'Learning Attempts'}
              action={
                learningAttempts.length > 0 ? (
                  <button
                    type="button"
                    onClick={clearLearningAttempts}
                    className="btn-ghost h-7 px-2.5 text-[12px] cursor-pointer"
                  >
                    {t('library.rejectedClear')}
                  </button>
                ) : undefined
              }
            >
              {learningAttempts.length === 0 ? (
                <p className="py-3 text-[13px]" style={{ color: 'var(--ink-tertiary)' }}>
                  {settings.app_language === 'zh'
                    ? '暂无自动学词记录。'
                    : 'No learning attempts yet.'}
                </p>
              ) : (
                learningAttempts.map((a) => (
                  <div
                    key={a.id}
                    className="py-3 space-y-1 text-[13.5px]"
                    style={{ borderColor: 'var(--border-hairline)' }}
                  >
                    <div className="font-medium">
                      {a.pasted} → {a.finalText}
                    </div>
                    <div className="text-[11.5px]" style={{ color: 'var(--ink-secondary)' }}>
                      <span style={{ color: 'var(--status-ok)' }}>{a.outcome}</span> · {a.source} ·{' '}
                      {a.reason}
                    </div>
                  </div>
                ))
              )}
            </SettingsGroup>
          </div>
        )}

        {pane === 'about' && (
          <div className="pb-8">
            <SettingsGroup title="TalkWTF">
              <Row label={settings.app_language === 'zh' ? '版本' : 'Version'}>
                <span className="text-[13px] font-mono-tabular" style={{ color: 'var(--ink-secondary)' }}>
                  0.1.0 (Web Port)
                </span>
              </Row>
              <Row label={settings.app_language === 'zh' ? '运行架构' : 'Runtime'}>
                <span className="text-[13px]" style={{ color: 'var(--ink-secondary)' }}>
                  React · Vite · Web Speech / Web Audio API
                </span>
              </Row>
              <Row label={settings.app_language === 'zh' ? '数据存储' : 'Storage'}>
                <span className="text-[13px]" style={{ color: 'var(--ink-secondary)' }}>
                  Browser localStorage (Local-first, zero cloud account)
                </span>
              </Row>
              <div className="pt-5" style={{ borderColor: 'var(--border-hairline)' }}>
                <button
                  type="button"
                  onClick={resetAllData}
                  className="btn-ghost h-9 px-3.5 text-[12.5px] cursor-pointer"
                  style={{ color: 'var(--status-err)' }}
                >
                  {settings.app_language === 'zh' ? '重置本地示例数据' : 'Reset Local Data'}
                </button>
              </div>
            </SettingsGroup>
          </div>
        )}
      </div>
    </div>
  );
};

const SettingsGroup: React.FC<{
  title: string;
  description?: string;
  action?: React.ReactNode;
  children: React.ReactNode;
}> = ({ title, description, action, children }) => (
  <section
    className="grid grid-cols-1 lg:grid-cols-12 gap-6 lg:gap-10 border-t pt-8"
    style={{ borderColor: 'var(--border-hairline)' }}
  >
    <div className="lg:col-span-4 space-y-2">
      <div className="flex items-center justify-between gap-2">
        <h3 className="text-[13px] font-semibold tracking-wide" style={{ color: 'var(--ink-primary)' }}>
          {title}
        </h3>
        {action}
      </div>
      {description && (
        <p className="text-[12.5px] leading-relaxed" style={{ color: 'var(--ink-secondary)' }}>
          {description}
        </p>
      )}
    </div>
    <div className="lg:col-span-8 divide-y" style={{ borderColor: 'var(--border-hairline)' }}>
      {children}
    </div>
  </section>
);

const Row: React.FC<{ label: string; children: React.ReactNode }> = ({ label, children }) => (
  <div
    className="py-4 first:pt-0 flex flex-wrap items-center justify-between gap-4"
    style={{ borderColor: 'var(--border-hairline)' }}
  >
    <span className="text-[14px]">{label}</span>
    {children}
  </div>
);

const ToggleRow: React.FC<{
  label: string;
  checked: boolean;
  onChange: (value: boolean) => void;
}> = ({ label, checked, onChange }) => (
  <div
    className="py-4 first:pt-0 flex items-center justify-between gap-4"
    style={{ borderColor: 'var(--border-hairline)' }}
  >
    <span className="text-[14px]">{label}</span>
    <TactileSwitch checked={checked} onChange={onChange} ariaLabel={label} />
  </div>
);
