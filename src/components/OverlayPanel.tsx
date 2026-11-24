import React, { useState } from 'react';
import {
  AlertTriangle,
  ArrowUpRight,
  Check,
  CheckCircle2,
  Info,
  Loader2,
  Mic,
  X,
} from 'lucide-react';
import { useAppStore } from '../store/AppStore';

interface OverlayPanelProps {
  onFinishRecording?: () => void;
  onDiscardRecording?: () => void;
}

export const OverlayPanel: React.FC<OverlayPanelProps> = ({
  onFinishRecording,
  onDiscardRecording,
}) => {
  const { overlay, levels, settings, t, hideOverlay, retryLastTranslation, undoLearnedRule } =
    useAppStore();
  const [hovering, setHovering] = useState(false);

  if (overlay.type === 'hidden' || settings.overlay_style === 'none') {
    return null;
  }

  const isRecording = overlay.type === 'recording' || overlay.type === 'streaming';
  const positionClass = settings.overlay_position === 'top' ? 'top-5' : 'bottom-5';
  const hasSignal = Math.max(...levels) > 0.22;

  return (
    <div
      className={`fixed left-1/2 -translate-x-1/2 ${positionClass} z-50 flex flex-col items-center gap-1.5 pointer-events-auto`}
    >
      <div
        onMouseEnter={() => setHovering(true)}
        onMouseLeave={() => setHovering(false)}
        className="glass-surface px-4 flex items-center gap-3 transition-all duration-150 select-none"
        style={{
          minHeight:
            overlay.type === 'translation_failed' ||
            overlay.type === 'notice' ||
            overlay.type === 'agent_message'
              ? 54
              : 46,
          minWidth: isRecording ? 328 : 288,
          maxWidth: 480,
        }}
      >
        {isRecording && (
          <div className="relative w-full flex items-center justify-between gap-3 py-2">
            {/* Acoustic Waveform HUD */}
            <div
              className={`w-full flex items-center justify-between gap-3 transition-opacity duration-150 ${
                hovering ? 'opacity-0 pointer-events-none' : 'opacity-100'
              }`}
            >
              <div className="flex items-center gap-1.5 text-[13px] font-medium truncate max-w-[120px]">
                {overlay.type === 'recording' && overlay.workflow === 'agent' ? (
                  <ArrowUpRight className="w-4 h-4 shrink-0" style={{ color: 'var(--accent)' }} />
                ) : (
                  <Mic className="w-4 h-4 shrink-0" style={{ color: 'var(--accent)' }} />
                )}
                <span className="truncate">{overlay.targetName}</span>
              </div>

              <div className="flex items-center justify-center gap-[3px] h-7">
                {levels.map((lvl, i) => (
                  <span
                    key={i}
                    className="w-[2.5px] transition-all duration-100"
                    style={{
                      height: hasSignal ? Math.max(4, Math.round(lvl * 26)) : 3,
                      backgroundColor: hasSignal ? 'var(--accent)' : 'var(--ink-tertiary)',
                      opacity: hasSignal ? 0.95 : 0.45,
                    }}
                  />
                ))}
              </div>

              <span
                className="font-mono-tabular text-[11px] shrink-0"
                style={{ color: 'var(--ink-secondary)' }}
              >
                REC
              </span>
            </div>

            {/* Sharp Hover Finish / Discard Action Deck */}
            <div
              className={`absolute inset-0 flex items-center gap-2 transition-opacity duration-150 ${
                hovering ? 'opacity-100' : 'opacity-0 pointer-events-none'
              }`}
            >
              <button
                type="button"
                onClick={() => {
                  if (onFinishRecording) onFinishRecording();
                  else hideOverlay();
                }}
                className="btn-accent flex-1 h-8 text-[12.5px] flex items-center justify-center gap-1.5 cursor-pointer"
              >
                <Check className="w-3.5 h-3.5" />
                <span>{t('overlay.finish')}</span>
              </button>
              <button
                type="button"
                onClick={() => {
                  if (onDiscardRecording) onDiscardRecording();
                  else hideOverlay();
                }}
                className="flex-1 h-8 rounded-[2px] text-[12.5px] font-semibold text-white flex items-center justify-center gap-1.5 cursor-pointer"
                style={{ backgroundColor: 'var(--status-err)' }}
              >
                <X className="w-3.5 h-3.5" />
                <span>{t('overlay.discard')}</span>
              </button>
            </div>
          </div>
        )}

        {overlay.type === 'transcribing' && (
          <div className="flex items-center gap-2.5 text-[13px] py-2 w-full">
            <Loader2 className="w-4 h-4 animate-spin shrink-0" style={{ color: 'var(--accent)' }} />
            <span>{t('overlay.transcribing')}</span>
          </div>
        )}

        {overlay.type === 'processing' && (
          <div className="flex items-center gap-2.5 text-[13px] py-2 w-full">
            <Loader2 className="w-4 h-4 animate-spin shrink-0" style={{ color: 'var(--accent)' }} />
            <span className="truncate">{overlay.label ?? t('overlay.processing')}</span>
          </div>
        )}

        {overlay.type === 'translating' && (
          <div className="flex items-center gap-2.5 text-[13px] py-2 w-full">
            <Loader2 className="w-4 h-4 animate-spin shrink-0" style={{ color: 'var(--accent)' }} />
            <span className="truncate">
              {t('overlay.translating', { label: overlay.label ?? 'English' })}
            </span>
          </div>
        )}

        {overlay.type === 'translation_failed' && (
          <div className="flex items-center justify-between gap-3 py-2.5 w-full">
            <div className="flex items-center gap-2 text-[13px]">
              <AlertTriangle
                className="w-4 h-4 shrink-0"
                style={{ color: 'var(--status-warn)' }}
              />
              <span>{t('overlay.translationFailed', { label: overlay.label })}</span>
            </div>
            <div className="flex items-center gap-1.5 shrink-0">
              <button
                type="button"
                onClick={retryLastTranslation}
                className="btn-accent text-[12px] h-7 px-2.5 cursor-pointer"
              >
                {t('overlay.retry')}
              </button>
              <button
                type="button"
                onClick={hideOverlay}
                className="p-1 hover:bg-[var(--bg-hover)] cursor-pointer"
                style={{ color: 'var(--ink-secondary)' }}
                aria-label="Dismiss"
              >
                <X className="w-3.5 h-3.5" />
              </button>
            </div>
          </div>
        )}

        {overlay.type === 'notice' && (
          <div className="flex items-center justify-between gap-3 py-2.5 w-full">
            <div className="flex items-center gap-2 text-[13px]">
              <Info className="w-4 h-4 shrink-0" style={{ color: 'var(--ink-secondary)' }} />
              <span>{overlay.message ?? t('overlay.noTarget')}</span>
            </div>
            <button
              type="button"
              onClick={hideOverlay}
              className="p-1 hover:bg-[var(--bg-hover)] cursor-pointer"
              style={{ color: 'var(--ink-secondary)' }}
              aria-label="Dismiss"
            >
              <X className="w-3.5 h-3.5" />
            </button>
          </div>
        )}

        {overlay.type === 'learned' && (
          <div className="flex items-center justify-between gap-3 py-2 w-full">
            <div className="flex items-center gap-2 text-[13px] min-w-0">
              <CheckCircle2
                className="w-4 h-4 shrink-0"
                style={{ color: 'var(--status-ok)' }}
              />
              <span className="truncate">
                {t('overlay.learned', { replacement: overlay.replacement })}
              </span>
            </div>
            <button
              type="button"
              onClick={() => undoLearnedRule(overlay.ruleId, overlay.pattern)}
              className="btn-ghost text-[12px] h-7 px-2.5 shrink-0 cursor-pointer"
            >
              {t('overlay.undo')}
            </button>
          </div>
        )}

        {overlay.type === 'agent_message' && (
          <div className="flex items-center justify-between gap-3 py-2.5 w-full">
            <div className="flex items-center gap-2 text-[13px]">
              {overlay.failed ? (
                <AlertTriangle
                  className="w-4 h-4 shrink-0"
                  style={{ color: 'var(--status-warn)' }}
                />
              ) : (
                <CheckCircle2
                  className="w-4 h-4 shrink-0"
                  style={{ color: 'var(--accent)' }}
                />
              )}
              <span>{overlay.text}</span>
            </div>
            <button
              type="button"
              onClick={hideOverlay}
              className="p-1 hover:bg-[var(--bg-hover)] cursor-pointer"
              style={{ color: 'var(--ink-secondary)' }}
              aria-label="Dismiss"
            >
              <X className="w-3.5 h-3.5" />
            </button>
          </div>
        )}
      </div>

      {isRecording && (
        <div
          className={`text-[11px] transition-opacity duration-150 ${
            hovering ? 'opacity-0' : 'opacity-100'
          }`}
          style={{ color: 'var(--ink-secondary)' }}
        >
          {t('overlay.recordingHint')}
        </div>
      )}
    </div>
  );
};
