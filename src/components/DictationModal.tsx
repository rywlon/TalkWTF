import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  ArrowUpRight,
  Check,
  Copy,
  GitBranch,
  HardDrive,
  Languages,
  Mic,
  MicOff,
  Pause,
  ShieldAlert,
  Sparkles,
  Square,
  WifiOff,
  X,
} from 'lucide-react';
import { TRANSLATION_LANGUAGES } from '../data/defaults';
import {
  createSilentWavFallback,
  formatBytes,
  pickSupportedAudioMime,
} from '../lib/audioVault';
import { useAppStore } from '../store/AppStore';
import type { AgentRouteDecision, AgentTarget } from '../types';
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

interface DictationModalProps {
  onOpenRecoveryVault?: () => void;
}

const AUTO_DISPATCH_MS = 2600;

export const DictationModal: React.FC<DictationModalProps> = ({ onOpenRecoveryVault }) => {
  const {
    dictationSession,
    closeDictation,
    settings,
    isOnline,
    levels,
    showOverlay,
    hideOverlay,
    setLevels,
    processTranscript,
    recordLearningFromEdit,
    checkpointRecordingDraft,
    rescueRecording,
    discardRecordingDraft,
    evaluateAutoRoute,
    dispatchRoutedAgent,
    t,
  } = useAppStore();

  const [isRecording, setIsRecording] = useState(false);
  const [rawText, setRawText] = useState('');
  const [polishedResult, setPolishedResult] = useState<string | null>(null);
  const [editableOutput, setEditableOutput] = useState('');
  const [copied, setCopied] = useState(false);
  const [micError, setMicError] = useState<string | null>(null);

  // Black-box audio vault live state
  const [checkpointBytes, setCheckpointBytes] = useState(0);
  const [rescuedNotice, setRescuedNotice] = useState<string | null>(null);

  // Tiny Auto-Route Harness state
  const [routeDecision, setRouteDecision] = useState<AgentRouteDecision | null>(null);
  const [editablePrompt, setEditablePrompt] = useState('');
  const [countdownMs, setCountdownMs] = useState<number>(0);
  const [countdownPaused, setCountdownPaused] = useState(false);
  const [dispatchedTarget, setDispatchedTarget] = useState<string | null>(null);

  const startedAtRef = useRef<number>(0);
  const draftIdRef = useRef<string | null>(null);
  const completedRef = useRef<boolean>(false);
  const rescuedRef = useRef<boolean>(false);
  const speechErrorRef = useRef<string | null>(null);
  const latestRawTextRef = useRef<string>('');
  const chunksRef = useRef<Blob[]>([]);
  const mimeTypeRef = useRef<string>('audio/webm');
  const mediaRecorderRef = useRef<MediaRecorder | null>(null);
  const mediaStreamRef = useRef<MediaStream | null>(null);
  const audioCtxRef = useRef<AudioContext | null>(null);
  const rafRef = useRef<number | null>(null);
  const recognitionRef = useRef<BrowserSpeechRecognition | null>(null);

  useEffect(() => {
    latestRawTextRef.current = rawText;
  }, [rawText]);

  const buildCurrentBlob = useCallback((): { blob: Blob; mimeType: string } => {
    if (chunksRef.current.length > 0) {
      const mime = mimeTypeRef.current || 'audio/webm';
      return { blob: new Blob(chunksRef.current, { type: mime }), mimeType: mime };
    }
    const elapsedSec = Math.max(
      1.5,
      Math.min(12, (Date.now() - (startedAtRef.current || Date.now())) / 1000),
    );
    return { blob: createSilentWavFallback(elapsedSec), mimeType: 'audio/wav' };
  }, []);

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
    if (mediaRecorderRef.current && mediaRecorderRef.current.state !== 'inactive') {
      try {
        mediaRecorderRef.current.stop();
      } catch {
        // ignore
      }
    }
    mediaRecorderRef.current = null;
    if (mediaStreamRef.current) {
      mediaStreamRef.current.getTracks().forEach((track) => {
        track.onended = null;
        track.stop();
      });
      mediaStreamRef.current = null;
    }
    if (audioCtxRef.current) {
      void audioCtxRef.current.close();
      audioCtxRef.current = null;
    }
    setIsRecording(false);
  }, []);

  const rescueCurrentSession = useCallback(
    (
      status: 'interrupted' | 'offline_pending' | 'transcribe_failed',
      reason: string,
      notifyOverlay = true,
    ) => {
      if (rescuedRef.current || completedRef.current) return;
      rescuedRef.current = true;
      const id = draftIdRef.current ?? `rec-${Date.now()}`;
      draftIdRef.current = id;
      const durationMs = Math.max(1200, Date.now() - (startedAtRef.current || Date.now()));
      const { blob, mimeType } = buildCurrentBlob();

      rescueRecording(
        {
          id,
          createdAt: startedAtRef.current || Date.now(),
          durationMs,
          sizeBytes: blob.size,
          mimeType,
          hasAudioBlob: true,
          workflow: dictationSession.workflow,
          targetAgentId: dictationSession.agentTarget?.id,
          targetName:
            dictationSession.agentTarget?.name ??
            (dictationSession.workflow === 'agent_auto'
              ? settings.app_language === 'zh'
                ? '智能路由 Agent'
                : 'Auto-Route Agent'
              : undefined),
          partialTranscript: latestRawTextRef.current.trim(),
          status,
          failureReason: reason,
        },
        blob,
        notifyOverlay,
      );
      setRescuedNotice(reason);
    },
    [
      buildCurrentBlob,
      dictationSession.agentTarget?.id,
      dictationSession.agentTarget?.name,
      dictationSession.workflow,
      rescueRecording,
      settings.app_language,
    ],
  );

  const startRecording = useCallback(async () => {
    setMicError(null);
    setPolishedResult(null);
    setRouteDecision(null);
    setDispatchedTarget(null);
    setRescuedNotice(null);
    setCheckpointBytes(0);
    completedRef.current = false;
    rescuedRef.current = false;
    speechErrorRef.current = null;
    chunksRef.current = [];

    const now = Date.now();
    startedAtRef.current = now;
    const draftId = `rec-${now}`;
    draftIdRef.current = draftId;
    setIsRecording(true);

    const targetName =
      dictationSession.agentTarget?.name ??
      (dictationSession.workflow === 'agent_auto'
        ? settings.app_language === 'zh'
          ? '智能路由'
          : 'Auto-Route'
        : dictationSession.workflow === 'translate'
          ? 'Translate'
          : 'Browser');

    showOverlay({
      type: 'recording',
      targetName,
      workflow: dictationSession.workflow,
    });

    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      mediaStreamRef.current = stream;

      // Guard against unexpected microphone disconnection mid-recording
      const audioTrack = stream.getAudioTracks()[0];
      if (audioTrack) {
        audioTrack.onended = () => {
          if (!completedRef.current && !rescuedRef.current) {
            stopAudio();
            rescueCurrentSession(
              'interrupted',
              settings.app_language === 'zh'
                ? '麦克风输入意外断开，录音已自动抢救至黑匣子'
                : 'Microphone disconnected unexpectedly; audio rescued to Vault',
              true,
            );
          }
        };
      }

      // Real chunked MediaRecorder checkpointing every 1 second into IndexedDB
      if (typeof MediaRecorder !== 'undefined') {
        try {
          const mime = pickSupportedAudioMime();
          mimeTypeRef.current = mime || 'audio/webm';
          const recorder = mime
            ? new MediaRecorder(stream, { mimeType: mime })
            : new MediaRecorder(stream);
          recorder.ondataavailable = (ev) => {
            if (ev.data && ev.data.size > 0) {
              chunksRef.current.push(ev.data);
              const combined = new Blob(chunksRef.current, {
                type: mimeTypeRef.current || ev.data.type || 'audio/webm',
              });
              setCheckpointBytes(combined.size);
              if (!completedRef.current && !rescuedRef.current && draftIdRef.current) {
                checkpointRecordingDraft(
                  {
                    id: draftIdRef.current,
                    createdAt: startedAtRef.current || Date.now(),
                    durationMs: Math.max(1000, Date.now() - (startedAtRef.current || Date.now())),
                    sizeBytes: combined.size,
                    mimeType: combined.type || 'audio/webm',
                    hasAudioBlob: true,
                    workflow: dictationSession.workflow,
                    targetAgentId: dictationSession.agentTarget?.id,
                    targetName: dictationSession.agentTarget?.name,
                    partialTranscript: latestRawTextRef.current.trim(),
                    status: 'recording_draft',
                    failureReason: '',
                  },
                  combined,
                );
              }
            }
          };
          recorder.start(1000);
          mediaRecorderRef.current = recorder;
        } catch {
          // Non-fatal: audio visualization & transcript still work
        }
      }

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
          ? '当前浏览器环境未开启麦克风权限，你仍可直接输入口语文本，或点击「暂存黑匣子」验证录音抢救链路。'
          : 'Microphone unavailable in this browser context. You can still type speech below or stash to the Audio Vault.',
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
        rec.onerror = (ev) => {
          if (ev.error && ev.error !== 'no-speech' && ev.error !== 'aborted') {
            speechErrorRef.current = ev.error;
          }
        };
        rec.start();
        recognitionRef.current = rec;
      } catch {
        // Ignore SpeechRecognition startup error
      }
    }
  }, [
    checkpointRecordingDraft,
    dictationSession.agentTarget?.id,
    dictationSession.agentTarget?.name,
    dictationSession.workflow,
    rescueCurrentSession,
    setLevels,
    settings.app_language,
    settings.selected_language,
    showOverlay,
    stopAudio,
  ]);

  // Protect recording on unexpected tab close / refresh
  useEffect(() => {
    if (!dictationSession.open || !isRecording) return;
    const onBeforeUnload = () => {
      if (!completedRef.current && !rescuedRef.current && draftIdRef.current) {
        rescueCurrentSession(
          'interrupted',
          settings.app_language === 'zh'
            ? '页面意外刷新或关闭，音频已自动抢救至黑匣子'
            : 'Tab closed or refreshed mid-recording; rescued to Vault',
          false,
        );
      }
    };
    window.addEventListener('beforeunload', onBeforeUnload);
    return () => window.removeEventListener('beforeunload', onBeforeUnload);
  }, [dictationSession.open, isRecording, rescueCurrentSession, settings.app_language]);

  useEffect(() => {
    if (dictationSession.open) {
      setRawText('');
      setPolishedResult(null);
      setEditableOutput('');
      setRouteDecision(null);
      setEditablePrompt('');
      setCountdownMs(0);
      setCountdownPaused(false);
      setDispatchedTarget(null);
      setRescuedNotice(null);
      setCopied(false);
      void startRecording();
    } else {
      stopAudio();
    }
    return () => stopAudio();
  }, [dictationSession.open, startRecording, stopAudio]);

  const handleDispatchRoute = useCallback(
    (target: AgentTarget) => {
      const promptText = editablePrompt.trim() || rawText.trim();
      if (!promptText) return;
      completedRef.current = true;
      if (draftIdRef.current) {
        discardRecordingDraft(draftIdRef.current);
        draftIdRef.current = null;
      }
      const durationMs = Math.max(1200, Date.now() - (startedAtRef.current || Date.now()));
      const { output } = dispatchRoutedAgent({
        rawText: rawText.trim() || promptText,
        prompt: promptText,
        target,
        durationMs,
        routeReason: routeDecision?.reason,
      });
      setDispatchedTarget(target.name);
      setPolishedResult(output);
      setEditableOutput(output);
      setRouteDecision(null);
      setCountdownMs(0);
    },
    [
      discardRecordingDraft,
      dispatchRoutedAgent,
      editablePrompt,
      rawText,
      routeDecision?.reason,
    ],
  );

  // Auto-dispatch countdown ticker for high-confidence routes
  useEffect(() => {
    if (
      !routeDecision ||
      !routeDecision.autoDispatch ||
      !routeDecision.target ||
      countdownPaused ||
      countdownMs <= 0
    ) {
      return;
    }
    const timer = window.setInterval(() => {
      setCountdownMs((prev) => {
        const next = Math.max(0, prev - 50);
        return next;
      });
    }, 50);
    return () => window.clearInterval(timer);
  }, [countdownMs, countdownPaused, routeDecision]);

  useEffect(() => {
    if (
      routeDecision &&
      routeDecision.autoDispatch &&
      routeDecision.target &&
      !countdownPaused &&
      countdownMs === 0 &&
      !dispatchedTarget
    ) {
      handleDispatchRoute(routeDecision.target);
    }
  }, [countdownMs, countdownPaused, dispatchedTarget, handleDispatchRoute, routeDecision]);

  // 1 / 2 / 3 quick keyboard disambiguation while route decision panel is open
  useEffect(() => {
    if (!dictationSession.open || !routeDecision) return;
    const onKeyDown = (e: KeyboardEvent) => {
      const tag = (e.target as HTMLElement | null)?.tagName;
      if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return;
      if (e.key === 'Escape') {
        setCountdownPaused(true);
        return;
      }
      if (e.key === 'Enter' && routeDecision.target) {
        e.preventDefault();
        handleDispatchRoute(routeDecision.target);
        return;
      }
      const idx = Number(e.key) - 1;
      if (idx >= 0 && idx < routeDecision.candidates.length) {
        e.preventDefault();
        handleDispatchRoute(routeDecision.candidates[idx].agent);
      }
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [dictationSession.open, handleDispatchRoute, routeDecision]);

  if (!dictationSession.open) return null;

  const handleClose = () => {
    stopAudio();
    if (!completedRef.current && !rescuedRef.current && draftIdRef.current) {
      discardRecordingDraft(draftIdRef.current);
      draftIdRef.current = null;
    }
    closeDictation();
  };

  const handleStashToVault = () => {
    stopAudio();
    rescueCurrentSession(
      isOnline ? 'transcribe_failed' : 'offline_pending',
      isOnline
        ? settings.app_language === 'zh'
          ? '已手动暂存至录音黑匣子，稍后可随时回放并重新识别'
          : 'Manually stashed to Black-Box Audio Vault for later recovery'
        : settings.app_language === 'zh'
          ? '当前离线，音频与草稿已安全存入黑匣子，联网后可一键恢复'
          : 'Offline — audio and draft safely saved to Vault until back online',
      true,
    );
  };

  const handleFinish = () => {
    stopAudio();
    const durationMs = Math.max(1200, Date.now() - (startedAtRef.current || Date.now()));
    const textToProcess = rawText.trim();

    // Protection 1: Offline rescue — never lose speech when offline
    if (!isOnline) {
      rescueCurrentSession(
        'offline_pending',
        settings.app_language === 'zh'
          ? '检测到当前处于离线状态，原始音频与草稿已安全存入黑匣子，联网后可一键识别'
          : 'You are offline — audio and draft have been saved to the Audio Vault',
        true,
      );
      return;
    }

    // Protection 2: Empty transcript or ASR error after real recording -> rescue audio!
    if (!textToProcess) {
      if (chunksRef.current.length > 0 || speechErrorRef.current) {
        rescueCurrentSession(
          'transcribe_failed',
          settings.app_language === 'zh'
            ? `语音转录失败或未返回文字${speechErrorRef.current ? `（${speechErrorRef.current}）` : ''}，原始音频已抢救至黑匣子`
            : `Transcription failed or returned empty${speechErrorRef.current ? ` (${speechErrorRef.current})` : ''}; raw audio rescued to Vault`,
          true,
        );
      } else {
        hideOverlay();
      }
      return;
    }

    // Tiny Auto-Route Harness flow
    if (dictationSession.workflow === 'agent_auto') {
      const decision = evaluateAutoRoute(textToProcess);
      setRouteDecision(decision);
      setEditablePrompt(decision.rewrittenPrompt || textToProcess);
      setCountdownPaused(false);
      setCountdownMs(decision.autoDispatch ? AUTO_DISPATCH_MS : 0);
      showOverlay({ type: 'routing_confirm', decision }, decision.autoDispatch ? 4000 : 8000);
      return;
    }

    // Standard Dictation / Translate / Direct Agent flow
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
      completedRef.current = true;
      if (draftIdRef.current) {
        discardRecordingDraft(draftIdRef.current);
        draftIdRef.current = null;
      }
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
    handleClose();
  };

  const activeScene = settings.scenes.find((s) => s.id === settings.active_scene_id);
  const workflowTitle =
    dictationSession.workflow === 'agent_auto'
      ? settings.app_language === 'zh'
        ? 'Voice to Agent · 智能路由'
        : 'Voice to Agent · Auto-Route'
      : dictationSession.workflow === 'agent'
        ? `Voice to Agent · ${dictationSession.agentTarget?.name ?? 'Agent'}`
        : dictationSession.workflow === 'translate'
          ? t('dashboard.startTranslate')
          : t('dashboard.startDictation');

  const tierLabel = (tier: AgentRouteDecision['tier']) => {
    if (settings.app_language === 'zh') {
      if (tier === 'rule') return 'TIER 1 · 唤醒规则';
      if (tier === 'sticky') return 'TIER 2 · 粘性会话';
      if (tier === 'semantic') return 'TIER 3 · 能力语义';
      if (tier === 'ambiguous') return 'HOLD · 置信度不足';
      return 'NO TARGET';
    }
    if (tier === 'rule') return 'TIER 1 · WAKE RULE';
    if (tier === 'sticky') return 'TIER 2 · STICKY SESSION';
    if (tier === 'semantic') return 'TIER 3 · SEMANTIC MATCH';
    if (tier === 'ambiguous') return 'HOLD · AMBIGUOUS';
    return 'NO TARGET';
  };

  return (
    <div className="fixed inset-0 z-40 flex items-center justify-center bg-black/55 backdrop-blur-[3px] p-4">
      <div
        className="w-full max-w-[620px] max-h-[92vh] overflow-y-auto studio-panel p-6 lg:p-7 shadow-2xl space-y-5"
        style={{ borderColor: 'var(--border-strong)' }}
      >
        <div className="flex items-start justify-between gap-4">
          <div className="flex items-start gap-3">
            <div className="mt-0.5 shrink-0" style={{ color: 'var(--accent)' }}>
              {dictationSession.workflow === 'agent_auto' ? (
                <GitBranch className="w-5 h-5" />
              ) : dictationSession.workflow === 'agent' ? (
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
                {dictationSession.workflow === 'agent_auto'
                  ? settings.app_language === 'zh'
                    ? '微型路由按唤醒词、粘性会话与能力名片自动分派本地 Agent'
                    : 'Tiny Harness routes via wake aliases, sticky sessions & capability manifests'
                  : activeScene
                    ? `${settings.app_language === 'zh' ? '当前场景' : 'Scene'}: ${activeScene.name}`
                    : `${settings.app_language === 'zh' ? '润色风格' : 'Style'}: ${settings.polish_style}`}
              </p>
            </div>
          </div>
          <button
            type="button"
            onClick={handleClose}
            className="p-1.5 hover:bg-[var(--bg-hover)] cursor-pointer"
            style={{ color: 'var(--ink-secondary)' }}
            aria-label="Close"
          >
            <X className="w-4 h-4" />
          </button>
        </div>

        {/* Live 60fps Acoustic Capture Chamber + Black-Box Heartbeat */}
        <div className="border-y py-3" style={{ borderColor: 'var(--border-hairline)' }}>
          <div className="flex flex-wrap items-center justify-between gap-2 text-[11.5px] font-mono-tabular mb-1.5">
            <div className="flex items-center gap-2">
              <span style={{ color: isRecording ? 'var(--accent)' : 'var(--ink-tertiary)' }}>
                {isRecording ? 'REC · BLACK-BOX ACTIVE' : 'STANDBY'}
              </span>
              {!isOnline && (
                <span
                  className="inline-flex items-center gap-1"
                  style={{ color: 'var(--status-warn)' }}
                >
                  <WifiOff className="w-3 h-3" />
                  <span>{settings.app_language === 'zh' ? '离线保护' : 'OFFLINE'}</span>
                </span>
              )}
            </div>
            <span style={{ color: 'var(--ink-tertiary)' }}>
              {checkpointBytes > 0
                ? `${settings.app_language === 'zh' ? '已落盘' : 'VAULT'} ${formatBytes(checkpointBytes)}`
                : settings.selected_language === 'auto'
                  ? 'AUTO LANG · 1s CHECKPOINT'
                  : `${settings.selected_language} · 1s CHECKPOINT`}
            </span>
          </div>
          <AcousticCanvas levels={levels} active={isRecording} height={50} barCount={44} />
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

        {/* Rescued Audio Banner */}
        {rescuedNotice && (
          <div
            className="border-l-2 pl-3.5 py-2.5 flex flex-wrap items-center justify-between gap-3"
            style={{ borderColor: 'var(--accent)', backgroundColor: 'var(--bg-well)' }}
          >
            <div className="flex items-start gap-2.5 min-w-0 flex-1">
              <ShieldAlert
                className="w-4 h-4 shrink-0 mt-0.5"
                style={{ color: 'var(--accent)' }}
              />
              <div className="space-y-0.5">
                <div className="text-[13px] font-medium">
                  {settings.app_language === 'zh'
                    ? '录音已安全抢救至本地黑匣子'
                    : 'Audio Safely Rescued to Local Vault'}
                </div>
                <p className="text-[12px]" style={{ color: 'var(--ink-secondary)' }}>
                  {rescuedNotice}
                </p>
              </div>
            </div>
            {onOpenRecoveryVault && (
              <button
                type="button"
                onClick={() => {
                  closeDictation();
                  onOpenRecoveryVault();
                }}
                className="btn-accent h-8 px-3 text-[12px] cursor-pointer shrink-0"
              >
                {settings.app_language === 'zh' ? '打开黑匣子查看' : 'Open Audio Vault'}
              </button>
            )}
          </div>
        )}

        <div className="space-y-4">
          <div className="space-y-1.5">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <label
                className="text-[12px] font-medium"
                style={{ color: 'var(--ink-secondary)' }}
              >
                {settings.app_language === 'zh'
                  ? '原始转写（支持语音输入或直接编辑）'
                  : 'Raw Transcript (Speak or type)'}
              </label>

              {dictationSession.workflow === 'agent_auto' ? (
                <div className="flex flex-wrap items-center gap-3 text-[11.5px]">
                  <button
                    type="button"
                    onClick={() =>
                      setRawText('让后端把订单接口的限流和 SQL 索引优化一下，顺便补一个 Rust 单测。')
                    }
                    className="font-medium cursor-pointer hover:underline"
                    style={{ color: 'var(--accent)' }}
                  >
                    {settings.app_language === 'zh' ? '后端规则示例' : 'Rule Sample'}
                  </button>
                  <button
                    type="button"
                    onClick={() =>
                      setRawText('把侧边栏的 Tailwind 间距和暗色模式对比度再收紧一点，去掉多余圆角。')
                    }
                    className="font-medium cursor-pointer hover:underline"
                    style={{ color: 'var(--ink-secondary)' }}
                  >
                    {settings.app_language === 'zh' ? '前端语义示例' : 'Semantic Sample'}
                  </button>
                  <button
                    type="button"
                    onClick={() =>
                      setRawText('帮我检查一下今天这个改动有没有什么遗漏的地方。')
                    }
                    className="font-medium cursor-pointer hover:underline"
                    style={{ color: 'var(--ink-secondary)' }}
                  >
                    {settings.app_language === 'zh' ? '歧义拦截示例' : 'Ambiguous Sample'}
                  </button>
                </div>
              ) : (
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
              )}
            </div>

            <textarea
              value={rawText}
              onChange={(e) => setRawText(e.target.value)}
              rows={3}
              placeholder={
                dictationSession.workflow === 'agent_auto'
                  ? settings.app_language === 'zh'
                    ? '直接说出需求（如「让后端修一下 SQL 报错」或「把按钮样式改锐利一点」）…'
                    : 'Speak naturally (e.g. "Ask backend to optimize the SQL query" or "Refine the sidebar CSS")…'
                  : settings.app_language === 'zh'
                    ? '正在聆听… 你也可以直接输入带口头禅或错字的口语文本'
                    : 'Listening… or type spoken text with filler words / typos'
              }
              className="studio-textarea w-full resize-none leading-relaxed"
            />
          </div>

          <div className="flex flex-wrap items-center justify-between gap-2">
            <div className="flex items-center gap-2">
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
                onClick={handleStashToVault}
                className="btn-ghost h-9 px-3 text-[12.5px] flex items-center gap-1.5 cursor-pointer"
                title={
                  settings.app_language === 'zh'
                    ? '立即将当前录音与草稿安全存入本地黑匣子，稍后再识别'
                    : 'Stash current audio & draft safely into the Black-Box Vault'
                }
              >
                <HardDrive className="w-3.5 h-3.5" style={{ color: 'var(--ink-secondary)' }} />
                <span>{settings.app_language === 'zh' ? '暂存黑匣子' : 'Save to Vault'}</span>
              </button>
            </div>

            <button
              type="button"
              disabled={!rawText.trim() && chunksRef.current.length === 0 && isOnline}
              onClick={handleFinish}
              className="btn-accent h-9 px-4 text-[13px] flex items-center gap-1.5 cursor-pointer"
            >
              {dictationSession.workflow === 'agent_auto' ? (
                <GitBranch className="w-3.5 h-3.5" />
              ) : (
                <Sparkles className="w-3.5 h-3.5" />
              )}
              <span>
                {!isOnline
                  ? settings.app_language === 'zh'
                    ? '离线存入黑匣子'
                    : 'Save Offline to Vault'
                  : dictationSession.workflow === 'agent_auto'
                    ? settings.app_language === 'zh'
                      ? '分析并路由 Agent'
                      : 'Analyze & Route Agent'
                    : dictationSession.workflow === 'agent'
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

          {/* Tiny Auto-Route Harness Decision & Confidence Gate */}
          {routeDecision && (
            <div
              className="pt-4 border-t space-y-4"
              style={{ borderColor: 'var(--border-hairline)' }}
            >
              <div className="flex flex-wrap items-center justify-between gap-2">
                <div className="flex items-center gap-2.5 text-[12px] font-mono-tabular">
                  <span
                    className="font-semibold"
                    style={{
                      color: routeDecision.autoDispatch ? 'var(--status-ok)' : 'var(--status-warn)',
                    }}
                  >
                    {tierLabel(routeDecision.tier)}
                  </span>
                  <span style={{ color: 'var(--ink-tertiary)' }}>·</span>
                  <span style={{ color: 'var(--ink-secondary)' }}>
                    {Math.round(routeDecision.confidence * 100)}%
                  </span>
                </div>
                <span className="text-[12px]" style={{ color: 'var(--ink-secondary)' }}>
                  {routeDecision.reason}
                </span>
              </div>

              {/* Countdown progress strip for high-confidence auto-dispatch */}
              {routeDecision.autoDispatch && routeDecision.target && (
                <div className="space-y-2">
                  <div className="flex items-center justify-between text-[12.5px]">
                    <span>
                      {countdownPaused
                        ? settings.app_language === 'zh'
                          ? `已暂停自动发送 · 目标：${routeDecision.target.name}`
                          : `Auto-dispatch paused · Target: ${routeDecision.target.name}`
                        : settings.app_language === 'zh'
                          ? `${(countdownMs / 1000).toFixed(1)}s 后自动发送给「${routeDecision.target.name}」`
                          : `Auto-dispatching to "${routeDecision.target.name}" in ${(countdownMs / 1000).toFixed(1)}s`}
                    </span>
                    <div className="flex items-center gap-2">
                      <button
                        type="button"
                        onClick={() => setCountdownPaused((p) => !p)}
                        className="btn-ghost h-7 px-2.5 text-[11.5px] flex items-center gap-1 cursor-pointer"
                      >
                        <Pause className="w-3 h-3" />
                        <span>
                          {countdownPaused
                            ? settings.app_language === 'zh'
                              ? '继续'
                              : 'Resume'
                            : settings.app_language === 'zh'
                              ? '暂停'
                              : 'Pause'}
                        </span>
                      </button>
                      <button
                        type="button"
                        onClick={() => handleDispatchRoute(routeDecision.target!)}
                        className="btn-accent h-7 px-3 text-[11.5px] cursor-pointer"
                      >
                        {settings.app_language === 'zh' ? '立即发送' : 'Send Now'}
                      </button>
                    </div>
                  </div>
                  <div
                    className="h-[2px] w-full overflow-hidden"
                    style={{ backgroundColor: 'var(--border-hairline)' }}
                  >
                    <div
                      className="h-full transition-all duration-75"
                      style={{
                        width: `${Math.min(100, (countdownMs / AUTO_DISPATCH_MS) * 100)}%`,
                        backgroundColor: countdownPaused ? 'var(--ink-tertiary)' : 'var(--accent)',
                      }}
                    />
                  </div>
                </div>
              )}

              {/* Cleaned prompt (wake prefix stripped) */}
              <div className="space-y-1">
                <label
                  className="text-[11.5px] font-medium"
                  style={{ color: 'var(--ink-secondary)' }}
                >
                  {settings.app_language === 'zh'
                    ? '整理后指令（已自动去除唤醒词，可直接微调）'
                    : 'Cleaned Prompt (wake prefix stripped, editable)'}
                </label>
                <textarea
                  value={editablePrompt}
                  onChange={(e) => {
                    setEditablePrompt(e.target.value);
                    setCountdownPaused(true);
                  }}
                  rows={2}
                  className="studio-textarea w-full resize-none leading-relaxed"
                />
              </div>

              {/* Ranked Candidate Agents (Click or Press 1/2/3) */}
              <div className="space-y-1.5">
                <div className="flex items-center justify-between text-[11.5px]" style={{ color: 'var(--ink-tertiary)' }}>
                  <span>
                    {routeDecision.autoDispatch
                      ? settings.app_language === 'zh'
                        ? '如需改派，点击或按数字键 1 / 2 / 3：'
                        : 'Click or press 1 / 2 / 3 to reroute:'
                      : settings.app_language === 'zh'
                        ? '置信度低于阈值，已安全拦截。请点击或按 1 / 2 / 3 指定接收 Agent：'
                        : 'Below confidence threshold — held safely. Click or press 1 / 2 / 3 to dispatch:'}
                  </span>
                </div>
                <div
                  className="border-y divide-y"
                  style={{ borderColor: 'var(--border-hairline)' }}
                >
                  {routeDecision.candidates.slice(0, 4).map((cand, idx) => {
                    const isPrimary = routeDecision.target?.id === cand.agent.id;
                    return (
                      <button
                        key={cand.agent.id}
                        type="button"
                        onClick={() => handleDispatchRoute(cand.agent)}
                        className="w-full py-2.5 px-2 -mx-2 flex items-center justify-between gap-3 text-left transition-colors hover:bg-[var(--bg-hover)] cursor-pointer"
                        style={{ borderColor: 'var(--border-hairline)' }}
                      >
                        <div className="flex items-center gap-3 min-w-0">
                          <span
                            className="font-mono-tabular text-[11.5px] w-5 text-center border py-0.5 shrink-0"
                            style={{
                              borderColor: isPrimary ? 'var(--accent)' : 'var(--border-strong)',
                              color: isPrimary ? 'var(--accent)' : 'var(--ink-secondary)',
                            }}
                          >
                            {idx + 1}
                          </span>
                          <div className="min-w-0">
                            <div className="text-[13.5px] font-medium truncate">
                              {cand.agent.name}
                            </div>
                            <div
                              className="text-[11.5px] truncate"
                              style={{ color: 'var(--ink-secondary)' }}
                            >
                              {cand.reason}
                            </div>
                          </div>
                        </div>
                        <div className="flex items-center gap-2 shrink-0">
                          <span
                            className="font-mono-tabular text-[12px]"
                            style={{ color: isPrimary ? 'var(--accent)' : 'var(--ink-tertiary)' }}
                          >
                            {Math.round(cand.score * 100)}%
                          </span>
                          <ArrowUpRight
                            className="w-3.5 h-3.5"
                            style={{ color: 'var(--ink-tertiary)' }}
                          />
                        </div>
                      </button>
                    );
                  })}
                </div>
              </div>
            </div>
          )}

          {/* Final Output / Edit-Learning Box */}
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
                  {dispatchedTarget
                    ? settings.app_language === 'zh'
                      ? `已分派给「${dispatchedTarget}」（修改错字后点击完成可触发自动学词）`
                      : `Dispatched to "${dispatchedTarget}" (edit typos to trigger Auto-Learn)`
                    : settings.app_language === 'zh'
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
                  onClick={handleClose}
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
