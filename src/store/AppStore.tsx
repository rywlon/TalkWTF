import React, { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react';
import {
  BUILT_IN_SCENES,
  DEFAULT_MODELS,
  DEFAULT_SETTINGS,
  INITIAL_AGENTS,
  INITIAL_HISTORY,
  INITIAL_LEARNING_ATTEMPTS,
  INITIAL_RULES,
  INITIAL_WORDS,
  TRANSLATION_LANGUAGES,
} from '../data/defaults';
import { translate } from '../data/i18n';
import { routeToLocalAgent } from '../lib/agentRouter';
import {
  clearAllAudioBlobs,
  deleteAudioBlob,
  getAudioBlob,
  saveAudioBlob,
} from '../lib/audioVault';
import {
  playFeedbackChime,
  runLocalPolishPipeline,
  runLocalTranslationFallback,
} from '../lib/pipeline';
import type {
  AgentRouteDecision,
  AgentTarget,
  AppSettings,
  AsrModelInfo,
  CorrectionRule,
  DictationWorkflow,
  DictionaryWord,
  HistoryEntry,
  LearningAttempt,
  OverlayState,
  RecoveredRecording,
  Scene,
} from '../types';

const STORAGE_KEY = 'talkwtf_web_state_v1';

interface PersistedState {
  settings: AppSettings;
  history: HistoryEntry[];
  words: DictionaryWord[];
  rules: CorrectionRule[];
  rejections: string[];
  agents: AgentTarget[];
  models: AsrModelInfo[];
  learningAttempts: LearningAttempt[];
  recoveryVault: RecoveredRecording[];
}

function hydrateAgents(stored?: AgentTarget[]): AgentTarget[] {
  if (!Array.isArray(stored) || stored.length === 0) return INITIAL_AGENTS;
  const defaultsById = new Map(INITIAL_AGENTS.map((a) => [a.id, a]));
  return stored.map((a) => {
    const def = defaultsById.get(a.id);
    return {
      ...a,
      aliases:
        a.aliases && a.aliases.length > 0
          ? a.aliases
          : def?.aliases ?? [a.provider.toLowerCase()],
      scope: a.scope ?? def?.scope ?? '',
    };
  });
}

function promoteInterruptedDrafts(vault?: RecoveredRecording[]): {
  items: RecoveredRecording[];
  promotedCount: number;
} {
  if (!Array.isArray(vault)) return { items: [], promotedCount: 0 };
  let promotedCount = 0;
  const items = vault.map((item) => {
    if (item.status === 'recording_draft') {
      promotedCount++;
      return {
        ...item,
        status: 'interrupted' as const,
        failureReason: '检测到上次录音意外中断或页面关闭，已从本地黑匣子自动抢救',
        updatedAt: Date.now(),
      };
    }
    return item;
  });
  return { items, promotedCount };
}

function loadState(): { state: PersistedState; rescuedOnBoot: number } {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (raw) {
      const parsed = JSON.parse(raw) as Partial<PersistedState>;
      const { items: recoveryVault, promotedCount } = promoteInterruptedDrafts(
        parsed.recoveryVault,
      );
      return {
        rescuedOnBoot: promotedCount,
        state: {
          settings: {
            ...DEFAULT_SETTINGS,
            ...(parsed.settings ?? {}),
            bindings: {
              ...DEFAULT_SETTINGS.bindings,
              ...(parsed.settings?.bindings ?? {}),
            },
            post_process_models: {
              ...DEFAULT_SETTINGS.post_process_models,
              ...(parsed.settings?.post_process_models ?? {}),
            },
          },
          history: Array.isArray(parsed.history) ? parsed.history : INITIAL_HISTORY,
          words: Array.isArray(parsed.words) ? parsed.words : INITIAL_WORDS,
          rules: Array.isArray(parsed.rules) ? parsed.rules : INITIAL_RULES,
          rejections: Array.isArray(parsed.rejections) ? parsed.rejections : [],
          agents: hydrateAgents(parsed.agents),
          models: Array.isArray(parsed.models) ? parsed.models : DEFAULT_MODELS,
          learningAttempts: Array.isArray(parsed.learningAttempts)
            ? parsed.learningAttempts
            : INITIAL_LEARNING_ATTEMPTS,
          recoveryVault,
        },
      };
    }
  } catch {
    // Fallback to defaults on corrupted storage
  }
  return {
    rescuedOnBoot: 0,
    state: {
      settings: DEFAULT_SETTINGS,
      history: INITIAL_HISTORY,
      words: INITIAL_WORDS,
      rules: INITIAL_RULES,
      rejections: [],
      agents: INITIAL_AGENTS,
      models: DEFAULT_MODELS,
      learningAttempts: INITIAL_LEARNING_ATTEMPTS,
      recoveryVault: [],
    },
  };
}

export interface AgentDeliveryState {
  sending: boolean;
  status: string;
  reply: string;
  failedText: string | null;
  failedTarget: AgentTarget | null;
  lastRouteReason?: string;
}

export interface DictationSession {
  open: boolean;
  workflow: DictationWorkflow;
  agentTarget: AgentTarget | null;
}

interface AppContextValue {
  settings: AppSettings;
  updateSettings: (patch: Partial<AppSettings>) => void;
  updateBinding: (id: string, binding: string) => void;
  resetBinding: (id: string) => void;
  t: (key: string, params?: Record<string, string | number>) => string;
  isOnline: boolean;

  // History
  history: HistoryEntry[];
  addHistoryEntry: (entry: Omit<HistoryEntry, 'id'>) => HistoryEntry;
  deleteHistoryEntry: (id: number) => void;
  retranscribeHistoryEntry: (id: number) => void;

  // Recording Recovery Vault (Black-Box)
  recoveryVault: RecoveredRecording[];
  checkpointRecordingDraft: (
    draft: Omit<RecoveredRecording, 'updatedAt'>,
    blob?: Blob | null,
  ) => void;
  rescueRecording: (
    draft: Omit<RecoveredRecording, 'updatedAt'>,
    blob?: Blob | null,
    notifyOverlay?: boolean,
  ) => void;
  discardRecordingDraft: (id: string) => void;
  updateRecoveredTranscript: (id: string, partialTranscript: string) => void;
  recoverRecordingItem: (
    id: string,
    transcriptOverride?: string,
    overrideAgent?: AgentTarget | null,
  ) => { ok: boolean; output?: string };
  deleteRecoveredRecording: (id: string) => void;
  getRecoveredAudioBlob: (id: string) => Promise<Blob | null>;

