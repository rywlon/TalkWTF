import React, { useCallback, useEffect, useMemo, useState } from "react";
import { useTranslation } from "react-i18next";
import {
  Check,
  Download,
  Pencil,
  Search,
  Trash2,
  Upload,
  X,
} from "lucide-react";
import { open, save } from "@tauri-apps/plugin-dialog";
import { toast } from "sonner";
import {
  commands,
  events,
  type CorrectionRule,
  type DictionaryImportReport,
  type DictionaryLimits,
  type DictionaryWord,
} from "@/bindings";

import { Alert } from "../../ui/Alert";
import { Button } from "../../ui/Button";
import { Dialog } from "../../ui/Dialog";
import { ToggleSwitch } from "../../ui/ToggleSwitch";
import { useSettings } from "../../../hooks/useSettings";
import { SettingContainer, SettingsGroup } from "@/components/ui";
import { Input } from "../../ui/Input";
import { WordCorrectionThreshold } from "./WordCorrectionThreshold";

type Segment = "words" | "rules";

const matches = (needle: string, ...haystack: string[]) =>
  needle === "" ||
  haystack.some((value) => value.toLowerCase().includes(needle));

const IconButton: React.FC<{
  label: string;
  onClick: () => void;
  children: React.ReactNode;
  className?: string;
}> = ({ label, onClick, children, className = "" }) => (
  <button
    type="button"
    aria-label={label}
    onClick={onClick}
    className={`rounded p-1 text-mid-gray transition-colors hover:text-text ${className}`}
  >
    {children}
  </button>
);

const WordsSection: React.FC<{
  words: DictionaryWord[];
  limits: DictionaryLimits | null;
  query: string;
  onChanged: () => Promise<void>;
}> = ({ words, limits, query, onChanged }) => {
  const { t } = useTranslation();
  const [draft, setDraft] = useState("");
  const [editingId, setEditingId] = useState<number | null>(null);
  const [editingValue, setEditingValue] = useState("");
  const [confirmingId, setConfirmingId] = useState<number | null>(null);
  const [isBusy, setIsBusy] = useState(false);

  const visible = useMemo(
    () => words.filter((entry) => matches(query, entry.word)),
    [words, query],
  );

  const maxChars = limits?.word_max_chars ?? 100;

  const handleAdd = async () => {
    const word = draft.trim();
    if (word === "") return;

    setIsBusy(true);
    const result = await commands.addDictionaryWord(word);
    setIsBusy(false);

    if (result.status === "error") {
      toast.error(result.error);
      return;
    }
    setDraft("");
    await onChanged();
  };

  const handleSaveEdit = async () => {
    if (editingId === null) return;

    setIsBusy(true);
    const result = await commands.updateDictionaryWord(
      editingId,
      editingValue.trim(),
    );
    setIsBusy(false);

    if (result.status === "error") {
      toast.error(result.error);
      return;
    }
    setEditingId(null);
    await onChanged();
  };

  const handleDelete = async (id: number) => {
    setIsBusy(true);
    const result = await commands.deleteDictionaryWord(id);
    setIsBusy(false);

    if (result.status === "error") {
      // The row can be gone already (removed from the overlay), so resync before
      // reporting: a stale row would fail on every further click.
      setConfirmingId(null);
      await onChanged();
      toast.error(result.error);
      return;
    }
    setConfirmingId(null);
    await onChanged();
  };

  return (
    <SettingsGroup title={t("settings.dictionary.wordsTitle")}>
      <SettingContainer
        title={t("settings.dictionary.wordsTitle")}
        description={t("settings.dictionary.wordsDescription")}
        descriptionMode="tooltip"
        layout="stacked"
        grouped={true}
      >
        <div className="space-y-3">
          <div className="flex gap-2">
            <Input
              type="text"
              value={draft}
              onChange={(event) => setDraft(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === "Enter") void handleAdd();
              }}
              placeholder={t("settings.advanced.customWords.placeholder")}
              variant="compact"
              maxLength={maxChars}
              className="flex-1"
            />
            <Button
              onClick={() => void handleAdd()}
              variant="secondary"
              size="md"
              disabled={draft.trim() === "" || isBusy}
              className="shrink-0"
            >
              {t("settings.advanced.customWords.add")}
            </Button>
          </div>

          {visible.length === 0 && (
            <p className="text-sm text-mid-gray">
              {t("settings.dictionary.wordsEmpty")}
            </p>
          )}

          <div className="space-y-1">
            {visible.map((entry) =>
              editingId === entry.id ? (
                <div key={entry.id} className="flex items-center gap-2">
                  <Input
                    type="text"
                    value={editingValue}
                    onChange={(event) => setEditingValue(event.target.value)}
                    onKeyDown={(event) => {
                      if (event.key === "Enter") void handleSaveEdit();
                      if (event.key === "Escape") setEditingId(null);
                    }}
                    variant="compact"
                    maxLength={maxChars}
                    className="flex-1"
                  />
                  <IconButton
                    label="Save word"
                    onClick={() => void handleSaveEdit()}
                  >
                    <Check className="h-4 w-4" />
                  </IconButton>
                  <IconButton
                    label="Cancel edit"
                    onClick={() => setEditingId(null)}
                  >
                    <X className="h-4 w-4" />
                  </IconButton>
                </div>
              ) : (
                <div
                  key={entry.id}
                  className="flex items-center justify-between gap-2 rounded border border-mid-gray/20 px-2 py-1"
                >
                  <span className="truncate text-sm">{entry.word}</span>
                  <span className="flex shrink-0 items-center gap-1">
                    <IconButton
                      label="Edit word"
                      onClick={() => {
                        setConfirmingId(null);
                        setEditingId(entry.id);
                        setEditingValue(entry.word);
                      }}
                    >
                      <Pencil className="h-4 w-4" />
                    </IconButton>
                    <IconButton
                      label="Delete word"
                      onClick={() => {
                        if (confirmingId === entry.id) {
                          void handleDelete(entry.id);
                        } else {
                          setConfirmingId(entry.id);
                        }
                      }}
                      className={
                        confirmingId === entry.id
                          ? "text-red-400 hover:text-red-300"
                          : ""
                      }
                    >
                      <Trash2 className="h-4 w-4" />
                    </IconButton>
                  </span>
                </div>
              ),
            )}
          </div>

          <WordCorrectionThreshold descriptionMode="tooltip" grouped={false} />
        </div>
      </SettingContainer>
    </SettingsGroup>
  );
};

