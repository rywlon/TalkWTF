import React, {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { convertFileSrc } from "@tauri-apps/api/core";
import { readFile } from "@tauri-apps/plugin-fs";
import {
  Check,
  Copy,
  FolderOpen,
  Languages,
  Mic,
  RotateCcw,
  Star,
  Trash2,
} from "lucide-react";
import { useTranslation } from "react-i18next";
import { toast } from "sonner";
import {
  commands,
  events,
  type HistoryEntry,
  type HistoryUpdatePayload,
} from "@/bindings";
import { useOsType } from "@/hooks/useOsType";
import { AudioPlayer, AudioPlayerGroup } from "../../ui/AudioPlayer";
import { Button } from "../../ui/Button";
import { Dropdown } from "../../ui/Dropdown";
import { SearchField } from "../../ui/SearchField";

/** "3 秒" / "2 分 5 秒" — short duration for the row metadata. */
function formatDurationShort(ms: number): string {
  const seconds = Math.max(0, Math.round(ms / 1000));
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  const rest = seconds % 60;
  return rest === 0 ? `${minutes}m` : `${minutes}m ${rest}s`;
}

/** "1 小时前" via Intl.RelativeTimeFormat. */
function formatRelativeTime(
  timestampSeconds: number,
  language: string,
): string {
  const diffMs = Date.now() - timestampSeconds * 1000;
  const diffSeconds = Math.round(diffMs / 1000);
  const formatter = new Intl.RelativeTimeFormat(language, {
    numeric: "auto",
  });
  const units: [Intl.RelativeTimeFormatUnit, number][] = [
    ["second", 60],
    ["minute", 60],
    ["hour", 24],
    ["day", 7],
    ["week", 4.348],
    ["month", 12],
    ["year", Number.POSITIVE_INFINITY],
  ];
  let value = -diffSeconds;
  for (const [unit, step] of units) {
    if (Math.abs(value) < step || unit === "year") {
      return formatter.format(Math.round(value), unit);
    }
    value = value / step;
  }
  return formatter.format(Math.round(value), "year");
}

const IconButton: React.FC<{
  onClick: () => void;
  title: string;
  disabled?: boolean;
  active?: boolean;
  children: React.ReactNode;
}> = ({ onClick, title, disabled, active, children }) => (
  <button
    onClick={onClick}
    disabled={disabled}
    className={`p-1.5 rounded-md flex items-center justify-center transition-colors cursor-pointer disabled:cursor-not-allowed disabled:text-text/20 ${
      active
        ? "text-logo-primary hover:text-logo-primary/80"
        : "text-text/50 hover:text-logo-primary"
    }`}
    title={title}
  >
    {children}
  </button>
);

const PAGE_SIZE = 30;

interface OpenRecordingsButtonProps {
  onClick: () => void;
  label: string;
}

const OpenRecordingsButton: React.FC<OpenRecordingsButtonProps> = ({
  onClick,
  label,
}) => (
  <Button
    onClick={onClick}
    variant="secondary"
    size="sm"
    className="flex items-center gap-2"
    title={label}
  >
    <FolderOpen className="w-4 h-4" />
    <span>{label}</span>
  </Button>
);

export const HistorySettings: React.FC = () => {
  const { t } = useTranslation();
  const osType = useOsType();
  const [entries, setEntries] = useState<HistoryEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [hasMore, setHasMore] = useState(true);
  const [query, setQuery] = useState("");
  const [sortOrder, setSortOrder] = useState<"newest" | "oldest">("newest");
  const sentinelRef = useRef<HTMLDivElement>(null);
  const entriesRef = useRef<HistoryEntry[]>([]);
  const loadingRef = useRef(false);

  // Keep ref in sync for use in IntersectionObserver callback
  useEffect(() => {
    entriesRef.current = entries;
  }, [entries]);

  const loadPage = useCallback(async (cursor?: number) => {
    const isFirstPage = cursor === undefined;
    if (!isFirstPage && loadingRef.current) return;
    loadingRef.current = true;

    if (isFirstPage) setLoading(true);

    try {
      const result = await commands.getHistoryEntries(
        cursor ?? null,
        PAGE_SIZE,
      );
      if (result.status === "ok") {
        const { entries: newEntries, has_more } = result.data;
        setEntries((prev) =>
          isFirstPage ? newEntries : [...prev, ...newEntries],
        );
        setHasMore(has_more);
      }
    } catch (error) {
      console.error("Failed to load history entries:", error);
    } finally {
      setLoading(false);
      loadingRef.current = false;
    }
  }, []);

  // Initial load
  useEffect(() => {
    loadPage();
  }, [loadPage]);

  // Infinite scroll via IntersectionObserver
  useEffect(() => {
    if (loading) return;

    const sentinel = sentinelRef.current;
    if (!sentinel || !hasMore) return;

    const observer = new IntersectionObserver(
      (observerEntries) => {
        const first = observerEntries[0];
        if (first.isIntersecting) {
          const lastEntry = entriesRef.current[entriesRef.current.length - 1];
          if (lastEntry) {
            loadPage(lastEntry.id);
          }
        }
      },
      { threshold: 0 },
    );

    observer.observe(sentinel);
    return () => observer.disconnect();
  }, [loading, hasMore, loadPage]);

  // Listen for new entries added from the transcription pipeline
  useEffect(() => {
    const unlisten = events.historyUpdatePayload.listen((event) => {
      const payload: HistoryUpdatePayload = event.payload;
      if (payload.action === "added") {
        setEntries((prev) => [payload.entry, ...prev]);
      } else if (payload.action === "updated") {
        setEntries((prev) =>
          prev.map((e) => (e.id === payload.entry.id ? payload.entry : e)),
        );
      }
      // "deleted" and "toggled" are handled by optimistic updates only,
      // so we intentionally ignore them here to avoid double-mutation.
    });

    return () => {
      unlisten.then((fn) => fn());
    };
  }, []);

  const toggleSaved = async (id: number) => {
    // Optimistic update
    setEntries((prev) =>
      prev.map((e) => (e.id === id ? { ...e, saved: !e.saved } : e)),
    );
    try {
      const result = await commands.toggleHistoryEntrySaved(id);
      if (result.status !== "ok") {
        // Revert on failure
        setEntries((prev) =>
          prev.map((e) => (e.id === id ? { ...e, saved: !e.saved } : e)),
        );
      }
    } catch (error) {
      console.error("Failed to toggle saved status:", error);
      // Revert on failure
      setEntries((prev) =>
        prev.map((e) => (e.id === id ? { ...e, saved: !e.saved } : e)),
      );
    }
  };

  const copyToClipboard = async (text: string) => {
    try {
      await navigator.clipboard.writeText(text);
    } catch (error) {
      console.error("Failed to copy to clipboard:", error);
    }
  };

  const getAudioUrl = useCallback(
    async (fileName: string) => {
      try {
        const result = await commands.getAudioFilePath(fileName);
        if (result.status === "ok") {
          if (osType === "linux") {
            const fileData = await readFile(result.data);
            const blob = new Blob([fileData], { type: "audio/wav" });
            return URL.createObjectURL(blob);
          }
          return convertFileSrc(result.data, "asset");
        }
        return null;
      } catch (error) {
        console.error("Failed to get audio file path:", error);
        return null;
      }
    },
    [osType],
  );

  const deleteAudioEntry = async (id: number) => {
    // Optimistically remove
    setEntries((prev) => prev.filter((e) => e.id !== id));
    try {
      const result = await commands.deleteHistoryEntry(id);
      if (result.status !== "ok") {
        // Reload on failure
        loadPage();
      }
    } catch (error) {
      console.error("Failed to delete entry:", error);
      loadPage();
    }
  };

  const retryHistoryEntry = async (id: number) => {
    const result = await commands.retryHistoryEntryTranscription(id);
    if (result.status !== "ok") {
      throw new Error(String(result.error));
    }
  };

  const openRecordingsFolder = async () => {
    try {
      const result = await commands.openRecordingsFolder();
      if (result.status !== "ok") {
        throw new Error(String(result.error));
      }
    } catch (error) {
      console.error("Failed to open recordings folder:", error);
    }
  };

  const visibleEntries = useMemo(() => {
    const needle = query.trim().toLowerCase();
    const filtered = needle
      ? entries.filter((entry) =>
          `${entry.transcription_text} ${entry.post_processed_text ?? ""}`
            .toLowerCase()
            .includes(needle),
        )
      : entries;
    return [...filtered].sort((a, b) =>
      sortOrder === "newest"
        ? b.timestamp - a.timestamp
        : a.timestamp - b.timestamp,
    );
  }, [entries, query, sortOrder]);

  const sortOptions = [
    { value: "newest", label: t("settings.history.sort.newest") },
    { value: "oldest", label: t("settings.history.sort.oldest") },
  ];

  let content: React.ReactNode;

  if (loading) {
    content = (
      <div className="px-5 py-10 text-center text-callout text-secondary-label">
        {t("settings.history.loading")}
      </div>
    );
  } else if (entries.length === 0) {
    content = (
      <div className="px-5 py-10 text-center text-callout text-secondary-label">
        {t("settings.history.empty")}
      </div>
    );
  } else if (visibleEntries.length === 0) {
    content = (
      <div className="px-5 py-10 text-center text-callout text-secondary-label">
        {t("settings.history.noMatches")}
      </div>
    );
  } else {
    content = (
      <>
        <AudioPlayerGroup>
          <div className="divide-y divide-separator">
            {visibleEntries.map((entry) => (
              <HistoryEntryComponent
                key={entry.id}
                entry={entry}
                onToggleSaved={() => toggleSaved(entry.id)}
                onCopyText={() => copyToClipboard(entry.transcription_text)}
                getAudioUrl={getAudioUrl}
                deleteAudio={deleteAudioEntry}
                retryTranscription={retryHistoryEntry}
              />
            ))}
          </div>
        </AudioPlayerGroup>
        {/* Sentinel for infinite scroll */}
        <div ref={sentinelRef} className="h-1" />
      </>
    );
  }

  return (
    <div className="max-w-[880px] w-full mx-auto space-y-5">
      <div className="flex items-center gap-3">
        <SearchField
          className="flex-1 max-w-sm"
          value={query}
          onChange={setQuery}
          placeholder={t("settings.history.searchPlaceholder")}
        />
        <Dropdown
          options={sortOptions}
          selectedValue={sortOrder}
          onSelect={(value) => setSortOrder(value as "newest" | "oldest")}
        />
        <div className="ms-auto">
          <OpenRecordingsButton
            onClick={openRecordingsFolder}
            label={t("settings.history.openFolder")}
          />
        </div>
      </div>
      <div className="glass-rim bg-background border border-separator rounded-card overflow-visible">
        {content}
      </div>
    </div>
  );
};

interface HistoryEntryProps {
  entry: HistoryEntry;
  onToggleSaved: () => void;
  onCopyText: () => void;
  getAudioUrl: (fileName: string) => Promise<string | null>;
  deleteAudio: (id: number) => Promise<void>;
  retryTranscription: (id: number) => Promise<void>;
}

const HistoryEntryComponent: React.FC<HistoryEntryProps> = ({
  entry,
  onToggleSaved,
  onCopyText,
  getAudioUrl,
  deleteAudio,
  retryTranscription,
}) => {
  const { t, i18n } = useTranslation();
  const [showCopied, setShowCopied] = useState(false);
  const [retrying, setRetrying] = useState(false);

  const hasTranscription = entry.transcription_text.trim().length > 0;

  const handleLoadAudio = useCallback(
    () => getAudioUrl(entry.file_name),
    [getAudioUrl, entry.file_name],
  );

  const handleCopyText = () => {
    if (!hasTranscription) {
      return;
    }

    onCopyText();
    setShowCopied(true);
    setTimeout(() => setShowCopied(false), 2000);
  };

  const handleDeleteEntry = async () => {
    try {
      await deleteAudio(entry.id);
    } catch (error) {
      console.error("Failed to delete entry:", error);
      toast.error(t("settings.history.deleteError"));
    }
  };

  const handleRetranscribe = async () => {
    try {
      setRetrying(true);
      await retryTranscription(entry.id);
    } catch (error) {
      console.error("Failed to re-transcribe:", error);
      toast.error(t("settings.history.retranscribeError"));
    } finally {
      setRetrying(false);
    }
  };

  const polished = entry.post_processed_text?.trim() ?? "";
  const raw = entry.transcription_text.trim();
  const primary = polished || raw;
  const secondary = polished && raw && polished !== raw ? raw : "";

  const metaParts = [
    entry.workflow === "translate"
      ? t("dashboard.workflow.translate")
      : t("dashboard.workflow.dictation"),
    formatRelativeTime(entry.timestamp, i18n.language),
  ];
  const durationMs = entry.duration_ms ?? 0;
  if (durationMs > 0) {
    metaParts.push(formatDurationShort(durationMs));
  }

  return (
    <div className="px-5 py-3.5 flex flex-col gap-2.5">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0 flex-1">
          <p
            className={
              retrying
                ? ""
                : hasTranscription
                  ? "text-body text-text select-text cursor-text whitespace-pre-wrap break-words"
                  : "text-body text-tertiary-label"
            }
            style={
              retrying
                ? { animation: "transcribe-pulse 3s ease-in-out infinite" }
                : undefined
            }
          >
            {retrying && (
              <style>{`
                @keyframes transcribe-pulse {
                  0%, 100% { color: color-mix(in srgb, var(--color-text) 40%, transparent); }
                  50% { color: color-mix(in srgb, var(--color-text) 90%, transparent); }
                }
              `}</style>
            )}
            {retrying
              ? t("settings.history.transcribing")
              : hasTranscription
                ? primary
                : t("settings.history.transcriptionFailed")}
          </p>

          {secondary && (
            <p className="mt-1 line-clamp-2 text-callout text-secondary-label select-text cursor-text">
              {secondary}
            </p>
          )}

          <p className="mt-1.5 flex items-center gap-1.5 text-caption text-tertiary-label">
            {entry.workflow === "translate" ? (
              <Languages className="h-3 w-3" />
            ) : (
              <Mic className="h-3 w-3" />
            )}
            {metaParts.join(" · ")}
          </p>
        </div>

        <div className="flex shrink-0 items-center -me-1">
          <IconButton
            onClick={handleCopyText}
            disabled={!hasTranscription || retrying}
            title={t("settings.history.copyToClipboard")}
          >
            {showCopied ? (
              <Check width={16} height={16} />
            ) : (
              <Copy width={16} height={16} />
            )}
          </IconButton>
          <IconButton
            onClick={onToggleSaved}
            disabled={retrying}
            active={entry.saved}
            title={
              entry.saved
                ? t("settings.history.unsave")
                : t("settings.history.save")
            }
          >
            <Star
              width={16}
              height={16}
              fill={entry.saved ? "currentColor" : "none"}
            />
          </IconButton>
          <IconButton
            onClick={handleRetranscribe}
            disabled={retrying}
            title={t("settings.history.retranscribe")}
          >
            <RotateCcw
              width={16}
              height={16}
              style={
                retrying
                  ? { animation: "spin 1s linear infinite reverse" }
                  : undefined
              }
            />
          </IconButton>
          <IconButton
            onClick={handleDeleteEntry}
            disabled={retrying}
            title={t("settings.history.delete")}
          >
            <Trash2 width={16} height={16} />
          </IconButton>
        </div>
      </div>

      <AudioPlayer onLoadRequest={handleLoadAudio} className="w-full" />
    </div>
  );
};