  // Dictionary
  words: DictionaryWord[];
  rules: CorrectionRule[];
  rejections: string[];
  addWord: (word: string) => void;
  updateWord: (id: number, word: string) => void;
  deleteWord: (id: number) => void;
  addRule: (
    pattern: string,
    replacement: string,
    source?: 'manual' | 'learned',
  ) => CorrectionRule | null;
  updateRule: (id: number, pattern: string, replacement: string) => void;
  toggleRule: (id: number, enabled: boolean) => void;
  deleteRule: (id: number) => void;
  forgetRejection: (pattern: string) => void;
  clearRejections: () => void;
  undoLearnedRule: (ruleId?: number, pattern?: string) => void;
  importDictionaryJson: (
    jsonText: string,
  ) => { accepted: number; duplicates: number; invalid: number };
  exportDictionaryJson: () => string;

  // Scenes
  addScene: (scene: Pick<Scene, 'name' | 'description' | 'prompt'>) => void;
  updateScene: (id: string, scene: Pick<Scene, 'name' | 'description' | 'prompt'>) => void;
  deleteScene: (id: string) => void;
  restoreBuiltInScenes: () => void;
  setActiveScene: (id: string | null) => void;

  // Translation targets
  addTranslationTarget: (code: string) => void;
  removeTranslationTarget: (code: string) => void;
  setActiveTranslationTarget: (code: string) => void;

  // Models
  models: AsrModelInfo[];
  downloadProgress: Record<string, number>;
  selectModel: (id: string) => void;
  downloadModel: (id: string) => void;
  cancelModelDownload: (id: string) => void;
  deleteModel: (id: string) => void;
  rescanModels: () => void;

  // Agents & Tiny Auto-Route Harness
  agents: AgentTarget[];
  agentDelivery: AgentDeliveryState;
  saveAgent: (target: AgentTarget) => void;
  removeAgent: (id: string) => void;
  deliverToAgent: (
    text: string,
    target: AgentTarget,
    simulateFailure?: boolean,
    routeReason?: string,
  ) => void;
  clearAgentStatus: () => void;
  evaluateAutoRoute: (rawText: string) => AgentRouteDecision;
  dispatchRoutedAgent: (params: {
    rawText: string;
    prompt: string;
    target: AgentTarget;
    durationMs: number;
    routeReason?: string;
  }) => { output: string; entry: HistoryEntry };

  // Learning attempts
  learningAttempts: LearningAttempt[];
  recordLearningFromEdit: (pasted: string, edited: string) => void;
  clearLearningAttempts: () => void;

  // Overlay & live dictation
  overlay: OverlayState;
  levels: number[];
  showOverlay: (state: OverlayState, autoHideMs?: number) => void;
  hideOverlay: () => void;
  setLevels: (values: number[]) => void;
  dictationSession: DictationSession;
  openDictation: (workflow: DictationWorkflow, agentTarget?: AgentTarget | null) => void;
  closeDictation: () => void;
  processTranscript: (params: {
    rawText: string;
    durationMs: number;
    workflow: DictationWorkflow;
    agentTarget?: AgentTarget | null;
    audioDataUrl?: string;
  }) => { output: string; entry: HistoryEntry | null };
  retryLastTranslation: () => void;
  resetAllData: () => void;
}

const AppContext = createContext<AppContextValue | null>(null);

