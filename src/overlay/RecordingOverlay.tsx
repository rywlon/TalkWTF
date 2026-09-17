import { listen } from "@tauri-apps/api/event";
import React, { useEffect, useLayoutEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import "./RecordingOverlay.css";
import { commands, events } from "@/bindings";
import type {
  StreamPhase,
  StreamPhaseEvent,
  StreamTextEvent,
  StreamWorkKind,
} from "@/bindings";
import i18n, { syncLanguageFromSettings } from "@/i18n";
import { getLanguageDirection } from "@/lib/utils/rtl";

/// What the backend learned from the edit, shown in the notice with an undo.
type LearnedNotice = { pattern: string; replacement: string; count: number };

type OverlayState =
  | "recording"
  | "streaming"
  | "transcribing"
  | "processing"
  | "translating"
  | "translation_failed"
  | "notice"
  | "learned";

/** How long the "added to dictionary" notice stays before hiding itself. */
const LEARNED_NOTICE_MS = 8000;

/** How long the translation failure / notice cards stay before hiding. */
const TRANSLATION_NOTICE_MS = 8000;

// Number of reactive bars in the waveform (the simple, smoothed style shared by
// every overlay form). Mic levels arrive as 16 FFT buckets; we take the first N.
const WAVE_BARS = 9;

const RecordingOverlay: React.FC = () => {
  const { t } = useTranslation();
  const [isVisible, setIsVisible] = useState(false);
  const [state, setState] = useState<OverlayState>("recording");
  // `Stream::play()` returning does not mean hardware callbacks are flowing.
  // Stay visually in an arming state until the backend processes the first
  // actual microphone sample chunk.
  const [captureReady, setCaptureReady] = useState(false);
  const [levels, setLevels] = useState<number[]>(Array(WAVE_BARS).fill(0));
  const [streamText, setStreamText] = useState<StreamTextEvent>({
    committed: "",
    tentative: "",
  });
  const [phase, setPhase] = useState<StreamPhase>("listening");
  const [workKind, setWorkKind] = useState<StreamWorkKind>("transcribing");
  const [elapsed, setElapsed] = useState(0);
  // Bumped on each new streaming session so the Live card remounts fresh (replays
  // the pop-in, and never animates in from the previous panel's open size).
  const [session, setSession] = useState(0);
  // Overlay placement (top vs bottom of the screen). The Live panel grows downward
  // from a top overlay (oldest line under the pill) and upward from a bottom one.
  const [position, setPosition] = useState<"top" | "bottom">("bottom");
  // True once live text overflows the cap. A top overlay fades its top edge only
  // while overflowing, so the resting first line stays crisp flush under the pill.
  const [overflowing, setOverflowing] = useState(false);
  // The correction we just learned, shown with an undo button.
  const [learned, setLearned] = useState<LearnedNotice | null>(null);
  // Translate workflow: the target language label, carried on the show-overlay
  // payload so the recording pill can name what it will translate into.
  const [translationLabel, setTranslationLabel] = useState<string | null>(null);
  // Translation failure target (for the message) and the "no target configured"
  // notice kind.
  const [failureLabel, setFailureLabel] = useState<string>("");
  const [noticeKind, setNoticeKind] = useState<string>("");

  const smoothedLevelsRef = useRef<number[]>(Array(16).fill(0));
  // Live-text scroll-back: the text region "sticks" to the newest line while the
  // user is at the bottom; if they scroll up to read history, auto-follow pauses
  // until they scroll back down.
  const capRef = useRef<HTMLDivElement>(null);
  const pinnedRef = useRef(true);
  const direction = getLanguageDirection(i18n.language);

  useEffect(() => {
    const setupEventListeners = async () => {
      const unlistenShow = await listen("show-overlay", async (event) => {
        // Normally just the state name; the learned notice arrives as
        // `{ state, notice }` so it travels on this channel instead of an event of
        // its own, which the overlay did not process until the app was activated.
        const raw = event.payload as
          | OverlayState
          | {
              state: OverlayState;
              notice?: LearnedNotice & { label?: string; kind?: string };
              translation?: { label?: string };
            };
        const overlayState = typeof raw === "string" ? raw : raw.state;
        // `notice` is overloaded: the learned notice carries pattern/replacement,
        // the translate cards carry a target label or a notice kind.
        if (typeof raw !== "string") {
          if (overlayState === "learned" && raw.notice) {
            setLearned(raw.notice as LearnedNotice);
          }
          if (overlayState === "translation_failed") {
            setFailureLabel(raw.notice?.label ?? "");
          }
          if (overlayState === "notice") {
            setNoticeKind(raw.notice?.kind ?? "");
          }
          setTranslationLabel(raw.translation?.label ?? null);
        } else {
          setTranslationLabel(null);
        }
        // Reset synchronously before settings I/O. A fast microphone can emit
        // recording-ready while the awaits below are in flight; resetting after
        // them would overwrite that event and leave the overlay stuck arming.
        if (overlayState === "recording" || overlayState === "streaming") {
          setCaptureReady(false);
          smoothedLevelsRef.current = Array(16).fill(0);
          setLevels(Array(WAVE_BARS).fill(0));
          setStreamText({ committed: "", tentative: "" });
        }

        await syncLanguageFromSettings();
        // The Live panel flows downward from a top overlay and upward from a
        // bottom one; read the placement so the layout can flip to match.
        try {
          const settings = await commands.getAppSettings();
          if (settings.status === "ok") {
            setPosition(
              settings.data.overlay_position === "top" ? "top" : "bottom",
            );
          }
        } catch {
          // Keep the previous/default placement if settings can't be read.
        }
        setState(overlayState);
        if (overlayState === "streaming") {
          setPhase("listening");
          setWorkKind("transcribing");
          setElapsed(0);
          setSession((s) => s + 1); // remount the card fresh for this session
        }
        setIsVisible(true);
      });

      const unlistenHide = await listen("hide-overlay", () => {
        setIsVisible(false);
        setCaptureReady(false);
      });

      const unlistenReady = await listen("recording-ready", () => {
        setElapsed(0);
        setCaptureReady(true);
      });

      const unlistenLevel = await listen<number[]>("mic-level", (event) => {
        const newLevels = event.payload as number[];
        // Exponential smoothing across the 16 buckets, then take the first N
        // bars for the shared waveform.
        const smoothed = smoothedLevelsRef.current.map((prev, i) => {
          const target = newLevels[i] || 0;
          return prev * 0.7 + target * 0.3;
        });
        smoothedLevelsRef.current = smoothed;
        setLevels(smoothed.slice(0, WAVE_BARS));
      });

      const unlistenStream = await events.streamTextEvent.listen((event) => {
        setStreamText(event.payload);
      });

      const unlistenPhase = await events.streamPhaseEvent.listen((event) => {
        const payload: StreamPhaseEvent = event.payload;
        setPhase(payload.phase);
        if (payload.kind) setWorkKind(payload.kind);
      });

      const unlistenLearned = await events.learnedCorrection.listen((event) => {
        setLearned(event.payload);
      });

      return () => {
        unlistenShow();
        unlistenHide();
        unlistenReady();
        unlistenLevel();
        unlistenStream();
        unlistenPhase();
        unlistenLearned();
      };
    };

    setupEventListeners();
  }, []);

  // The learned notice carries an undo affordance, so it hides itself instead of
  // waiting for the pipeline to finish.
  useEffect(() => {
    if (state !== "learned" || !isVisible) return;
    const id = setTimeout(() => {
      setLearned(null);
      commands.hideOverlay();
    }, LEARNED_NOTICE_MS);
    return () => clearTimeout(id);
  }, [state, isVisible]);

  // The translation failure / notice cards hide themselves like the learned
  // notice; the retry slot stays in memory so the user can still retry from the
  // settings page if the card is gone.
  useEffect(() => {
    if (state !== "translation_failed" && state !== "notice") return;
    if (!isVisible) return;
    const id = setTimeout(() => {
      commands.hideOverlay();
    }, TRANSLATION_NOTICE_MS);
    return () => clearTimeout(id);
  }, [state, isVisible]);

  // Elapsed capture timer starts only once microphone samples are flowing.
  useEffect(() => {
    if (state !== "streaming" || !isVisible || !captureReady) return;
    const id = setInterval(() => setElapsed((e) => e + 1), 1000);
    return () => clearInterval(id);
  }, [state, isVisible, captureReady]);

  // Stick to the bottom as text streams in — but only while pinned, so a user who
  // has scrolled up to read history isn't yanked back down by the next chunk.
  useLayoutEffect(() => {
    const el = capRef.current;
    if (!el) return;
    // Fade the top edge only once text actually overflows the cap.
    setOverflowing(el.scrollHeight > el.clientHeight + 1);
    if (pinnedRef.current) el.scrollTop = el.scrollHeight;
  }, [streamText]);

  // Each fresh streaming session starts pinned to the bottom, fade cleared.
  useEffect(() => {
    pinnedRef.current = true;
    setOverflowing(false);
  }, [session]);

  if (!isVisible) return null;

  // Re-pin when the user is within ~a line of the bottom; unpin otherwise.
  const handleStreamScroll = () => {
    const el = capRef.current;
    if (!el) return;
    pinnedRef.current = el.scrollHeight - el.scrollTop - el.clientHeight <= 16;
  };

  const fmtTime = (s: number) =>
    `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;

  // ---- Shared building blocks (one visual language for every overlay form) ----
  const waveform = (
    <div className={`swave ${captureReady ? "ready" : "arming"}`}>
      {levels.map((v, i) => (
        <i
          key={i}
          style={{
            height: `${Math.max(3, Math.min(18, 3 + Math.pow(v, 0.7) * 15))}px`,
          }}
        />
      ))}
    </div>
  );

  const cancelBtn = (
    <button
      className="sx"
      aria-label="cancel"
      onClick={() => commands.cancelOperation()}
    >
      <svg viewBox="0 0 16 16" aria-hidden="true">
        <path
          d="M4 4 L12 12 M12 4 L4 12"
          stroke="currentColor"
          strokeWidth="1.6"
          strokeLinecap="round"
        />
      </svg>
    </button>
  );

  // dot (left) | waveform (center) | timer + cancel (right) — same structure for
  // pill & panel, so the Live morph is a pure width change.
  const listeningRow = (
    showTimer: boolean,
    showCancel: boolean,
    label?: string,
  ) => (
    <div className="sbase">
      <div className="sbase-l">
        <span className={`sdot ${captureReady ? "ready" : "arming"}`} />
      </div>
      {waveform}
      <div className="sbase-r">
        {label && <span className="strans-label">{label}</span>}
        {showTimer && <span className="stimer">{fmtTime(elapsed)}</span>}
        {showCancel && cancelBtn}
      </div>
    </div>
  );

  // spinner (left) | label (center) | cancel (right) — same 3-zone grid as the
  // listening row, so the label is centered.
  const workingRow = (label: string, showCancel: boolean) => (
    <div className="sbase">
      <div className="sbase-l">
        <span className="sspinner" />
      </div>
      <span className="swork-label">{label}</span>
      <div className="sbase-r">{showCancel && cancelBtn}</div>
    </div>
  );

  // ---- Live overlay: a pill that sculpts open into a panel ----
  if (state === "streaming") {
    const hasText =
      streamText.committed.length > 0 || streamText.tentative.length > 0;
    const working = phase === "working";
    // Keep the panel open whenever there's text — even while finalizing — so the
    // transcript stays put under a working spinner instead of collapsing and
    // squishing the text mid-stream. Only fall back to the small working pill
    // when there was no text to preserve.
    const open = hasText;
    const collapsed = working && !hasText;

    return (
      <div dir={direction} className={`ov-stage ${position}`}>
        <div
          key={session}
          className={`scard ${open ? "open" : ""} ${collapsed ? "working" : ""} ${
            isVisible ? "" : "leaving"
          }`}
        >
          <div className="stext">
            <div className="stext-clip">
              <div
                className={`stext-cap ${overflowing ? "overflowing" : ""}`}
                ref={capRef}
                onScroll={handleStreamScroll}
              >
                <p>
                  <span className="committed">
                    {streamText.committed ? streamText.committed + " " : ""}
                  </span>
                  <span className="tentative">{streamText.tentative}</span>
                  {/* Drop the blinking caret once finalizing — it's no longer
                      capturing, and a static spinner conveys the work. */}
                  {!working && <span className="scaret" />}
                </p>
              </div>
            </div>
          </div>
          {working
            ? workingRow(
                workKind === "polishing"
                  ? t("overlay.processing")
                  : t("overlay.transcribing"),
                true,
              )
            : listeningRow(open, true)}
        </div>
      </div>
    );
  }

  // ---- Learned notice: we just wrote a correction into the dictionary. Shows
  // what was learned plus a one-click undo, then hides itself.
  if (state === "learned") {
    // The payload arrives on its own event; if it has not landed yet, render
    // nothing rather than falling through to the recording pill.
    if (!learned) return null;

    return (
      <div
        dir={direction}
        className={`ov-stage ${position} ov-fade ${isVisible ? "show" : ""}`}
      >
        <div className="scard learned">
          <div className="learned-row">
            <p className="learned-text">
              {learned.count > 1
                ? t("overlay.learned.titlePlural", { count: learned.count })
                : t("overlay.learned.title", {
                    pattern: learned.pattern,
                    replacement: learned.replacement,
                  })}
            </p>
            <button
              className="sx learned-undo"
              onClick={() => {
                setLearned(null);
                void commands.undoLastDictionaryLearning();
              }}
            >
              {t("overlay.learned.undo")}
            </button>
          </div>
        </div>
      </div>
    );
  }

  // ---- Translation failure: the LLM call failed. Never paste the untranslated
  // source; offer a retry of the same transcript instead.
  if (state === "translation_failed") {
    return (
      <div
        dir={direction}
        className={`ov-stage ${position} ov-fade ${isVisible ? "show" : ""}`}
      >
        <div className="scard learned">
          <div className="learned-row">
            <p className="learned-text">
              {t("overlay.translate.failed", { label: failureLabel })}
            </p>
            <button
              className="sx learned-undo"
              onClick={() => {
                commands.hideOverlay();
                void commands.retryLastTranslation();
              }}
            >
              {t("overlay.translate.retry")}
            </button>
          </div>
        </div>
      </div>
    );
  }

  // ---- Plain notice: currently only "no target language configured".
  if (state === "notice") {
    const message =
      noticeKind === "no_target"
        ? t("overlay.translate.noTarget")
        : t("overlay.translate.failed", { label: "" });
    return (
      <div
        dir={direction}
        className={`ov-stage ${position} ov-fade ${isVisible ? "show" : ""}`}
      >
        <div className="scard learned">
          <div className="learned-row">
            <p className="learned-text">{message}</p>
          </div>
        </div>
      </div>
    );
  }

  // ---- Minimal overlay: exactly one row at a time — waveform (recording), or a
  // spinner + label (transcribing / processing). Never both. The pill animates its
  // width between them; the cancel button is in both rows so it stays put.
  const working =
    state === "transcribing" ||
    state === "processing" ||
    state === "translating";
  const workLabel =
    state === "translating"
      ? t("overlay.translate.working")
      : state === "processing"
        ? t("overlay.processing")
        : t("overlay.transcribing");

  return (
    <div
      dir={direction}
      className={`ov-stage ${position} ov-fade ${isVisible ? "show" : ""}`}
    >
      <div
        className={`scard compact ${working && isVisible ? "cworking" : ""}`}
      >
        {working
          ? workingRow(workLabel, true)
          : listeningRow(
              false,
              true,
              translationLabel
                ? t("overlay.translate.to", { label: translationLabel })
                : undefined,
            )}
      </div>
    </div>
  );
};

export default RecordingOverlay;
