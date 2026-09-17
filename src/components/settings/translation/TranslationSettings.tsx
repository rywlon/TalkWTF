import React, { useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { X } from "lucide-react";
import { toast } from "sonner";

import { commands } from "@/bindings";
import type { TranslationLanguage } from "@/bindings";
import { SettingContainer, SettingsGroup } from "@/components/ui";
import { Select } from "@/components/ui/Select";
import { ShortcutInput } from "../ShortcutInput";
import { useSettings } from "../../../hooks/useSettings";

/**
 * Settings for the translate workflow: its shortcut, the (up to three) target
 * languages, and which one is active. The backend owns the language table and
 * all validation; this page just renders it.
 */
export const TranslationSettings: React.FC = () => {
  const { t } = useTranslation();
  const { getSetting, refreshSettings } = useSettings();
  const [languages, setLanguages] = useState<TranslationLanguage[]>([]);
  const [busy, setBusy] = useState(false);

  const targets = getSetting("translation_targets") ?? [];
  const activeTarget = getSetting("translation_active_target") ?? null;

  useEffect(() => {
    void commands.getTranslationLanguages().then(setLanguages);
  }, []);

  const labelFor = (code: string) =>
    languages.find((language) => language.value === code)?.label ?? code;

  const run = async (
    action: () => Promise<{ status: string; error?: string }>,
  ) => {
    setBusy(true);
    try {
      const result = await action();
      if (result.status === "error") {
        toast.error(result.error);
        return;
      }
      await refreshSettings();
    } catch (error) {
      toast.error(String(error));
    } finally {
      setBusy(false);
    }
  };

  const addable = languages.filter(
    (language) => !targets.includes(language.value),
  );
  const canAddMore = targets.length < 3;

  return (
    <div className="max-w-3xl w-full mx-auto space-y-6">
      <SettingsGroup
        title={t("settings.translation.title")}
        description={t("settings.translation.description")}
      >
        <ShortcutInput
          shortcutId="translate"
          descriptionMode="tooltip"
          grouped={true}
        />
      </SettingsGroup>

      <SettingsGroup
        title={t("settings.translation.targets.title")}
        description={t("settings.translation.targets.description")}
      >
        <SettingContainer
          title={t("settings.translation.targets.listTitle")}
          description={t("settings.translation.targets.listDescription")}
          descriptionMode="inline"
          layout="stacked"
          grouped={true}
        >
          <div className="flex flex-col gap-3">
            {targets.length === 0 ? (
              <p className="text-sm text-mid-gray">
                {t("settings.translation.targets.empty")}
              </p>
            ) : (
              <div className="flex flex-wrap gap-2">
                {targets.map((code) => (
                  <span
                    key={code}
                    className="inline-flex items-center gap-1.5 rounded-full border border-mid-gray/40 bg-mid-gray/10 py-1 ps-3 pe-1.5 text-sm"
                  >
                    {labelFor(code)}
                    <button
                      type="button"
                      aria-label={t("settings.translation.targets.remove", {
                        language: labelFor(code),
                      })}
                      disabled={busy}
                      className="flex h-5 w-5 items-center justify-center rounded-full text-mid-gray transition-colors hover:bg-mid-gray/20 hover:text-text disabled:opacity-50"
                      onClick={() =>
                        void run(() => commands.removeTranslationTarget(code))
                      }
                    >
                      <X className="h-3 w-3" />
                    </button>
                  </span>
                ))}
              </div>
            )}

            {canAddMore && addable.length > 0 && (
              <div className="max-w-[320px]">
                <Select
                  value={null}
                  options={addable.map((language) => ({
                    value: language.value,
                    label: language.label,
                  }))}
                  placeholder={t("settings.translation.targets.addPlaceholder")}
                  disabled={busy}
                  onChange={(value) => {
                    if (value) {
                      void run(() => commands.addTranslationTarget(value));
                    }
                  }}
                />
              </div>
            )}
          </div>
        </SettingContainer>

        {targets.length > 0 && (
          <SettingContainer
            title={t("settings.translation.targets.activeTitle")}
            description={t("settings.translation.targets.activeDescription")}
            descriptionMode="inline"
            layout="stacked"
            grouped={true}
          >
            <div
              role="radiogroup"
              className="flex flex-wrap gap-1 rounded-lg border border-mid-gray/20 bg-mid-gray/5 p-1"
            >
              {targets.map((code) => {
                const isActive = activeTarget === code;
                return (
                  <button
                    key={code}
                    type="button"
                    role="radio"
                    aria-checked={isActive}
                    disabled={busy}
                    onClick={() =>
                      void run(() => commands.setActiveTranslationTarget(code))
                    }
                    className={`flex-1 rounded-md px-3 py-1.5 text-sm font-medium transition-colors disabled:opacity-50 ${
                      isActive
                        ? "bg-background text-text shadow-sm"
                        : "text-mid-gray hover:text-text"
                    }`}
                  >
                    {labelFor(code)}
                  </button>
                );
              })}
            </div>
          </SettingContainer>
        )}
      </SettingsGroup>
    </div>
  );
};