export const AppStoreProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const initialBoot = useMemo(() => loadState(), []);
  const [state, setState] = useState<PersistedState>(() => initialBoot.state);
  const [overlay, setOverlay] = useState<OverlayState>({ type: 'hidden' });
  const [levels, setLevelsState] = useState<number[]>(() => Array(18).fill(0.15));
  const [downloadProgress, setDownloadProgress] = useState<Record<string, number>>({});
  const [isOnline, setIsOnline] = useState<boolean>(() =>
    typeof navigator !== 'undefined' ? navigator.onLine : true,
  );
  const [dictationSession, setDictationSession] = useState<DictationSession>({
    open: false,
    workflow: 'dictation',
    agentTarget: null,
  });
  const [agentDelivery, setAgentDelivery] = useState<AgentDeliveryState>({
    sending: false,
    status: '',
    reply: '',
    failedText: null,
    failedTarget: null,
  });

  const autoHideTimerRef = useRef<number | null>(null);
  const downloadTimersRef = useRef<Record<string, number>>({});
  const lastFailedTranslationRef = useRef<{ rawText: string; label: string; code: string } | null>(
    null,
  );

  // Persist to localStorage
  useEffect(() => {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
    } catch {
      // Ignore quota errors
    }
  }, [state]);

  const showOverlay = useCallback((next: OverlayState, autoHideMs?: number) => {
    if (autoHideTimerRef.current) {
      window.clearTimeout(autoHideTimerRef.current);
      autoHideTimerRef.current = null;
    }
    setOverlay(next);
    const duration =
      autoHideMs ??
      (next.type === 'learned' ||
      next.type === 'translation_failed' ||
      next.type === 'notice' ||
      next.type === 'agent_message' ||
      next.type === 'audio_rescued'
        ? 8500
        : undefined);
    if (duration) {
      autoHideTimerRef.current = window.setTimeout(() => {
        setOverlay({ type: 'hidden' });
        autoHideTimerRef.current = null;
      }, duration);
    }
  }, []);

  const hideOverlay = useCallback(() => {
    if (autoHideTimerRef.current) {
      window.clearTimeout(autoHideTimerRef.current);
      autoHideTimerRef.current = null;
    }
    setOverlay({ type: 'hidden' });
  }, []);

  // Notify immediately if an interrupted recording was rescued on boot
  useEffect(() => {
    if (initialBoot.rescuedOnBoot > 0) {
      const first = initialBoot.state.recoveryVault[0];
      if (first) {
        showOverlay({
          type: 'audio_rescued',
          vaultId: first.id,
          reason:
            initialBoot.state.settings.app_language === 'zh'
              ? `已从黑匣子抢救 ${initialBoot.rescuedOnBoot} 段意外中断的录音`
              : `Rescued ${initialBoot.rescuedOnBoot} interrupted recording(s) from Audio Vault`,
          durationMs: first.durationMs,
        });
      }
    }
  }, [initialBoot, showOverlay]);

  // Monitor browser online/offline transitions for automatic recovery prompts
  useEffect(() => {
    const onOnline = () => {
      setIsOnline(true);
      setState((prev) => {
        const pending = prev.recoveryVault.filter((r) => r.status !== 'recording_draft');
        if (pending.length > 0) {
          showOverlay({
            type: 'notice',
            kind: 'no_target',
            message:
              prev.settings.app_language === 'zh'
                ? `网络已恢复 · 录音黑匣子中有 ${pending.length} 段录音可一键重新识别`
                : `Back online · ${pending.length} saved recording(s) ready to re-transcribe`,
          });
        }
        return prev;
      });
    };
    const onOffline = () => {
      setIsOnline(false);
    };
    window.addEventListener('online', onOnline);
    window.addEventListener('offline', onOffline);
    return () => {
      window.removeEventListener('online', onOnline);
      window.removeEventListener('offline', onOffline);
    };
  }, [showOverlay]);

  // Apply light/dark/system theme class
  useEffect(() => {
    const root = document.documentElement;
    const apply = (mode: AppSettings['theme']) => {
      const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
      const isDark = mode === 'dark' || (mode === 'system' && prefersDark);
      root.classList.toggle('dark', isDark);
    };
    apply(state.settings.theme);
    const mq = window.matchMedia('(prefers-color-scheme: dark)');
    const listener = () => {
      if (state.settings.theme === 'system') apply('system');
    };
    mq.addEventListener('change', listener);
    return () => mq.removeEventListener('change', listener);
  }, [state.settings.theme]);

  const t = useCallback(
    (key: string, params?: Record<string, string | number>) =>
      translate(state.settings.app_language, key, params),
    [state.settings.app_language],
  );

  const setLevels = useCallback((values: number[]) => {
    if (values.length === 0) return;
    const count = 18;
    const center = (count - 1) / 2;
    const mirrored = Array.from({ length: count }, (_, idx) => {
      const distance = Math.abs(idx - center);
      const bucket = Math.min(
        values.length - 1,
        Math.floor((distance * values.length) / (center + 1)),
      );
      return Math.max(0.12, Math.min(1, values[bucket]));
    });
    setLevelsState(mirrored);
  }, []);

  const updateSettings = useCallback((patch: Partial<AppSettings>) => {
    setState((prev) => ({
      ...prev,
      settings: { ...prev.settings, ...patch },
    }));
  }, []);

  const updateBinding = useCallback((id: string, binding: string) => {
    setState((prev) => {
      const existing = prev.settings.bindings[id] ?? {
        id,
        name: id,
        description: '',
        default_binding: '',
        current_binding: '',
      };
      return {
        ...prev,
        settings: {
          ...prev.settings,
          bindings: {
            ...prev.settings.bindings,
            [id]: { ...existing, current_binding: binding },
          },
        },
      };
    });
  }, []);

  const resetBinding = useCallback((id: string) => {
    setState((prev) => {
      const def = DEFAULT_SETTINGS.bindings[id];
      const existing = prev.settings.bindings[id];
      if (!existing && !def) return prev;
      return {
        ...prev,
        settings: {
          ...prev.settings,
          bindings: {
            ...prev.settings.bindings,
            [id]: {
              ...(existing ?? def),
              current_binding: def?.default_binding ?? existing?.default_binding ?? '',
            },
          },
        },
      };
    });
  }, []);

  // History
  const addHistoryEntry = useCallback((entry: Omit<HistoryEntry, 'id'>): HistoryEntry => {
    const newEntry: HistoryEntry = {
      ...entry,
      id: Date.now() + Math.floor(Math.random() * 1000),
    };
    setState((prev) => {
      const limit = Math.max(1, prev.settings.history_limit || 50);
      return {
        ...prev,
        history: [newEntry, ...prev.history].slice(0, limit),
      };
    });
    return newEntry;
  }, []);

  const deleteHistoryEntry = useCallback((id: number) => {
    setState((prev) => ({
      ...prev,
      history: prev.history.filter((e) => e.id !== id),
    }));
  }, []);

  const retranscribeHistoryEntry = useCallback((id: number) => {
    setState((prev) => {
      const activeScene =
        prev.settings.scenes.find((s) => s.id === prev.settings.active_scene_id) ?? null;
      return {
        ...prev,
        history: prev.history.map((item) => {
          if (item.id !== id) return item;
          const polished = runLocalPolishPipeline({
            rawText: item.transcription,
            words: prev.words,
            rules: prev.rules,
            fillerRemoval: prev.settings.filler_word_removal_enabled,
            polishStyle: prev.settings.polish_style,
            activeScene,
            appendTrailingSpace: prev.settings.append_trailing_space,
          });
          return {
            ...item,
            postProcessed: polished,
            charCount: polished.length,
          };
        }),
      };
    });
  }, []);

  // Black-Box Recording Recovery Vault
  const checkpointRecordingDraft = useCallback(
    (draft: Omit<RecoveredRecording, 'updatedAt'>, blob?: Blob | null) => {
      if (blob && blob.size > 0) {
        void saveAudioBlob(draft.id, blob);
      }
      const nextItem: RecoveredRecording = {
        ...draft,
        sizeBytes: blob ? blob.size : draft.sizeBytes,
        hasAudioBlob: Boolean(blob && blob.size > 0) || draft.hasAudioBlob,
        updatedAt: Date.now(),
      };
      setState((prev) => {
        const exists = prev.recoveryVault.some((r) => r.id === draft.id);
        return {
          ...prev,
          recoveryVault: exists
            ? prev.recoveryVault.map((r) => (r.id === draft.id ? nextItem : r))
            : [nextItem, ...prev.recoveryVault].slice(0, 30),
        };
      });
    },
    [],
  );

  const rescueRecording = useCallback(
    (
      draft: Omit<RecoveredRecording, 'updatedAt'>,
      blob?: Blob | null,
      notifyOverlay = true,
    ) => {
      if (blob && blob.size > 0) {
        void saveAudioBlob(draft.id, blob);
      }
      const rescued: RecoveredRecording = {
        ...draft,
        sizeBytes: blob ? blob.size : draft.sizeBytes,
        hasAudioBlob: Boolean(blob && blob.size > 0) || draft.hasAudioBlob,
        updatedAt: Date.now(),
      };
      setState((prev) => {
        const exists = prev.recoveryVault.some((r) => r.id === draft.id);
        return {
          ...prev,
          recoveryVault: exists
            ? prev.recoveryVault.map((r) => (r.id === draft.id ? rescued : r))
            : [rescued, ...prev.recoveryVault].slice(0, 30),
        };
      });
      if (notifyOverlay) {
        showOverlay({
          type: 'audio_rescued',
          vaultId: rescued.id,
          reason: rescued.failureReason,
          durationMs: rescued.durationMs,
        });
      }
    },
    [showOverlay],
  );

  const discardRecordingDraft = useCallback((id: string) => {
    void deleteAudioBlob(id);
    setState((prev) => ({
      ...prev,
      recoveryVault: prev.recoveryVault.filter((r) => r.id !== id),
    }));
  }, []);

  const updateRecoveredTranscript = useCallback((id: string, partialTranscript: string) => {
    setState((prev) => ({
      ...prev,
      recoveryVault: prev.recoveryVault.map((r) =>
        r.id === id ? { ...r, partialTranscript, updatedAt: Date.now() } : r,
      ),
    }));
  }, []);

  const deleteRecoveredRecording = useCallback((id: string) => {
    void deleteAudioBlob(id);
    setState((prev) => ({
      ...prev,
      recoveryVault: prev.recoveryVault.filter((r) => r.id !== id),
    }));
  }, []);

  const getRecoveredAudioBlob = useCallback((id: string) => getAudioBlob(id), []);

  // Dictionary
  const addWord = useCallback((word: string) => {
    const cleaned = word.trim();
    if (!cleaned) return;
    setState((prev) => {
      if (prev.words.some((w) => w.word.toLowerCase() === cleaned.toLowerCase())) return prev;
      return {
        ...prev,
        words: [
          {
            id: Date.now() + Math.floor(Math.random() * 1000),
            word: cleaned,
            createdAt: new Date().toISOString(),
          },
          ...prev.words,
        ],
      };
    });
  }, []);

  const updateWord = useCallback((id: number, word: string) => {
    const cleaned = word.trim();
    if (!cleaned) return;
    setState((prev) => ({
      ...prev,
      words: prev.words.map((w) => (w.id === id ? { ...w, word: cleaned } : w)),
    }));
  }, []);

  const deleteWord = useCallback((id: number) => {
    setState((prev) => ({
      ...prev,
      words: prev.words.filter((w) => w.id !== id),
    }));
  }, []);

  const addRule = useCallback(
    (
      pattern: string,
      replacement: string,
      source: 'manual' | 'learned' = 'manual',
    ): CorrectionRule | null => {
      const p = pattern.trim();
      const r = replacement.trim();
      if (!p || !r) return null;
      const created: CorrectionRule = {
        id: Date.now() + Math.floor(Math.random() * 1000),
        pattern: p,
        replacement: r,
        enabled: true,
        source,
        createdAt: new Date().toISOString(),
      };
      setState((prev) => {
        if (prev.rules.some((x) => x.pattern.toLowerCase() === p.toLowerCase())) return prev;
        return {
          ...prev,
          rules: [created, ...prev.rules],
        };
      });
      return created;
    },
    [],
  );

  const updateRule = useCallback((id: number, pattern: string, replacement: string) => {
    const p = pattern.trim();
    const r = replacement.trim();
    if (!p || !r) return;
    setState((prev) => ({
      ...prev,
      rules: prev.rules.map((x) => (x.id === id ? { ...x, pattern: p, replacement: r } : x)),
    }));
  }, []);

  const toggleRule = useCallback((id: number, enabled: boolean) => {
    setState((prev) => ({
      ...prev,
      rules: prev.rules.map((x) => (x.id === id ? { ...x, enabled } : x)),
    }));
  }, []);

  const deleteRule = useCallback((id: number) => {
    setState((prev) => ({
      ...prev,
      rules: prev.rules.filter((x) => x.id !== id),
    }));
  }, []);

  const forgetRejection = useCallback((pattern: string) => {
    setState((prev) => ({
      ...prev,
      rejections: prev.rejections.filter((r) => r !== pattern),
    }));
  }, []);

  const clearRejections = useCallback(() => {
    setState((prev) => ({ ...prev, rejections: [] }));
  }, []);

  const undoLearnedRule = useCallback(
    (ruleId?: number, pattern?: string) => {
      setState((prev) => {
        const nextRules = ruleId ? prev.rules.filter((r) => r.id !== ruleId) : prev.rules;
        const nextRejections =
          pattern && !prev.rejections.includes(pattern)
            ? [pattern, ...prev.rejections]
            : prev.rejections;
        return {
          ...prev,
          rules: nextRules,
          rejections: nextRejections,
        };
      });
      hideOverlay();
    },
    [hideOverlay],
  );

  const importDictionaryJson = useCallback((jsonText: string) => {
    let accepted = 0;
    let duplicates = 0;
    let invalid = 0;
    const parsed = JSON.parse(jsonText) as {
      words?: Array<string | { word?: string }>;
      correction_rules?: Array<{ pattern?: string; replacement?: string; enabled?: boolean }>;
      rules?: Array<{ pattern?: string; replacement?: string; enabled?: boolean }>;
    };

    const incomingWords = parsed.words ?? [];
    const incomingRules = parsed.correction_rules ?? parsed.rules ?? [];

    setState((prev) => {
      const nextWords = [...prev.words];
      const nextRules = [...prev.rules];
      const existingWords = new Set(nextWords.map((w) => w.word.toLowerCase()));
      const existingRules = new Set(nextRules.map((r) => r.pattern.toLowerCase()));

      for (const item of incomingWords) {
        const val = (typeof item === 'string' ? item : item?.word ?? '').trim();
        if (!val) {
          invalid++;
          continue;
        }
        if (existingWords.has(val.toLowerCase())) {
          duplicates++;
          continue;
        }
        existingWords.add(val.toLowerCase());
        nextWords.unshift({
          id: Date.now() + Math.floor(Math.random() * 100000) + accepted,
          word: val,
          createdAt: new Date().toISOString(),
        });
        accepted++;
      }

      for (const rule of incomingRules) {
        const p = (rule?.pattern ?? '').trim();
        const r = (rule?.replacement ?? '').trim();
        if (!p || !r) {
          invalid++;
          continue;
        }
        if (existingRules.has(p.toLowerCase())) {
          duplicates++;
          continue;
        }
        existingRules.add(p.toLowerCase());
        nextRules.unshift({
          id: Date.now() + Math.floor(Math.random() * 100000) + accepted,
          pattern: p,
          replacement: r,
          enabled: rule.enabled ?? true,
          source: 'manual',
          createdAt: new Date().toISOString(),
        });
        accepted++;
      }

      return { ...prev, words: nextWords, rules: nextRules };
    });

    return { accepted, duplicates, invalid };
  }, []);

  const exportDictionaryJson = useCallback(() => {
    return JSON.stringify(
      {
        version: 1,
        exported_at: new Date().toISOString(),
        words: state.words.map((w) => w.word),
        correction_rules: state.rules.map((r) => ({
          pattern: r.pattern,
          replacement: r.replacement,
          enabled: r.enabled,
        })),
      },
      null,
      2,
    );
  }, [state.words, state.rules]);

  // Scenes
  const addScene = useCallback((scene: Pick<Scene, 'name' | 'description' | 'prompt'>) => {
    const now = new Date().toISOString();
    const created: Scene = {
      id: `custom_${Date.now()}`,
      name: scene.name.trim(),
      description: scene.description.trim(),
      prompt: scene.prompt.trim(),
      created_at: now,
      updated_at: now,
    };
    setState((prev) => ({
      ...prev,
      settings: {
        ...prev.settings,
        scenes: [...prev.settings.scenes, created],
      },
    }));
  }, []);

  const updateScene = useCallback(
    (id: string, scene: Pick<Scene, 'name' | 'description' | 'prompt'>) => {
      setState((prev) => ({
        ...prev,
        settings: {
          ...prev.settings,
          scenes: prev.settings.scenes.map((s) =>
            s.id === id
              ? {
                  ...s,
                  name: scene.name.trim(),
                  description: scene.description.trim(),
                  prompt: scene.prompt.trim(),
                  updated_at: new Date().toISOString(),
                }
              : s,
          ),
        },
      }));
    },
    [],
  );

  const deleteScene = useCallback((id: string) => {
    setState((prev) => ({
      ...prev,
      settings: {
        ...prev.settings,
        scenes: prev.settings.scenes.filter((s) => s.id !== id),
        active_scene_id: prev.settings.active_scene_id === id ? null : prev.settings.active_scene_id,
      },
    }));
  }, []);

  const restoreBuiltInScenes = useCallback(() => {
    setState((prev) => {
      const customScenes = prev.settings.scenes.filter((s) => !s.id.startsWith('builtin_'));
      return {
        ...prev,
        settings: {
          ...prev.settings,
          scenes: [...BUILT_IN_SCENES, ...customScenes],
        },
      };
    });
  }, []);

  const setActiveScene = useCallback((id: string | null) => {
    setState((prev) => ({
      ...prev,
      settings: { ...prev.settings, active_scene_id: id },
    }));
  }, []);

  // Translation targets
  const addTranslationTarget = useCallback((code: string) => {
    setState((prev) => {
      const current = prev.settings.translation_targets;
      if (current.includes(code) || current.length >= 3) return prev;
      const next = [...current, code];
      return {
        ...prev,
        settings: {
          ...prev.settings,
          translation_targets: next,
          translation_active_target: prev.settings.translation_active_target ?? code,
        },
      };
    });
  }, []);

  const removeTranslationTarget = useCallback((code: string) => {
    setState((prev) => {
      const next = prev.settings.translation_targets.filter((c) => c !== code);
      const active =
        prev.settings.translation_active_target === code
          ? (next[0] ?? null)
          : prev.settings.translation_active_target;
      return {
        ...prev,
        settings: {
          ...prev.settings,
          translation_targets: next,
          translation_active_target: active,
        },
      };
    });
  }, []);

  const setActiveTranslationTarget = useCallback((code: string) => {
    setState((prev) => ({
      ...prev,
      settings: { ...prev.settings, translation_active_target: code },
    }));
  }, []);

  // Models
  const selectModel = useCallback((id: string) => {
    setState((prev) => ({
      ...prev,
      settings: { ...prev.settings, selected_model: id },
    }));
  }, []);

  const downloadModel = useCallback((id: string) => {
    if (downloadTimersRef.current[id]) return;
    setDownloadProgress((prev) => ({ ...prev, [id]: 0.05 }));
    const timer = window.setInterval(() => {
      setDownloadProgress((prev) => {
        const cur = prev[id] ?? 0;
        const next = Math.min(1, cur + 0.16);
        if (next >= 1) {
          window.clearInterval(downloadTimersRef.current[id]);
          delete downloadTimersRef.current[id];
          setState((s) => ({
            ...s,
            models: s.models.map((m) => (m.id === id ? { ...m, isDownloaded: true } : m)),
          }));
          const copy = { ...prev };
          delete copy[id];
          return copy;
        }
        return { ...prev, [id]: next };
      });
    }, 260);
    downloadTimersRef.current[id] = timer;
  }, []);

  const cancelModelDownload = useCallback((id: string) => {
    if (downloadTimersRef.current[id]) {
      window.clearInterval(downloadTimersRef.current[id]);
      delete downloadTimersRef.current[id];
    }
    setDownloadProgress((prev) => {
      const copy = { ...prev };
      delete copy[id];
      return copy;
    });
  }, []);

  const deleteModel = useCallback((id: string) => {
    setState((prev) => ({
      ...prev,
      models: prev.models.map((m) => (m.id === id ? { ...m, isDownloaded: false } : m)),
    }));
  }, []);

  const rescanModels = useCallback(() => {
    setState((prev) => {
      const downloadedIds = new Set(prev.models.filter((m) => m.isDownloaded).map((m) => m.id));
      return {
        ...prev,
        models: DEFAULT_MODELS.map((m) => ({
          ...m,
          isDownloaded: downloadedIds.has(m.id) || m.isDownloaded,
        })),
      };
    });
  }, []);

  // Agents & Auto-Route Tiny Harness
  const saveAgent = useCallback((target: AgentTarget) => {
    setState((prev) => {
      const exists = prev.agents.some((a) => a.id === target.id);
      const nextAgents = exists
        ? prev.agents.map((a) => (a.id === target.id ? target : a))
        : [...prev.agents, target];
      const nextBindings = { ...prev.settings.bindings };
      if (!nextBindings[target.bindingID]) {
        nextBindings[target.bindingID] = {
          id: target.bindingID,
          name: target.name,
          description: 'Voice to Agent',
          default_binding: '',
          current_binding: '',
        };
      }
      return {
        ...prev,
        agents: nextAgents,
        settings: { ...prev.settings, bindings: nextBindings },
      };
    });
  }, []);

  const removeAgent = useCallback((id: string) => {
    setState((prev) => ({
      ...prev,
      agents: prev.agents.filter((a) => a.id !== id),
    }));
  }, []);

  const deliverToAgent = useCallback(
    (
      text: string,
      target: AgentTarget,
      simulateFailure = false,
      routeReason?: string,
    ) => {
      const statusText =
        target.kind === 'codex' ? `${target.name} 正在处理…` : `正在发送到 ${target.name}…`;
      setAgentDelivery({
        sending: true,
        status: statusText,
        reply: '',
        failedText: null,
        failedTarget: null,
        lastRouteReason: routeReason,
      });
      showOverlay({ type: 'processing', label: statusText });

      // Mark lastUsedAt immediately for sticky session continuity
      setState((prev) => ({
        ...prev,
        agents: prev.agents.map((a) =>
          a.id === target.id ? { ...a, lastUsedAt: Date.now() } : a,
        ),
      }));

      window.setTimeout(() => {
        if (simulateFailure) {
          setAgentDelivery({
            sending: false,
            status: `无法连接 ${target.name}（本地接收端未响应）`,
            reply: '',
            failedText: text,
            failedTarget: target,
            lastRouteReason: routeReason,
          });
          showOverlay({
            type: 'agent_message',
            text: '发送未确认，内容已保留。打开 TalkWTF 查看或复制。',
            failed: true,
          });
          return;
        }
        const okStatus =
          target.kind === 'codex' ? `${target.name} 已接收指令` : `已发送到 ${target.name}`;
        setAgentDelivery({
          sending: false,
          status: okStatus,
          reply: `[Session ${target.conversation.slice(0, 8)}]${routeReason ? ` (${routeReason})` : ''} 已收到语音指令：「${text}」。本地回执已确认。`,
          failedText: null,
          failedTarget: null,
          lastRouteReason: routeReason,
        });
        showOverlay({ type: 'agent_message', text: okStatus, failed: false });
      }, 550);
    },
    [showOverlay],
  );

  const clearAgentStatus = useCallback(() => {
    setAgentDelivery({
      sending: false,
      status: '',
      reply: '',
      failedText: null,
      failedTarget: null,
      lastRouteReason: undefined,
    });
  }, []);

  const evaluateAutoRoute = useCallback(
    (rawText: string): AgentRouteDecision => {
      const activeScene =
        state.settings.scenes.find((s) => s.id === state.settings.active_scene_id) ?? null;
      const polished = runLocalPolishPipeline({
        rawText,
        words: state.words,
        rules: state.rules,
        fillerRemoval: state.settings.filler_word_removal_enabled,
        polishStyle: state.settings.polish_style,
        activeScene,
        appendTrailingSpace: false,
      });
      return routeToLocalAgent(polished, state.agents, state.settings.app_language);
    },
    [
      state.agents,
      state.rules,
      state.settings.active_scene_id,
      state.settings.app_language,
      state.settings.filler_word_removal_enabled,
      state.settings.polish_style,
      state.settings.scenes,
      state.words,
    ],
  );

  const dispatchRoutedAgent = useCallback(
    (params: {
      rawText: string;
      prompt: string;
      target: AgentTarget;
      durationMs: number;
      routeReason?: string;
    }) => {
      if (state.settings.audio_feedback) {
        playFeedbackChime('stop', state.settings.sound_theme, state.settings.audio_feedback_volume);
      }
      const entry = addHistoryEntry({
        timestamp: Math.floor(Date.now() / 1000),
        transcription: params.rawText.trim(),
        postProcessed: params.prompt.trim(),
        workflow: 'agent',
        durationMs: params.durationMs,
        charCount: params.prompt.trim().length,
        targetLabel: params.target.name,
      });
      deliverToAgent(params.prompt.trim(), params.target, false, params.routeReason);
      return { output: params.prompt.trim(), entry };
    },
    [
      addHistoryEntry,
      deliverToAgent,
      state.settings.audio_feedback,
      state.settings.audio_feedback_volume,
      state.settings.sound_theme,
    ],
  );

  // Learning from edits
  const recordLearningFromEdit = useCallback(
    (pasted: string, edited: string) => {
      const a = pasted.trim();
      const b = edited.trim();
      if (!a || !b || a === b) return;
      if (!state.settings.learn_from_edits) return;

      let prefix = 0;
      while (prefix < a.length && prefix < b.length && a[prefix] === b[prefix]) prefix++;
      let suffix = 0;
      while (
        suffix < a.length - prefix &&
        suffix < b.length - prefix &&
        a[a.length - 1 - suffix] === b[b.length - 1 - suffix]
      ) {
        suffix++;
      }
      const oldSeg = a.slice(prefix, a.length - suffix).trim();
      const newSeg = b.slice(prefix, b.length - suffix).trim();

      if (
        oldSeg.length >= 1 &&
        oldSeg.length <= 16 &&
        newSeg.length >= 1 &&
        newSeg.length <= 24 &&
        !state.rejections.includes(oldSeg)
      ) {
        const created = addRule(oldSeg, newSeg, 'learned');
        const attempt: LearningAttempt = {
          id: Date.now(),
          pasted: a,
          finalText: b,
          outcome: 'learned',
          source: 'edit-watcher',
          reason: `自动学词：${oldSeg} → ${newSeg}`,
          strategy: 'exact_diff',
          createdAt: new Date().toISOString(),
        };
        setState((prev) => ({
          ...prev,
          learningAttempts: [attempt, ...prev.learningAttempts].slice(0, 30),
        }));
        showOverlay({
          type: 'learned',
          pattern: oldSeg,
          replacement: newSeg,
          count: 1,
          ruleId: created?.id,
        });
      }
    },
    [addRule, showOverlay, state.rejections, state.settings.learn_from_edits],
  );

  const clearLearningAttempts = useCallback(() => {
    setState((prev) => ({ ...prev, learningAttempts: [] }));
  }, []);

  // Dictation modal & pipeline
  const openDictation = useCallback(
    (workflow: DictationWorkflow, agentTarget: AgentTarget | null = null) => {
      if (workflow === 'translate' && state.settings.translation_targets.length === 0) {
        showOverlay({ type: 'notice', kind: 'no_target' });
        return;
      }
      if (workflow === 'agent_auto' && state.agents.length === 0) {
        showOverlay({
          type: 'notice',
          kind: 'no_target',
          message:
            state.settings.app_language === 'zh'
              ? '请先在「Voice to Agent」中配对至少一个本地 Agent'
              : 'Pair at least one local Agent in Voice to Agent first',
        });
        return;
      }
      if (state.settings.audio_feedback) {
        playFeedbackChime('start', state.settings.sound_theme, state.settings.audio_feedback_volume);
      }
      setDictationSession({ open: true, workflow, agentTarget });
    },
    [
      showOverlay,
      state.agents.length,
      state.settings.app_language,
      state.settings.audio_feedback,
      state.settings.audio_feedback_volume,
      state.settings.sound_theme,
      state.settings.translation_targets.length,
    ],
  );

  const closeDictation = useCallback(() => {
    setDictationSession((prev) => ({ ...prev, open: false }));
    hideOverlay();
  }, [hideOverlay]);

  const processTranscript = useCallback(
    (params: {
      rawText: string;
      durationMs: number;
      workflow: DictationWorkflow;
      agentTarget?: AgentTarget | null;
      audioDataUrl?: string;
    }) => {
      const raw = params.rawText.trim();
      if (!raw) {
        hideOverlay();
        return { output: '', entry: null };
      }

      if (state.settings.audio_feedback) {
        playFeedbackChime('stop', state.settings.sound_theme, state.settings.audio_feedback_volume);
      }

      const activeScene =
        state.settings.scenes.find((s) => s.id === state.settings.active_scene_id) ?? null;

      const polished = runLocalPolishPipeline({
        rawText: raw,
        words: state.words,
        rules: state.rules,
        fillerRemoval: state.settings.filler_word_removal_enabled,
        polishStyle: state.settings.polish_style,
        activeScene,
        appendTrailingSpace: state.settings.append_trailing_space,
      });

      let finalOutput = polished;
      let targetLabel: string | undefined;

      if (params.workflow === 'translate') {
        const activeCode =
          state.settings.translation_active_target ?? state.settings.translation_targets[0];
        const lang = TRANSLATION_LANGUAGES.find((l) => l.value === activeCode);
        targetLabel = lang?.label ?? activeCode ?? 'English';
        finalOutput = runLocalTranslationFallback(polished, activeCode ?? 'en', targetLabel);
        lastFailedTranslationRef.current = {
          rawText: raw,
          label: targetLabel,
          code: activeCode ?? 'en',
        };
      }

      const resolvedWorkflow: HistoryEntry['workflow'] =
        params.workflow === 'agent_auto' ? 'agent' : params.workflow;

      const entry = addHistoryEntry({
        timestamp: Math.floor(Date.now() / 1000),
        transcription: raw,
        postProcessed: finalOutput,
        workflow: resolvedWorkflow,
        durationMs: params.durationMs,
        charCount: finalOutput.length,
        targetLabel: params.agentTarget?.name ?? targetLabel,
        audioDataUrl: params.audioDataUrl,
      });

      if ((params.workflow === 'agent' || params.workflow === 'agent_auto') && params.agentTarget) {
        deliverToAgent(finalOutput, params.agentTarget);
      } else {
        hideOverlay();
      }

      return { output: finalOutput, entry };
    },
    [
      addHistoryEntry,
      deliverToAgent,
      hideOverlay,
      state.rules,
      state.settings.active_scene_id,
      state.settings.append_trailing_space,
      state.settings.audio_feedback,
      state.settings.audio_feedback_volume,
      state.settings.filler_word_removal_enabled,
      state.settings.polish_style,
      state.settings.scenes,
      state.settings.sound_theme,
      state.settings.translation_active_target,
      state.settings.translation_targets,
      state.words,
    ],
  );

  // Recover a saved vault recording into History / Agent delivery
  const recoverRecordingItem = useCallback(
    (
      id: string,
      transcriptOverride?: string,
      overrideAgent?: AgentTarget | null,
    ): { ok: boolean; output?: string } => {
      const targetItem = state.recoveryVault.find((r) => r.id === id);
      if (!targetItem) return { ok: false };

      const textToRecover = (transcriptOverride ?? targetItem.partialTranscript).trim();
      if (!textToRecover) {
        return { ok: false };
      }

      let resolvedAgent: AgentTarget | null = overrideAgent ?? null;
      let routeReason: string | undefined;

      if (!resolvedAgent && targetItem.targetAgentId) {
        resolvedAgent = state.agents.find((a) => a.id === targetItem.targetAgentId) ?? null;
      }
      if (!resolvedAgent && targetItem.workflow === 'agent_auto') {
        const decision = evaluateAutoRoute(textToRecover);
        resolvedAgent = decision.target;
        routeReason = decision.reason;
      }

      let output = '';
      if (resolvedAgent && (targetItem.workflow === 'agent' || targetItem.workflow === 'agent_auto')) {
        const res = dispatchRoutedAgent({
          rawText: textToRecover,
          prompt: evaluateAutoRoute(textToRecover).rewrittenPrompt || textToRecover,
          target: resolvedAgent,
          durationMs: targetItem.durationMs || 3000,
          routeReason,
        });
        output = res.output;
      } else {
        const res = processTranscript({
          rawText: textToRecover,
          durationMs: targetItem.durationMs || 3000,
          workflow: targetItem.workflow === 'translate' ? 'translate' : 'dictation',
        });
        output = res.output;
      }

      deleteRecoveredRecording(id);
      return { ok: true, output };
    },
    [
      deleteRecoveredRecording,
      dispatchRoutedAgent,
      evaluateAutoRoute,
      processTranscript,
      state.agents,
      state.recoveryVault,
    ],
  );

  const retryLastTranslation = useCallback(() => {
    const failed = lastFailedTranslationRef.current ?? {
      rawText: '我们下周三开会确认发布计划',
      label: 'English',
      code: 'en',
    };
    showOverlay({ type: 'translating', label: failed.label });
    window.setTimeout(() => {
      const translated = runLocalTranslationFallback(failed.rawText, failed.code, failed.label);
      addHistoryEntry({
        timestamp: Math.floor(Date.now() / 1000),
        transcription: failed.rawText,
        postProcessed: translated,
        workflow: 'translate',
        durationMs: 3200,
        charCount: translated.length,
        targetLabel: failed.label,
      });
      hideOverlay();
    }, 700);
  }, [addHistoryEntry, hideOverlay, showOverlay]);

  const resetAllData = useCallback(() => {
    localStorage.removeItem(STORAGE_KEY);
    void clearAllAudioBlobs();
    setState({
      settings: DEFAULT_SETTINGS,
      history: INITIAL_HISTORY,
      words: INITIAL_WORDS,
      rules: INITIAL_RULES,
      rejections: [],
      agents: INITIAL_AGENTS,
      models: DEFAULT_MODELS,
      learningAttempts: INITIAL_LEARNING_ATTEMPTS,
      recoveryVault: [],
    });
  }, []);

  const value = useMemo<AppContextValue>(
    () => ({
      settings: state.settings,
      updateSettings,
      updateBinding,
      resetBinding,
      t,
      isOnline,
      history: state.history,
      addHistoryEntry,
      deleteHistoryEntry,
      retranscribeHistoryEntry,
      recoveryVault: state.recoveryVault,
      checkpointRecordingDraft,
      rescueRecording,
      discardRecordingDraft,
      updateRecoveredTranscript,
      recoverRecordingItem,
      deleteRecoveredRecording,
      getRecoveredAudioBlob,
      words: state.words,
      rules: state.rules,
      rejections: state.rejections,
      addWord,
      updateWord,
      deleteWord,
      addRule,
      updateRule,
      toggleRule,
      deleteRule,
      forgetRejection,
      clearRejections,
      undoLearnedRule,
      importDictionaryJson,
      exportDictionaryJson,
      addScene,
      updateScene,
      deleteScene,
      restoreBuiltInScenes,
      setActiveScene,
      addTranslationTarget,
      removeTranslationTarget,
      setActiveTranslationTarget,
      models: state.models,
      downloadProgress,
      selectModel,
      downloadModel,
      cancelModelDownload,
      deleteModel,
      rescanModels,
      agents: state.agents,
      agentDelivery,
      saveAgent,
      removeAgent,
      deliverToAgent,
      clearAgentStatus,
      evaluateAutoRoute,
      dispatchRoutedAgent,
      learningAttempts: state.learningAttempts,
      recordLearningFromEdit,
      clearLearningAttempts,
      overlay,
      levels,
      showOverlay,
      hideOverlay,
      setLevels,
      dictationSession,
      openDictation,
      closeDictation,
      processTranscript,
      retryLastTranslation,
      resetAllData,
    }),
    [
      state,
      updateSettings,
      updateBinding,
      resetBinding,
      t,
      isOnline,
      addHistoryEntry,
      deleteHistoryEntry,
      retranscribeHistoryEntry,
      checkpointRecordingDraft,
      rescueRecording,
      discardRecordingDraft,
      updateRecoveredTranscript,
      recoverRecordingItem,
      deleteRecoveredRecording,
      getRecoveredAudioBlob,
      addWord,
      updateWord,
      deleteWord,
      addRule,
      updateRule,
      toggleRule,
      deleteRule,
      forgetRejection,
      clearRejections,
      undoLearnedRule,
      importDictionaryJson,
      exportDictionaryJson,
      addScene,
      updateScene,
      deleteScene,
      restoreBuiltInScenes,
      setActiveScene,
      addTranslationTarget,
      removeTranslationTarget,
      setActiveTranslationTarget,
      downloadProgress,
      selectModel,
      downloadModel,
      cancelModelDownload,
      deleteModel,
      rescanModels,
      agentDelivery,
      saveAgent,
      removeAgent,
      deliverToAgent,
      clearAgentStatus,
      evaluateAutoRoute,
      dispatchRoutedAgent,
      recordLearningFromEdit,
      clearLearningAttempts,
      overlay,
      levels,
      showOverlay,
      hideOverlay,
      setLevels,
      dictationSession,
      openDictation,
      closeDictation,
      processTranscript,
      retryLastTranslation,
      resetAllData,
    ],
  );

  return <AppContext.Provider value={value}>{children}</AppContext.Provider>;
};

export function useAppStore(): AppContextValue {
  const ctx = useContext(AppContext);
  if (!ctx) throw new Error('useAppStore must be used inside AppStoreProvider');
  return ctx;
}
