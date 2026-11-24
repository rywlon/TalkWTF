export type AppSection = 'dashboard' | 'agents' | 'library' | 'settings';

export type LibraryTab = 'history' | 'recovery' | 'dictionary';

export type SettingsPane =
  | 'general'
  | 'personalization'
  | 'models'
  | 'audio'
  | 'advanced'
  | 'debug'
  | 'about';

export type ThemeMode = 'system' | 'light' | 'dark';
export type ShortcutActivation = 'hold_or_toggle' | 'push_to_talk' | 'toggle';
export type OverlayStyle = 'none' | 'minimal' | 'live';
export type OverlayPosition = 'top' | 'bottom';
export type SoundTheme = 'marimba' | 'pop' | 'custom';
export type PasteMethod = 'ctrl_v' | 'shift_insert' | 'ctrl_shift_v' | 'direct' | 'none';
export type ClipboardHandling = 'dont_modify' | 'copy_to_clipboard';
export type AutoSubmitKey = 'off' | 'enter' | 'ctrl_enter' | 'cmd_enter';
export type VadBackend = 'silero' | 'earshot';
export type ModelUnloadTimeout =
  | 'immediately'
  | 'sec15'
  | 'min2'
  | 'min5'
  | 'min10'
  | 'min15'
  | 'hour1'
  | 'never';
export type RecordingRetentionPeriod =
  | 'preserve_limit'
  | 'never'
  | 'days3'
  | 'weeks2'
  | 'month1'
  | 'months3';
export type LogLevel = 'trace' | 'debug' | 'info' | 'warn' | 'error';

export type DictationWorkflow = 'dictation' | 'translate' | 'agent' | 'agent_auto';

export interface ShortcutBinding {
  id: string;
  name: string;
  description: string;
  default_binding: string;
  current_binding: string;
}

export interface Scene {
  id: string;
  name: string;
  description: string;
  prompt: string;
  created_at: string;
  updated_at: string;
}

export interface PostProcessProvider {
  id: string;
  label: string;
  base_url: string;
  allow_base_url_edit: boolean;
  requires_api_key: boolean;
}

export interface PolishStyleOption {
  value: string;
  label: string;
  description: string;
}

export interface LanguageOption {
  value: string;
  label: string;
}

export type AgentChoice = 'Codex' | 'Claude Code' | 'OpenCode' | 'Cursor' | '其他本地 Agent';

export interface AgentTarget {
  id: string;
  name: string;
  kind: 'codex' | 'http' | 'command';
  provider: AgentChoice;
  address: string;
  conversation: string;
  workingDirectory?: string;
  bindingID: string;
  /** Wake aliases for 0ms deterministic routing (e.g. ["后端", "codex", "api"]) */
  aliases?: string[];
  /** Short capability manifest describing what tasks belong to this Agent */
  scope?: string;
  /** Last dispatched unix ms timestamp for sticky session continuity */
  lastUsedAt?: number;
}

export interface AgentRouteCandidate {
  agent: AgentTarget;
  score: number;
  reason: string;
}

export interface AgentRouteDecision {
  target: AgentTarget | null;
  confidence: number;
  tier: 'rule' | 'sticky' | 'semantic' | 'ambiguous' | 'none';
  reason: string;
  rewrittenPrompt: string;
  candidates: AgentRouteCandidate[];
  autoDispatch: boolean;
}

export type RecoveryStatus =
  | 'recording_draft'
  | 'interrupted'
  | 'offline_pending'
  | 'transcribe_failed';

export interface RecoveredRecording {
  id: string;
  createdAt: number; // unix ms
  updatedAt: number; // unix ms
  durationMs: number;
  sizeBytes: number;
  mimeType: string;
  hasAudioBlob: boolean;
  workflow: DictationWorkflow;
  targetAgentId?: string;
  targetName?: string;
  partialTranscript: string;
  status: RecoveryStatus;
  failureReason: string;
}

export interface HistoryEntry {
  id: number;
  timestamp: number; // unix seconds
  transcription: string;
  postProcessed: string | null;
  workflow: 'dictation' | 'translate' | 'agent';
  durationMs: number;
  charCount: number;
  targetLabel?: string;
  audioDataUrl?: string;
}

export interface DictionaryWord {
  id: number;
  word: string;
  createdAt: string;
}

export interface CorrectionRule {
  id: number;
  pattern: string;
  replacement: string;
  enabled: boolean;
  source: 'manual' | 'learned';
  createdAt: string;
}

export interface LearningAttempt {
  id: number;
  pasted: string;
  finalText: string;
  outcome: 'learned' | 'skipped';
  source: string;
  reason: string;
  strategy?: string;
  createdAt: string;
}

export interface AsrModelInfo {
  id: string;
  name: string;
  description: string;
  parameters: string;
  sizeMb: number;
  languages: number;
  streaming: boolean;
  recommended: boolean;
  isDownloaded: boolean;
}

export type OverlayState =
  | { type: 'hidden' }
  | { type: 'recording'; targetName: string; workflow: DictationWorkflow }
  | { type: 'streaming'; targetName: string; liveText?: string }
  | { type: 'transcribing' }
  | { type: 'processing'; label?: string }
  | { type: 'translating'; label?: string }
  | { type: 'translation_failed'; label: string; rawText?: string }
  | { type: 'notice'; kind: 'no_target' | 'error'; message?: string }
  | { type: 'learned'; pattern: string; replacement: string; count: number; ruleId?: number }
  | { type: 'agent_message'; text: string; failed: boolean }
  | { type: 'audio_rescued'; vaultId: string; reason: string; durationMs: number }
  | { type: 'routing_confirm'; decision: AgentRouteDecision };

export interface AppSettings {
  app_language: 'zh' | 'en';
  selected_language: string;
  theme: ThemeMode;
  shortcut_activation: ShortcutActivation;
  hold_threshold_ms: number;
  bindings: Record<string, ShortcutBinding>;
  start_hidden: boolean;
  autostart_enabled: boolean;
  overlay_style: OverlayStyle;
  overlay_position: OverlayPosition;
  selected_microphone: string;
  selected_channel: number;
  always_on_microphone: boolean;
  mute_while_recording: boolean;
  selected_output_device: string;
  audio_feedback: boolean;
  sound_theme: SoundTheme;
  audio_feedback_volume: number;
  paste_method: PasteMethod;
  paste_delay_ms: number;
  paste_delay_after_ms: number;
  reliable_paste: boolean;
  clipboard_handling: ClipboardHandling;
  auto_submit_key: AutoSubmitKey;
  append_trailing_space: boolean;
  vad_enabled: boolean;
  vad_backend: VadBackend;
  filler_word_removal_enabled: boolean;
  learn_from_edits: boolean;
  translate_to_english: boolean;
  word_correction_threshold: number;
  model_unload_timeout: ModelUnloadTimeout;
  history_limit: number;
  recording_retention_period: RecordingRetentionPeriod;
  experimental_enabled: boolean;
  lazy_stream_close: boolean;
  transcribe_accelerator: string;
  ort_accelerator: string;
  selected_model: string;
  log_level: LogLevel;
  debug_mode: boolean;
  extra_recording_buffer_ms: number;
  update_checks_enabled: boolean;
  keyboard_implementation: 'handy_keys' | 'tauri';
  post_process_provider_id: string;
  post_process_providers: PostProcessProvider[];
  post_process_models: Record<string, string>;
  post_process_thinking: boolean;
  polish_style: string;
  scenes: Scene[];
  active_scene_id: string | null;
  translation_targets: string[];
  translation_active_target: string | null;
}
