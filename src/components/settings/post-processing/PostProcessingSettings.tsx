import React, { useState } from "react";
import { useTranslation } from "react-i18next";
import { RefreshCcw } from "lucide-react";

import { Alert } from "../../ui/Alert";
import { SettingContainer, SettingsGroup } from "@/components/ui";
import { ResetButton } from "../../ui/ResetButton";
import { ToggleSwitch } from "../../ui/ToggleSwitch";
import { useSettings } from "../../../hooks/useSettings";

import { ProviderSelect } from "./ProviderSelect";
import { BaseUrlField } from "./BaseUrlField";
import { ApiKeyField } from "./ApiKeyField";
import { ModelSelect } from "./ModelSelect";
import { usePostProcessProviderState } from "./usePostProcessProviderState";
import { StyleAndScenesPane } from "./StyleAndScenesPane";
import { ShortcutInput } from "../ShortcutInput";

const ProviderPane: React.FC = () => {
  const { t } = useTranslation();
  const { getSetting, updateSetting, isUpdating } = useSettings();
  const state = usePostProcessProviderState();

  const thinkingEnabled = getSetting("post_process_thinking") || false;

  const missingConfigLabels = state.missingConfig.map((field) => {
    switch (field) {
      case "baseUrl":
        return t("settings.postProcessing.api.baseUrl.title");
      case "apiKey":
        return t("settings.postProcessing.api.apiKey.title");
      default:
        return t("settings.postProcessing.api.model.title");
    }
  });

  return (
    <>
      <SettingContainer
        title={t("settings.postProcessing.api.provider.title")}
        description={t("settings.postProcessing.api.provider.description")}
        descriptionMode="tooltip"
        layout="horizontal"
        grouped={true}
      >
        <div className="flex items-center gap-2">
          <ProviderSelect
            options={state.providerOptions}
            value={state.selectedProviderId}
            onChange={state.handleProviderSelect}
          />
        </div>
      </SettingContainer>

      {state.isAppleProvider && state.appleIntelligenceUnavailable && (
        <Alert variant="error" contained>
          {t("settings.postProcessing.api.appleIntelligence.unavailable")}
        </Alert>
      )}

      {!state.isAppleProvider && missingConfigLabels.length > 0 && (
        <Alert variant="warning" contained>
          {t("settings.postProcessing.status.incomplete", {
            fields: missingConfigLabels.join(" / "),
          })}
        </Alert>
      )}

      {!state.isAppleProvider && (
        <>
          {state.allowBaseUrlEdit && (
            <SettingContainer
              title={t("settings.postProcessing.api.baseUrl.title")}
              description={t("settings.postProcessing.api.baseUrl.description")}
              descriptionMode="inline"
              layout="horizontal"
              grouped={true}
            >
              <div className="flex items-center gap-2">
                <BaseUrlField
                  value={state.baseUrl}
                  onBlur={state.handleBaseUrlChange}
                  placeholder={t(
                    "settings.postProcessing.api.baseUrl.placeholder",
                  )}
                  disabled={state.isBaseUrlUpdating}
                  className="min-w-[380px]"
                />
              </div>
            </SettingContainer>
          )}

          {state.requiresApiKey && (
            <SettingContainer
              title={t("settings.postProcessing.api.apiKey.title")}
              description={t("settings.postProcessing.api.apiKey.description")}
              descriptionMode="tooltip"
              layout="horizontal"
              grouped={true}
            >
              <div className="flex items-center gap-2">
                <ApiKeyField
                  value={state.apiKey}
                  onBlur={state.handleApiKeyChange}
                  placeholder={t(
                    "settings.postProcessing.api.apiKey.placeholder",
                  )}
                  disabled={state.isApiKeyUpdating}
                  className="min-w-[320px]"
                />
              </div>
            </SettingContainer>
          )}

          <SettingContainer
            title={t("settings.postProcessing.api.model.title")}
            description={
              state.allowBaseUrlEdit
                ? t("settings.postProcessing.api.model.descriptionCustom")
                : t("settings.postProcessing.api.model.descriptionDefault")
            }
            descriptionMode="tooltip"
            layout="stacked"
            grouped={true}
          >
            <div className="flex items-center gap-2">
              <ModelSelect
                value={state.model}
                options={state.modelOptions}
                disabled={state.isModelUpdating}
                isLoading={state.isFetchingModels}
                placeholder={
                  state.modelOptions.length > 0
                    ? t(
                        "settings.postProcessing.api.model.placeholderWithOptions",
                      )
                    : t(
                        "settings.postProcessing.api.model.placeholderNoOptions",
                      )
                }
                onSelect={state.handleModelSelect}
                onCreate={state.handleModelCreate}
                onBlur={() => {}}
                className="flex-1 min-w-[380px]"
              />
              <ResetButton
                onClick={state.handleRefreshModels}
                disabled={state.isFetchingModels}
                ariaLabel={t("settings.postProcessing.api.model.refreshModels")}
                className="flex h-10 w-10 items-center justify-center"
              >
                <RefreshCcw
                  className={`h-4 w-4 ${state.isFetchingModels ? "animate-spin" : ""}`}
                />
              </ResetButton>
            </div>
          </SettingContainer>

          {/* Apple Intelligence runs on-device and has no reasoning switch, so
              the row would be a dead control there — the whole block above is
              already hidden for it. */}
          <ToggleSwitch
            checked={thinkingEnabled}
            onChange={(enabled) =>
              updateSetting("post_process_thinking", enabled)
            }
            isUpdating={isUpdating("post_process_thinking")}
            label={t("settings.postProcessing.thinking.title")}
            description={t("settings.postProcessing.thinking.description")}
            descriptionMode="tooltip"
            grouped={true}
          />
        </>
      )}
    </>
  );
};

type TabId = "shortcut" | "polish" | "provider";

export const PostProcessingSettings: React.FC = () => {
  const { t } = useTranslation();
  const [tab, setTab] = useState<TabId>("shortcut");

  const tabs: { id: TabId; label: string }[] = [
    { id: "shortcut", label: t("settings.postProcessing.hotkey.title") },
    { id: "polish", label: t("settings.postProcessing.prompts.title") },
    { id: "provider", label: t("settings.postProcessing.api.title") },
  ];

  return (
    <div className="max-w-3xl w-full mx-auto space-y-6">
      <div
        role="tablist"
        className="flex gap-1 rounded-lg border border-mid-gray/20 bg-mid-gray/5 p-1"
      >
        {tabs.map(({ id, label }) => (
          <button
            key={id}
            type="button"
            role="tab"
            aria-selected={tab === id}
            onClick={() => setTab(id)}
            className={`flex-1 rounded-md px-3 py-1.5 text-sm font-medium transition-colors ${
              tab === id
                ? "bg-background text-text shadow-sm"
                : "text-mid-gray hover:text-text"
            }`}
          >
            {label}
          </button>
        ))}
      </div>

      {tab === "shortcut" && (
        <SettingsGroup title={t("settings.postProcessing.hotkey.title")}>
          <ShortcutInput
            shortcutId="transcribe"
            descriptionMode="tooltip"
            grouped={true}
          />
          <ShortcutInput
            shortcutId="transcribe_with_post_process"
            descriptionMode="tooltip"
            grouped={true}
          />
        </SettingsGroup>
      )}

      {tab === "polish" && <StyleAndScenesPane />}

      {tab === "provider" && (
        <SettingsGroup title={t("settings.postProcessing.api.title")}>
          <ProviderPane />
        </SettingsGroup>
      )}
    </div>
  );
};