const RulesSection: React.FC<{
  rules: CorrectionRule[];
  limits: DictionaryLimits | null;
  query: string;
  onChanged: () => Promise<void>;
}> = ({ rules, limits, query, onChanged }) => {
  const { t } = useTranslation();
  const [pattern, setPattern] = useState("");
  const [replacement, setReplacement] = useState("");
  const [editingId, setEditingId] = useState<number | null>(null);
  const [editingPattern, setEditingPattern] = useState("");
  const [editingReplacement, setEditingReplacement] = useState("");
  const [confirmingId, setConfirmingId] = useState<number | null>(null);
  const [isBusy, setIsBusy] = useState(false);

  const visible = useMemo(
    () =>
      rules.filter((rule) => matches(query, rule.pattern, rule.replacement)),
    [rules, query],
  );

  const patternMax = limits?.rule_pattern_max_chars ?? 120;
  const replacementMax = limits?.rule_replacement_max_chars ?? 120;

  const handleAdd = async () => {
    if (pattern.trim() === "" || replacement.trim() === "") return;

    setIsBusy(true);
    const result = await commands.addCorrectionRule(
      pattern.trim(),
      replacement.trim(),
    );
    setIsBusy(false);

    if (result.status === "error") {
      toast.error(result.error);
      return;
    }
    setPattern("");
    setReplacement("");
    await onChanged();
  };

  const handleSaveEdit = async () => {
    if (editingId === null) return;

    setIsBusy(true);
    const result = await commands.updateCorrectionRule(
      editingId,
      editingPattern.trim(),
      editingReplacement.trim(),
    );
    setIsBusy(false);

    if (result.status === "error") {
      toast.error(result.error);
      return;
    }
    setEditingId(null);
    await onChanged();
  };

  const handleToggle = async (rule: CorrectionRule, enabled: boolean) => {
    const result = await commands.setCorrectionRuleEnabled(rule.id, enabled);
    if (result.status === "error") {
      toast.error(result.error);
      return;
    }
    await onChanged();
  };

  const handleDelete = async (id: number) => {
    const result = await commands.deleteCorrectionRule(id);
    if (result.status === "error") {
      setConfirmingId(null);
      await onChanged();
      toast.error(result.error);
      return;
    }
    setConfirmingId(null);
    await onChanged();
  };

  return (
    <SettingsGroup title={t("settings.dictionary.rulesTitle")}>
      <SettingContainer
        title={t("settings.dictionary.rulesTitle")}
        description={t("settings.dictionary.rulesDescription")}
        descriptionMode="tooltip"
        layout="stacked"
        grouped={true}
      >
        <div className="space-y-3">
          <div className="flex flex-wrap gap-2">
            <Input
              type="text"
              value={pattern}
              onChange={(event) => setPattern(event.target.value)}
              placeholder={t("settings.dictionary.patternPlaceholder")}
              variant="compact"
              maxLength={patternMax}
              className="min-w-[180px] flex-1"
            />
            <Input
              type="text"
              value={replacement}
              onChange={(event) => setReplacement(event.target.value)}
              placeholder={t("settings.dictionary.replacementPlaceholder")}
              variant="compact"
              maxLength={replacementMax}
              className="min-w-[180px] flex-1"
            />
            <Button
              onClick={() => void handleAdd()}
              variant="secondary"
              size="md"
              disabled={
                pattern.trim() === "" || replacement.trim() === "" || isBusy
              }
              className="shrink-0"
            >
              {t("settings.advanced.customWords.add")}
            </Button>
          </div>

          {visible.length === 0 && (
            <p className="text-sm text-mid-gray">
              {t("settings.dictionary.rulesEmpty")}
            </p>
          )}

          <div className="space-y-1">
            {visible.map((rule) =>
              editingId === rule.id ? (
                <div key={rule.id} className="flex items-center gap-2">
                  <Input
                    type="text"
                    value={editingPattern}
                    onChange={(event) => setEditingPattern(event.target.value)}
                    onKeyDown={(event) => {
                      if (event.key === "Enter") void handleSaveEdit();
                      if (event.key === "Escape") setEditingId(null);
                    }}
                    variant="compact"
                    maxLength={patternMax}
                    className="flex-1"
                  />
                  <Input
                    type="text"
                    value={editingReplacement}
                    onChange={(event) =>
                      setEditingReplacement(event.target.value)
                    }
                    onKeyDown={(event) => {
                      if (event.key === "Enter") void handleSaveEdit();
                      if (event.key === "Escape") setEditingId(null);
                    }}
                    variant="compact"
                    maxLength={replacementMax}
                    className="flex-1"
                  />
                  <IconButton
                    label="Save rule"
                    onClick={() => void handleSaveEdit()}
                  >
                    <Check className="h-4 w-4" />
                  </IconButton>
                  <IconButton
                    label="Cancel edit"
                    onClick={() => setEditingId(null)}
                  >
                    <X className="h-4 w-4" />
                  </IconButton>
                </div>
              ) : (
                <div
                  key={rule.id}
                  className="flex items-center justify-between gap-2 rounded border border-mid-gray/20 px-2 py-1"
                >
                  <label className="flex min-w-0 flex-1 cursor-pointer items-center gap-2">
                    <input
                      type="checkbox"
                      checked={rule.enabled}
                      onChange={(event) =>
                        void handleToggle(rule, event.target.checked)
                      }
                      aria-label={t("settings.dictionary.enabled")}
                      className="h-4 w-4 shrink-0 cursor-pointer accent-current"
                    />
                    <span
                      className={`truncate text-sm ${rule.enabled ? "" : "text-mid-gray line-through"}`}
                    >
                      {rule.pattern} → {rule.replacement}
                    </span>
                  </label>
                  <span className="flex shrink-0 items-center gap-1">
                    <IconButton
                      label="Edit rule"
                      onClick={() => {
                        setConfirmingId(null);
                        setEditingId(rule.id);
                        setEditingPattern(rule.pattern);
                        setEditingReplacement(rule.replacement);
                      }}
                    >
                      <Pencil className="h-4 w-4" />
                    </IconButton>
                    <IconButton
                      label="Delete rule"
                      onClick={() => {
                        if (confirmingId === rule.id) {
                          void handleDelete(rule.id);
                        } else {
                          setConfirmingId(rule.id);
                        }
                      }}
                      className={
                        confirmingId === rule.id
                          ? "text-red-400 hover:text-red-300"
                          : ""
                      }
                    >
                      <Trash2 className="h-4 w-4" />
                    </IconButton>
                  </span>
                </div>
              ),
            )}
          </div>
        </div>
      </SettingContainer>
    </SettingsGroup>
  );
};

