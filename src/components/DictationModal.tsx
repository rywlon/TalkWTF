import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  ArrowUpRight,
  Check,
  Copy,
  Languages,
  Mic,
  MicOff,
  Sparkles,
  Square,
  X,
} from 'lucide-react';
import { TRANSLATION_LANGUAGES } from '../data/defaults';
import { useAppStore } from '../store/AppStore';
import { AcousticCanvas } from './ui/Controls';

interface BrowserSpeechRecognitionEvent {
  resultIndex: number;
  results: {
    length: number;
    [index: number]: {
      isFinal: boolean;
      [altIndex: number]: { transcript: string };
    };
  };
}

interface BrowserSpeechRecognition {
  continuous: boolean;
  interimResults: boolean;
  lang: string;
  onresult: ((event: BrowserSpeechRecognitionEvent) => void) | null;
  onerror: ((event: { error: string }) => void) | null;
  onend: (() => void) | null;
  start: () => void;
  stop: () => void;
}

export const DictationModal: React.FC = () => {
  const {
    dictationSession,
    closeDictation,
    settings,
    levels,
    showOverlay,
    hideOverlay,
    setLevels,
    processTranscript,
    recordLearningFromEdit,
    t,
  } = useAppStore();

  const [isRecording, setIsRecording] = useState(false);
  const [rawText, setRawText] = useState('');
  const [polishedResult, setPolishedResult] = useState<string | null>(null);
  const [editableOutput, setEditableOutput] = useState('');
  const [copied, setCopied] = useState(false);
  const [micError, setMicError] = useState<string | null>(null);

  const startedAtRef = useRef<number>(0);
  const mediaStreamRef = useRef<MediaStream | null>(null);
  const audioCtxRef = useRef<AudioContext | null>(null);
  const rafRef = useRef<number | null>(null);
  const recognitionRef = useRef<BrowserSpeechRecognition | null>(null);

  const stopAudio = useCallback(() => {
    if (rafRef.current) {
      cancelAnimationFrame(rafRef.current);
      rafRef.current = null;
    }
    if (recognitionRef.current) {
      try {
        recognitionRef.current.stop();
      } catch {
        // ignore
      }
      recognitionRef.current = null;
    }
    if (mediaStreamRef.current) {
      mediaStreamRef.current.getTracks().forEach((track) => track.stop());
      mediaStreamRef.current = null;
    }
    if (audioCtxRef.current) {
      void audioCtxRef.current.close();
      audioCtxRef.current = null;
    }
    setIsRecording(false);
  }, []);

  const startRecording = useCallback(async () => {
    setMicError(null);
    setPolishedResult(null);
    startedAtRef.current = Date.now();
    setIsRecording(true);

    const targetName =
      dictationSession.agentTarget?.name ??
      (dictationSession.workflow === 'translate' ? 'Translate' : 'Browser');

    showOverlay({
      type: 'recording',
      targetName,
      workflow: dictationSession.workflow,
    });

    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      mediaStreamRef.current = stream;
      const AudioCtx =
        window.AudioContext ||
        (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext;
      const audioCtx = new AudioCtx();
      audioCtxRef.current = audioCtx;
      const source = audioCtx.createMediaStreamSource(stream);
      const analyser = audioCtx.createAnalyser();
      analyser.fftSize = 64;
      source.connect(analyser);
      const data = new Uint8Array(analyser.frequencyBinCount);

      const pump = () => {
        analyser.getByteFrequencyData(data);
        const buckets = Array.from(data.slice(0, 12), (v) => Math.max(0.12, v / 255));
        setLevels(buckets);
        rafRef.current = requestAnimationFrame(pump);
      };
      rafRef.current = requestAnimationFrame(pump);
    } catch {
      setMicError(
        settings.app_language === 'zh'
          ? '未检测到麦克风权限，你仍可在下方直接输入或粘贴口语文本来测试完整润色链路。'
          : 'Microphone unavailable in this browser context. You can still type or paste raw speech below to test the full pipeline.',
      );
      const pumpIdle = () => {
        const tSec = Date.now() / 300;
        const fake = Array.from(
          { length: 10 },
          (_, i) => 0.18 + Math.abs(Math.sin(tSec + i * 0.6)) * 0.35,
        );
        setLevels(fake);
        rafRef.current = requestAnimationFrame(pumpIdle);
      };
      rafRef.current = requestAnimationFrame(pumpIdle);
    }

    const SpeechRec =
      (window as unknown as { SpeechRecognition?: new () => BrowserSpeechRecognition })
        .SpeechRecognition ||
      (window as unknown as { webkitSpeechRecognition?: new () => BrowserSpeechRecognition })
        .webkitSpeechRecognition;

    if (SpeechRec) {
      try {
        const rec = new SpeechRec();
        rec.continuous = true;
        rec.interimResults = true;
        rec.lang =
          settings.selected_language === 'auto'
            ? settings.app_language === 'zh'
              ? 'zh-CN'
              : 'en-US'
            : settings.selected_language;
        rec.onresult = (event) => {
          let combined = '';
          for (let i = 0; i < event.results.length; i++) {
            combined += event.results[i][0]?.transcript ?? '';
          }
          if (combined.trim()) {
            setRawText(combined);
          }
        };
        rec.onerror = () => {
          // Non-fatal
        };
        rec.start();
        recognitionRef.current = rec;
      } catch {
        // Ignore SpeechRecognition startup error
      }
    }
  }, [
    dictationSession.agentTarget?.name,
    dictationSession.workflow,
    setLevels,
    settings.app_language,
    settings.selected_language,
    showOverlay,
  ]);

  useEffect(() => {
    if (dictationSession.open) {
      setRawText('');
      setPolishedResult(null);
      setEditableOutput('');
      setCopied(false);
      void startRecording();
    } else {
      stopAudio();
    }
    return () => stopAudio();
  }, [dictationSession.open, startRecording, stopAudio]);

  if (!dictationSession.open) return null;

  const handleFinish = () => {
    stopAudio();
    const durationMs = Math.max(1200, Date.now() - (startedAtRef.current || Date.now()));
    const textToProcess = rawText.trim();
    if (!textToProcess) {
      hideOverlay();
      return;
    }

    const activeTargetCode =
      settings.translation_active_target ?? settings.translation_targets[0] ?? 'en';
    const targetLabel =
      TRANSLATION_LANGUAGES.find((l) => l.value === activeTargetCode)?.label ?? activeTargetCode;

    if (dictationSession.workflow === 'translate') {
      showOverlay({ type: 'translating', label: targetLabel });
    } else {
      showOverlay({ type: 'processing' });
    }

    window.setTimeout(() => {
      const { output } = processTranscript({
        rawText: textToProcess,
        durationMs,
        workflow: dictationSession.workflow,
        agentTarget: dictationSession.agentTarget,
      });
      setPolishedResult(output);
      setEditableOutput(output);
    }, 360);
  };

  const handleCopy = async () => {
    if (!editableOutput) return;
    try {
      await navigator.clipboard.writeText(editableOutput);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1800);
    } catch {
      // ignore
    }
  };

  const handleApplyEditLearning = () => {
    if (polishedResult && editableOutput.trim() !== polishedResult.trim()) {
      recordLearningFromEdit(polishedResult, editableOutput);
    }
    closeDictation();
  };

  const activeScene = settings.scenes.find((s) => s.id === settings.active_scene_id);
  const workflowTitle =
    dictationSession.workflow === 'agent'
      ? `Voice to Agent · ${dictationSession.agentTarget?.name ?? 'Agent'}`
      : dictationSession.workflow === 'translate'
        ? t('dashboard.startTranslate')
        : t('dashboard.startDictation');

  return (
    <div className="fixed inset-0 z-40 flex items-center justify-center bg-black/55 backdrop-blur-[3px] p-4">
      <div
        className="w-full max-w-[580px] studio-panel p-6 lg:p-7 shadow-2xl space-y-5"
        style={{ borderColor: 'var(--border-strong)' }}
      >
        <div className="flex items-start justify-between gap-4">
          <div className="flex items-start gap-3">
            <div className="mt-0.5 shrink-0" style={{ color: 'var(--accent)' }}>
              {dictationSession.workflow === 'agent' ? (
                <ArrowUpRight className="w-5 h-5" />
              ) : dictationSession.workflow === 'translate' ? (
                <Languages className="w-5 h-5" />
              ) : (
                <Mic className="w-5 h-5" />
              )}
            </div>
            <div>
              <h3 className="font-display text-[20px] font-semibold leading-tight">
                {workflowTitle}
              </h3>
              <p className="text-[12.5px] mt-0.5" style={{ color: 'var(--ink-secondary)' }}>
                {activeScene
                  ? `${settings.app_language === 'zh' ? '当前场景' : 'Scene'}: ${activeScene.name}`
                  : `${settings.app_language === 'zh' ? '润色风格' : 'Style'}: ${settings.polish_style}`}
              </p>
            </div>
          </div>
          <button
            type="button"
            onClick={closeDictation}
            className="p-1.5 hover:bg-[var(--bg-hover)] cursor-pointer"
            style={{ color: 'var(--ink-secondary)' }}
            aria-label="Close"
          >
            <X className="w-4 h-4" />
          </button>
        </div>

        {/* Live 60fps Acoustic Capture Chamber */}
        <div
          className="border-y py-3"
          style={{ borderColor: 'var(--border-hairline)' }}
        >
          <div className="flex items-center justify-between text-[11.5px] font-mono-tabular mb-1.5">
            <span style={{ color: isRecording ? 'var(--accent)' : 'var(--ink-tertiary)' }}>
              {isRecording ? 'LIVE INPUT' : 'STANDBY'}
            </span>
            <span style={{ color: 'var(--ink-tertiary)' }}>
              {settings.selected_language === 'auto' ? 'AUTO LANG' : settings.selected_language}
            </span>
          </div>
          <AcousticCanvas levels={levels} active={isRecording} height={52} barCount={44} />
        </div>

        {micError && (
          <div
            className="px-3 py-2 text-[12px] flex items-center gap-2 studio-well"
            style={{ color: 'var(--ink-secondary)' }}
          >
            <MicOff className="w-3.5 h-3.5 shrink-0" />
            <span>{micError}</span>
          </div>
        )}

        <div className="space-y-4">
          <div className="space-y-1.5">
            <div className="flex items-center justify-between">
              <label
                className="text-[12px] font-medium"
                style={{ color: 'var(--ink-secondary)' }}
              >
                {settings.app_language === 'zh'
                  ? '原始转写（支持语音输入或直接编辑）'
                  : 'Raw Transcript (Speak or type)'}
              </label>
              <button
                type="button"
                onClick={() =>
                  setRawText(
                    '嗯那个首先打开浏览起确认一下 TalkWTF 的接口返回然后把词典规则同步一下最后跑一遍构建。',
                  )
                }
                className="text-[12px] font-medium cursor-pointer hover:underline"
                style={{ color: 'var(--accent)' }}
              >
                {settings.app_language === 'zh' ? '填入示例口语' : 'Insert sample speech'}
              </button>
            </div>
            <textarea
              value={rawText}
              onChange={(e) => setRawText(e.target.value)}
              rows={3}
              placeholder={
                settings.app_language === 'zh'
                  ? '正在聆听… 你也可以直接输入带口头禅或错字的口语文本'
                  : 'Listening… or type spoken text with filler words / typos'
              }
              className="studio-textarea w-full resize-none leading-relaxed"
            />
          </div>

          <div className="flex items-center justify-between gap-2">
            {isRecording ? (
              <button
                type="button"
                onClick={stopAudio}
                className="btn-ghost h-9 px-3.5 text-[13px] flex items-center gap-1.5 cursor-pointer"
              >
                <Square className="w-3.5 h-3.5" style={{ color: 'var(--status-err)' }} />
                <span>{settings.app_language === 'zh' ? '停止录音' : 'Stop Mic'}</span>
              </button>
            ) : (
              <button
                type="button"
                onClick={() => void startRecording()}
                className="btn-ghost h-9 px-3.5 text-[13px] flex items-center gap-1.5 cursor-pointer"
              >
                <Mic className="w-3.5 h-3.5" style={{ color: 'var(--accent)' }} />
                <span>{settings.app_language === 'zh' ? '重新录音' : 'Record Again'}</span>
              </button>
            )}

            <button
              type="button"
              disabled={!rawText.trim()}
              onClick={handleFinish}
              className="btn-accent h-9 px-4 text-[13px] flex items-center gap-1.5 cursor-pointer"
            >
              <Sparkles className="w-3.5 h-3.5" />
              <span>
                {dictationSession.workflow === 'agent'
                  ? settings.app_language === 'zh'
                    ? '润色并发送给 Agent'
                    : 'Polish & Send to Agent'
                  : dictationSession.workflow === 'translate'
                    ? settings.app_language === 'zh'
                      ? '转写并翻译'
                      : 'Transcribe & Translate'
                    : settings.app_language === 'zh'
                      ? '完成并 AI 润色'
                      : 'Finish & Polish'}
              </span>
            </button>
          </div>

          {polishedResult !== null && (
            <div
              className="pt-4 border-t space-y-2.5"
              style={{ borderColor: 'var(--border-hairline)' }}
            >
              <div className="flex items-center justify-between">
                <span
                  className="text-[12px] font-medium"
                  style={{ color: 'var(--ink-secondary)' }}
                >
                  {settings.app_language === 'zh'
                    ? '输出结果（修改错字后点击完成，可触发自动学词）'
                    : 'Output (Edit typos and finish to trigger Auto-Learn)'}
                </span>
                <button
                  type="button"
                  onClick={() => void handleCopy()}
                  className="text-[12px] font-medium flex items-center gap-1 cursor-pointer hover:underline"
                  style={{ color: 'var(--accent)' }}
                >
                  {copied ? <Check className="w-3.5 h-3.5" /> : <Copy className="w-3.5 h-3.5" />}
                  <span>{copied ? t('common.copied') : t('common.copy')}</span>
                </button>
              </div>
              <textarea
                value={editableOutput}
                onChange={(e) => setEditableOutput(e.target.value)}
                rows={3}
                className="studio-textarea w-full resize-none leading-relaxed"
              />
              <div className="flex justify-end gap-2 pt-1">
                <button
                  type="button"
                  onClick={closeDictation}
                  className="btn-ghost h-9 px-3.5 text-[13px] cursor-pointer"
                >
                  {t('common.cancel')}
                </button>
                <button
                  type="button"
                  onClick={handleApplyEditLearning}
                  className="btn-accent h-9 px-4 text-[13px] cursor-pointer"
                >
                  {settings.app_language === 'zh' ? '完成' : 'Done'}
                </button>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
};
