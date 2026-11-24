import React, { useEffect, useRef, useState } from 'react';
import { AudioWaveform } from 'lucide-react';

/**
 * Machined linear hardware slide switch (Braun / Dieter Rams aesthetic, sharp 2px geometry).
 */
export const TactileSwitch: React.FC<{
  checked: boolean;
  onChange: (next: boolean) => void;
  ariaLabel?: string;
  size?: 'sm' | 'md';
}> = ({ checked, onChange, ariaLabel, size = 'md' }) => {
  const trackW = size === 'sm' ? 'w-8 h-[18px]' : 'w-10 h-[22px]';
  const thumbSize = size === 'sm' ? 'w-3 h-3' : 'w-3.5 h-3.5';
  const translate =
    size === 'sm'
      ? checked
        ? 'translate-x-[17px]'
        : 'translate-x-[3px]'
      : checked
        ? 'translate-x-[22px]'
        : 'translate-x-[4px]';

  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={ariaLabel}
      onClick={() => onChange(!checked)}
      className={`${trackW} relative inline-flex items-center rounded-[2px] shrink-0 cursor-pointer transition-colors duration-150 focus-visible:outline-2 focus-visible:outline-offset-2`}
      style={{
        backgroundColor: checked ? 'var(--accent)' : 'var(--border-strong)',
        outlineColor: 'var(--accent)',
      }}
    >
      <span
        className={`${thumbSize} ${translate} inline-block rounded-[1px] bg-white shadow-xs transition-transform duration-150`}
        style={{ transitionTimingFunction: 'cubic-bezier(0.16, 1, 0.3, 1)' }}
      />
    </button>
  );
};

/**
 * Crisp sculpted keycap shortcut display (e.g. "Alt+Space" -> [Alt] [Space]).
 */
export const KeycapCombo: React.FC<{ combo: string; muted?: boolean }> = ({ combo, muted }) => {
  if (!combo) return null;
  const keys = combo.split('+').filter(Boolean);
  return (
    <span className="inline-flex items-center gap-1 shrink-0">
      {keys.map((k, idx) => (
        <kbd
          key={`${k}-${idx}`}
          className="font-mono-tabular inline-flex items-center justify-center min-w-[22px] px-1.5 py-[2px] text-[11px] font-medium rounded-[2px] leading-tight"
          style={{
            backgroundColor: muted ? 'transparent' : 'var(--bg-surface)',
            color: muted ? 'var(--ink-secondary)' : 'var(--ink-primary)',
            border: '1px solid var(--border-strong)',
          }}
        >
          {k}
        </kbd>
      ))}
    </span>
  );
};

/**
 * 60fps HTML5 Canvas Acoustic Studio Oscilloscope / Discrete Meter Visualizer.
 * Reacts to real microphone FFT buckets when active, or renders a serene
 * harmonic breathing wave at rest. Respects prefers-reduced-motion.
 */
export const AcousticCanvas: React.FC<{
  levels?: number[];
  active?: boolean;
  height?: number;
  barCount?: number;
}> = ({ levels, active = false, height = 72, barCount = 44 }) => {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const levelsRef = useRef<number[]>(levels ?? []);
  levelsRef.current = levels ?? [];

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    let rafId = 0;

    const draw = (time: number) => {
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      const rect = canvas.getBoundingClientRect();
      const width = Math.max(120, rect.width);
      const h = rect.height || height;

      if (canvas.width !== Math.round(width * dpr) || canvas.height !== Math.round(h * dpr)) {
        canvas.width = Math.round(width * dpr);
        canvas.height = Math.round(h * dpr);
      }

      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, width, h);

      const styles = getComputedStyle(document.documentElement);
      const accent = styles.getPropertyValue('--accent').trim() || '#ff552b';
      const inkTertiary = styles.getPropertyValue('--ink-tertiary').trim() || '#656c76';
      const hairline = styles.getPropertyValue('--border-hairline').trim() || 'rgba(255,255,255,0.08)';

      const midY = h / 2;

      // Architectural center datum hairline
      ctx.strokeStyle = hairline;
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(0, midY);
      ctx.lineTo(width, midY);
      ctx.stroke();

      const gap = width / barCount;
      const barW = Math.max(2, Math.min(3, gap * 0.4));
      const t = reducedMotion ? 0 : time * 0.0022;
      const live = levelsRef.current;
      const centerIndex = (barCount - 1) / 2;

      for (let i = 0; i < barCount; i++) {
        const normDist = Math.abs(i - centerIndex) / Math.max(1, centerIndex);
        const envelope = Math.cos(normDist * Math.PI * 0.48);

        let amp: number;
        if (active && live.length > 0) {
          const bucket = Math.min(live.length - 1, Math.floor(normDist * live.length));
          const liveVal = live[bucket] ?? 0.15;
          amp = Math.max(0.1, liveVal * (0.55 + envelope * 0.65));
        } else {
          const wave1 = Math.sin(t + i * 0.28) * 0.5 + 0.5;
          const wave2 = Math.cos(t * 0.7 - i * 0.17) * 0.5 + 0.5;
          amp = (0.1 + (wave1 * 0.55 + wave2 * 0.45) * 0.42) * envelope;
        }

        const barH = Math.max(4, amp * (h * 0.78));
        const x = i * gap + (gap - barW) / 2;
        const y = midY - barH / 2;

        const isCenterBand = normDist < (active ? 0.68 : 0.34);
        ctx.fillStyle = isCenterBand ? accent : inkTertiary;
        ctx.globalAlpha = active
          ? isCenterBand
            ? 0.92
            : 0.42
          : isCenterBand
            ? 0.8 - normDist * 0.4
            : 0.28;

        ctx.fillRect(x, y, barW, barH);
      }
      ctx.globalAlpha = 1;

      if (!reducedMotion) {
        rafId = requestAnimationFrame(draw);
      }
    };

    rafId = requestAnimationFrame(draw);
    return () => cancelAnimationFrame(rafId);
  }, [active, barCount, height]);

  return (
    <canvas
      ref={canvasRef}
      style={{ height }}
      className="w-full block"
      aria-label="Live acoustic waveform visualizer"
    />
  );
};

/**
 * Zero-broken-image wrapper with styled architectural fallback container.
 */
export const ResilientImage: React.FC<{
  src: string;
  alt: string;
  className?: string;
  fallbackLabel?: string;
}> = ({ src, alt, className = '', fallbackLabel }) => {
  const [failed, setFailed] = useState(false);

  if (failed) {
    return (
      <div
        className={`flex flex-col items-center justify-center gap-2 ${className}`}
        style={{
          background:
            'radial-gradient(circle at 30% 25%, rgba(255,85,43,0.16), transparent 60%), var(--bg-well)',
        }}
      >
        <AudioWaveform className="w-8 h-8 opacity-60" style={{ color: 'var(--accent)' }} />
        {fallbackLabel && (
          <span className="text-[12px]" style={{ color: 'var(--ink-secondary)' }}>
            {fallbackLabel}
          </span>
        )}
      </div>
    );
  }

  return (
    <img
      src={src}
      alt={alt}
      referrerPolicy="no-referrer"
      onError={() => setFailed(true)}
      className={className}
    />
  );
};