export const DictionarySettings: React.FC = () => {
  const { t } = useTranslation();
  const { getSetting, updateSetting, isUpdating } = useSettings();
  const [segment, setSegment] = useState<Segment>("words");
  const [query, setQuery] = useState("");
  const [words, setWords] = useState<DictionaryWord[]>([]);
  const [rules, setRules] = useState<CorrectionRule[]>([]);
  const [limits, setLimits] = useState<DictionaryLimits | null>(null);
  const [isBusy, setIsBusy] = useState(false);
  // Accessibility report, shown inline so "learn from edits" can be diagnosed
  // without reading a log file.
  const [diagnostic, setDiagnostic] = useState<string[] | null>(null);
  // Mishearings the user undid. Invisible for too long: without this the app
  // silently stopped learning a word and there was no way to find out why.
  const [rejected, setRejected] = useState<string[]>([]);
  const [rejectedOpen, setRejectedOpen] = useState(false);

  const reload = useCallback(async () => {
    const result = await commands.getDictionary();
    if (result.status === "error") {
      toast.error(result.error);
      return;
    }
    setWords(result.data.words);
    setRules(result.data.rules);
  }, []);

  const reloadRejected = useCallback(async () => {
    const result = await commands.listLearningRejections();
    if (result.status === "error") {
      toast.error(result.error);
      return;
    }
    setRejected(result.data);
  }, []);

  const restoreRejected = async (pattern: string) => {
    const result = await commands.forgetLearningRejection(pattern);
    if (result.status === "error") {
      toast.error(result.error);
      return;
    }
    await reloadRejected();
  };

  const clearRejected = async () => {
    const result = await commands.clearLearningRejections();
    if (result.status === "error") {
      toast.error(result.error);
      return;
    }
    await reloadRejected();
  };

  useEffect(() => {
    void reload();
    void reloadRejected();
    void commands.getDictionaryLimits().then(setLimits);
  }, [reload]);

  // "Learn from my corrections" and the overlay's undo both write behind this
  // page's back, so refresh the lists when they do. Without the second one the
  // page keeps showing the row that undo just removed.
  useEffect(() => {
    const pending = events.learnedCorrection.listen(() => {
      void reload();
      void reloadRejected();
    });
    const undone = events.dictionaryChanged.listen(() => {
      void reload();
      void reloadRejected();
    });
    return () => {
      void pending.then((unlisten) => unlisten());
      void undone.then((unlisten) => unlisten());
    };
  }, [reload, reloadRejected]);

  const reportImport = (report: DictionaryImportReport) => {
    toast.success(
      t("settings.dictionary.importReport", {
        accepted: report.accepted,
        duplicates: report.skipped_duplicates,
        invalid: report.skipped_invalid,
      }),
    );
  };

  const handleExport = async () => {
    const path = await save({
      defaultPath: "talkwtf-dictionary.json",
      filters: [{ name: "JSON", extensions: ["json"] }],
    });
    if (!path) return;

    setIsBusy(true);
    const result = await commands.exportDictionary(path);
    setIsBusy(false);

    if (result.status === "error") {
      toast.error(result.error);
      return;
    }
    toast.success(t("settings.dictionary.exportDone"));
  };

  const handleImport = async () => {
    const path = await open({
      multiple: false,
      filters: [{ name: "JSON", extensions: ["json"] }],
    });
    if (!path || Array.isArray(path)) return;

    setIsBusy(true);
    const result = await commands.importDictionary(path);
    setIsBusy(false);

    if (result.status === "error") {
      toast.error(result.error);
      return;
    }
    reportImport(result.data);
    await reload();
  };

  return (
    <div className="max-w-3xl w-full mx-auto space-y-6">
      <div className="flex flex-wrap items-center gap-2">
        <div className="relative min-w-[200px] flex-1">
          <Search className="pointer-events-none absolute left-2 top-1/2 h-4 w-4 -translate-y-1/2 text-mid-gray" />
          <Input
            type="text"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder={t("settings.dictionary.search")}
            variant="compact"
            className="pl-8"
          />
        </div>
        <Button
          onClick={() => void handleImport()}
          variant="secondary"
          size="md"
          disabled={isBusy}
        >
          <span className="flex items-center gap-1">
            <Upload className="h-4 w-4" />
            {t("settings.dictionary.import")}
          </span>
        </Button>
        <Button
          onClick={() => void handleExport()}
          variant="secondary"
          size="md"
          disabled={isBusy}
        >
          <span className="flex items-center gap-1">
            <Download className="h-4 w-4" />
            {t("settings.dictionary.export")}
          </span>
        </Button>
      </div>

      <div
        role="tablist"
        className="flex gap-1 rounded-lg border border-mid-gray/20 bg-mid-gray/5 p-1"
      >
        {(
          [
            { id: "words", label: t("settings.dictionary.wordsTitle") },
            { id: "rules", label: t("settings.dictionary.rulesTitle") },
          ] as { id: Segment; label: string }[]
        ).map(({ id, label }) => (
          <button
            key={id}
            type="button"
            role="tab"
            aria-selected={segment === id}
            onClick={() => setSegment(id)}
            className={`flex-1 rounded-md px-3 py-1.5 text-sm font-medium transition-colors ${
              segment === id
                ? "bg-background text-text shadow-sm"
                : "text-mid-gray hover:text-text"
            }`}
          >
            {label}
          </button>
        ))}
      </div>

      <Alert variant="info" contained>
        {t("settings.dictionary.hint")}
      </Alert>

      <SettingsGroup title={t("settings.dictionary.learn.title")}>
        <ToggleSwitch
          checked={getSetting("learn_from_edits") ?? false}
          onChange={(enabled) => updateSetting("learn_from_edits", enabled)}
          isUpdating={isUpdating("learn_from_edits")}
          label={t("settings.dictionary.learn.title")}
          description={t("settings.dictionary.learn.description")}
          descriptionMode="tooltip"
          grouped={true}
        />
        <SettingContainer
          title={t("settings.dictionary.learn.rejectedTitle")}
          description={t("settings.dictionary.learn.rejectedDescription")}
          descriptionMode="tooltip"
          layout="stacked"
          grouped={true}
        >
          <Button
            onClick={() => setRejectedOpen(true)}
            variant="secondary"
            size="md"
          >
            {t("settings.dictionary.learn.rejectedButton", {
              count: rejected.length,
            })}
          </Button>
        </SettingContainer>
        <SettingContainer
          title={t("settings.dictionary.diagnose.title")}
          description={t("settings.dictionary.diagnose.description")}
          descriptionMode="tooltip"
          layout="stacked"
          grouped={true}
        >
          <div className="space-y-2">
            <Button
              onClick={() => {
                void commands.diagnoseEditLearning().then(setDiagnostic);
              }}
              variant="secondary"
              size="md"
            >
              {t("settings.dictionary.diagnose.action")}
            </Button>
            {diagnostic && (
              <pre className="max-h-64 overflow-auto whitespace-pre-wrap break-words rounded border border-mid-gray/20 bg-mid-gray/5 p-2 font-mono text-xs text-mid-gray">
                {diagnostic.join("\n")}
              </pre>
            )}
          </div>
        </SettingContainer>
      </SettingsGroup>

      <Dialog
        open={rejectedOpen}
        onOpenChange={setRejectedOpen}
        title={t("settings.dictionary.learn.rejectedTitle")}
        description={t("settings.dictionary.learn.rejectedDescription")}
        closeLabel={t("common.close")}
        footer={
          rejected.length > 0 ? (
            <Button onClick={() => void clearRejected()} variant="danger-ghost">
              {t("settings.dictionary.learn.rejectedClear")}
            </Button>
          ) : undefined
        }
      >
        {rejected.length === 0 ? (
          <p className="text-sm text-mid-gray">
            {t("settings.dictionary.learn.rejectedEmpty")}
          </p>
        ) : (
          <ul className="max-h-72 space-y-1 overflow-auto">
            {rejected.map((pattern) => (
              <li
                key={pattern}
                className="flex items-center justify-between gap-3 rounded-md border border-mid-gray/20 px-3 py-1.5"
              >
                <span className="truncate text-sm">{pattern}</span>
                <Button
                  onClick={() => void restoreRejected(pattern)}
                  variant="ghost"
                  size="sm"
                >
                  {t("settings.dictionary.learn.rejectedRestore")}
                </Button>
              </li>
            ))}
          </ul>
        )}
      </Dialog>

      {segment === "words" ? (
        <WordsSection
          words={words}
          limits={limits}
          query={query}
          onChanged={reload}
        />
      ) : (
        <RulesSection
          rules={rules}
          limits={limits}
          query={query}
          onChanged={reload}
        />
      )}
    </div>
  );
};
