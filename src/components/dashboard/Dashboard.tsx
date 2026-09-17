import React, { useCallback, useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import {
  Check,
  Circle,
  Clock,
  Gauge,
  Languages,
  Mic,
  RefreshCw,
  Timer,
  Type,
} from "lucide-react";

import { commands } from "@/bindings";
import type { DashboardStats } from "@/bindings";

/** Milliseconds → "1h 23m" / "5m 12s" / "12s". */
function formatDuration(ms: number): string {
  const totalSeconds = Math.max(0, Math.round(ms / 1000));
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  if (hours > 0) return `${hours}h ${minutes}m`;
  if (minutes > 0) return `${minutes}m ${seconds}s`;
  return `${seconds}s`;
}

function formatNumber(value: number): string {
  return Math.round(value).toLocaleString();
}

const StatCard: React.FC<{
  icon: React.ComponentType<{ className?: string }>;
  label: string;
  value: string;
  hint?: string;
}> = ({ icon: Icon, label, value, hint }) => (
  <div className="rounded-xl border border-separator bg-background p-4">
    <div className="flex items-center gap-1.5 text-xs font-medium text-secondary-label">
      <Icon className="h-3.5 w-3.5" />
      {label}
    </div>
    <div className="mt-1.5 text-2xl font-semibold tracking-tight text-text">
      {value}
    </div>
    {hint && <div className="mt-0.5 text-xs text-tertiary-label">{hint}</div>}
  </div>
);

const StatusRow: React.FC<{
  label: string;
  value: string;
  ok?: boolean | null;
}> = ({ label, value, ok = null }) => (
  <div className="flex items-center justify-between gap-3 px-4 py-2.5">
    <span className="text-sm text-secondary-label">{label}</span>
    <span className="flex items-center gap-1.5 text-sm font-medium text-text">
      {ok !== null &&
        (ok ? (
          <Check className="h-3.5 w-3.5 text-logo-primary" />
        ) : (
          <Circle className="h-3 w-3 text-tertiary-label" />
        ))}
      {value}
    </span>
  </div>
);

export const Dashboard: React.FC = () => {
  const { t } = useTranslation();
  const [stats, setStats] = useState<DashboardStats | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const result = await commands.getDashboardStats();
      if (result.status === "ok") {
        setStats(result.data);
        setError(null);
      } else {
        setError(result.error);
      }
    } catch (e) {
      setError(String(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const workflowLabel = (workflow: string) =>
    workflow === "translate"
      ? t("dashboard.workflow.translate")
      : t("dashboard.workflow.dictation");

  const maxWeekly = stats
    ? Math.max(1, ...stats.weekly.map((day) => day.count))
    : 1;

  return (
    <div className="max-w-4xl w-full mx-auto space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-semibold tracking-tight text-text">
          {t("dashboard.title")}
        </h1>
        <button
          type="button"
          onClick={() => void load()}
          disabled={loading}
          aria-label={t("dashboard.refresh")}
          title={t("dashboard.refresh")}
          className="flex h-8 w-8 items-center justify-center rounded-lg border border-separator text-secondary-label transition-colors hover:bg-fill hover:text-text disabled:opacity-50"
        >
          <RefreshCw className={`h-4 w-4 ${loading ? "animate-spin" : ""}`} />
        </button>
      </div>

      {error && (
        <div className="rounded-lg border border-error/40 bg-error/10 px-3 py-2 text-sm text-error">
          {t("dashboard.error")}
        </div>
      )}

      {!stats ? (
        <div className="py-16 text-center text-sm text-tertiary-label">
          {loading ? t("dashboard.loading") : t("dashboard.error")}
        </div>
      ) : (
        <>
          {/* Today */}
          <section className="space-y-2">
            <h2 className="px-1 text-xs font-medium uppercase tracking-wide text-secondary-label">
              {t("dashboard.today.title")}
            </h2>
            <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
              <StatCard
                icon={Mic}
                label={t("dashboard.today.recordings")}
                value={formatNumber(stats.today.recordings)}
              />
              <StatCard
                icon={Type}
                label={t("dashboard.today.chars")}
                value={formatNumber(stats.today.chars)}
              />
              <StatCard
                icon={Languages}
                label={t("dashboard.today.translations")}
                value={formatNumber(stats.today.translations)}
              />
              <StatCard
                icon={Clock}
                label={t("dashboard.today.dictationTime")}
                value={formatDuration(stats.today.dictation_ms)}
              />
            </div>
          </section>

          {/* All time */}
          <section className="space-y-2">
            <h2 className="px-1 text-xs font-medium uppercase tracking-wide text-secondary-label">
              {t("dashboard.metrics.title")}
            </h2>
            <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
              <StatCard
                icon={Mic}
                label={t("dashboard.metrics.totalRecordings")}
                value={formatNumber(stats.total_recordings)}
              />
              <StatCard
                icon={Clock}
                label={t("dashboard.metrics.dictationTime")}
                value={formatDuration(stats.total_dictation_ms)}
              />
              <StatCard
                icon={Type}
                label={t("dashboard.metrics.chars")}
                value={formatNumber(stats.total_chars)}
              />
              <StatCard
                icon={Gauge}
                label={t("dashboard.metrics.speed")}
                value={t("dashboard.metrics.charsPerMin", {
                  value: Math.round(stats.avg_chars_per_min),
                })}
              />
              <StatCard
                icon={Timer}
                label={t("dashboard.metrics.timeSaved")}
                value={formatDuration(stats.time_saved_ms)}
              />
              <StatCard
                icon={Languages}
                label={t("dashboard.metrics.translations")}
                value={formatNumber(stats.translation_count)}
              />
            </div>
          </section>

          {/* Weekly + tokens */}
          <div className="grid gap-4 lg:grid-cols-2">
            <section className="rounded-xl border border-separator bg-background p-4">
              <h2 className="text-xs font-medium uppercase tracking-wide text-secondary-label">
                {t("dashboard.weekly.title")}
              </h2>
              <div className="mt-4 flex items-end justify-between gap-1.5">
                {stats.weekly.map((day) => (
                  <div
                    key={day.day}
                    className="flex flex-1 flex-col items-center gap-1.5"
                    title={t("dashboard.weekly.recordings", {
                      count: day.count,
                    })}
                  >
                    <div className="flex h-16 w-full items-end justify-center">
                      <div
                        className="w-5 rounded-t bg-logo-primary/80"
                        style={{
                          height: `${Math.max(2, (day.count / maxWeekly) * 64)}px`,
                        }}
                      />
                    </div>
                    <span className="text-[10px] text-tertiary-label">
                      {day.day}
                    </span>
                  </div>
                ))}
              </div>
            </section>

            <section className="rounded-xl border border-separator bg-background p-4">
              <h2 className="text-xs font-medium uppercase tracking-wide text-secondary-label">
                {t("dashboard.tokens.title")}
              </h2>
              <div className="mt-3 grid grid-cols-2 gap-3">
                {(
                  [
                    ["dashboard.tokens.today", stats.tokens_today],
                    ["dashboard.tokens.week", stats.tokens_week],
                  ] as const
                ).map(([labelKey, usage]) => (
                  <div key={labelKey} className="rounded-lg bg-fill p-3">
                    <div className="text-xs font-medium text-secondary-label">
                      {t(labelKey)}
                    </div>
                    {usage.requests === 0 ? (
                      <div className="mt-1 text-sm text-tertiary-label">
                        {t("dashboard.tokens.none")}
                      </div>
                    ) : (
                      <dl className="mt-1.5 space-y-0.5 text-xs">
                        <div className="flex justify-between">
                          <dt className="text-tertiary-label">
                            {t("dashboard.tokens.prompt")}
                          </dt>
                          <dd className="font-medium text-text">
                            {formatNumber(usage.prompt_tokens)}
                          </dd>
                        </div>
                        <div className="flex justify-between">
                          <dt className="text-tertiary-label">
                            {t("dashboard.tokens.completion")}
                          </dt>
                          <dd className="font-medium text-text">
                            {formatNumber(usage.completion_tokens)}
                          </dd>
                        </div>
                        <div className="flex justify-between">
                          <dt className="text-tertiary-label">
                            {t("dashboard.tokens.total")}
                          </dt>
                          <dd className="font-semibold text-text">
                            {formatNumber(usage.total_tokens)}
                          </dd>
                        </div>
                        <div className="flex justify-between">
                          <dt className="text-tertiary-label">
                            {t("dashboard.tokens.requests")}
                          </dt>
                          <dd className="font-medium text-text">
                            {formatNumber(usage.requests)}
                          </dd>
                        </div>
                      </dl>
                    )}
                  </div>
                ))}
              </div>
            </section>
          </div>

          {/* Services + personalization */}
          <div className="grid gap-4 lg:grid-cols-2">
            <section className="space-y-2">
              <h2 className="px-1 text-xs font-medium uppercase tracking-wide text-secondary-label">
                {t("dashboard.services.title")}
              </h2>
              <div className="divide-y divide-separator rounded-xl border border-separator bg-background">
                <StatusRow
                  label={t("dashboard.services.asr")}
                  value={
                    stats.services.asr_model || t("dashboard.services.none")
                  }
                  ok={stats.services.asr_ready}
                />
                <StatusRow
                  label={t("dashboard.services.llm")}
                  value={
                    stats.services.llm_provider
                      ? `${stats.services.llm_provider}${
                          stats.services.llm_model
                            ? ` · ${stats.services.llm_model}`
                            : ""
                        }`
                      : t("dashboard.services.none")
                  }
                  ok={stats.services.polish_ready}
                />
                <StatusRow
                  label={t("dashboard.services.polish")}
                  value={
                    stats.services.polish_ready
                      ? t("dashboard.services.configured")
                      : t("dashboard.services.notConfigured")
                  }
                  ok={stats.services.polish_ready}
                />
                <StatusRow
                  label={t("dashboard.services.input")}
                  value={
                    stats.services.asr_ready
                      ? t("dashboard.services.ready")
                      : t("dashboard.services.notReady")
                  }
                  ok={stats.services.asr_ready}
                />
                <StatusRow
                  label={t("dashboard.services.paste")}
                  value={
                    stats.services.paste_enabled
                      ? t("dashboard.services.enabled")
                      : t("dashboard.services.disabled")
                  }
                  ok={stats.services.paste_enabled}
                />
              </div>
            </section>

            <section className="space-y-2">
              <h2 className="px-1 text-xs font-medium uppercase tracking-wide text-secondary-label">
                {t("dashboard.personalization.title")}
              </h2>
              <div className="rounded-xl border border-separator bg-background p-4">
                <div className="flex items-center justify-between">
                  <span className="text-sm text-secondary-label">
                    {t("dashboard.personalization.label")}
                  </span>
                  <span className="text-2xl font-semibold text-text">
                    {stats.personalization.score}%
                  </span>
                </div>
                <div className="mt-2 h-2 w-full overflow-hidden rounded-full bg-fill">
                  <div
                    className="h-full rounded-full bg-logo-primary transition-[width]"
                    style={{ width: `${stats.personalization.score}%` }}
                  />
                </div>
                <ul className="mt-3 space-y-1.5">
                  {stats.personalization.items.map((item) => (
                    <li
                      key={item.id}
                      className="flex items-center gap-2 text-sm"
                    >
                      {item.done ? (
                        <Check className="h-3.5 w-3.5 shrink-0 text-logo-primary" />
                      ) : (
                        <Circle className="h-3 w-3 shrink-0 text-tertiary-label" />
                      )}
                      <span
                        className={
                          item.done ? "text-text" : "text-tertiary-label"
                        }
                      >
                        {t(`dashboard.personalization.items.${item.id}`)}
                      </span>
                    </li>
                  ))}
                </ul>
              </div>
            </section>
          </div>

          {/* Recent activity */}
          <section className="space-y-2">
            <h2 className="px-1 text-xs font-medium uppercase tracking-wide text-secondary-label">
              {t("dashboard.recent.title")}
            </h2>
            {stats.recent.length === 0 ? (
              <div className="rounded-xl border border-separator bg-background px-4 py-6 text-center text-sm text-tertiary-label">
                {t("dashboard.recent.empty")}
              </div>
            ) : (
              <ul className="divide-y divide-separator rounded-xl border border-separator bg-background">
                {stats.recent.map((activity) => (
                  <li
                    key={activity.id}
                    className="flex items-center gap-3 px-4 py-2.5"
                  >
                    {activity.workflow === "translate" ? (
                      <Languages className="h-4 w-4 shrink-0 text-logo-primary" />
                    ) : (
                      <Mic className="h-4 w-4 shrink-0 text-secondary-label" />
                    )}
                    <div className="min-w-0 flex-1">
                      <p className="truncate text-sm text-text">
                        {activity.preview}
                      </p>
                      <p className="text-xs text-tertiary-label">
                        {new Date(activity.timestamp * 1000).toLocaleString()} ·{" "}
                        {workflowLabel(activity.workflow)} ·{" "}
                        {t("dashboard.recent.chars", {
                          count: activity.char_count,
                        })}
                      </p>
                    </div>
                  </li>
                ))}
              </ul>
            )}
          </section>
        </>
      )}
    </div>
  );
};
