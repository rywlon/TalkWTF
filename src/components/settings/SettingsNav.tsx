import React from "react";
import { useTranslation } from "react-i18next";
import { useSettings } from "../../hooks/useSettings";

/** Secondary destinations shown while the Settings section is active. */
export type SettingsPane =
  | "general"
  | "personalization"
  | "models"
  | "audio"
  | "advanced"
  | "about"
  | "debug";

interface PaneConfig {
  id: SettingsPane;
  labelKey: string;
  debugOnly?: boolean;
}

export const SETTINGS_PANES: PaneConfig[] = [
  { id: "general", labelKey: "settings.panes.general" },
  { id: "personalization", labelKey: "settings.panes.personalization" },
  { id: "models", labelKey: "settings.panes.models" },
  { id: "audio", labelKey: "settings.panes.audio" },
  { id: "advanced", labelKey: "settings.panes.advanced" },
  { id: "about", labelKey: "settings.panes.about" },
  { id: "debug", labelKey: "settings.panes.debug", debugOnly: true },
];

interface SettingsNavProps {
  pane: SettingsPane;
  onPaneChange: (pane: SettingsPane) => void;
}

export const SettingsNav: React.FC<SettingsNavProps> = ({
  pane,
  onPaneChange,
}) => {
  const { t } = useTranslation();
  const { getSetting } = useSettings();
  const debugEnabled = getSetting("debug_mode") || false;

  const panes = SETTINGS_PANES.filter(
    (config) => !config.debugOnly || debugEnabled,
  );

  return (
    <nav className="w-48 h-full shrink-0 border-e border-separator p-3 space-y-1 overflow-y-auto">
      {panes.map((config) => {
        const isActive = pane === config.id;
        return (
          <button
            key={config.id}
            type="button"
            onClick={() => onPaneChange(config.id)}
            className={`w-full text-start rounded-control px-3 h-8 text-body transition-colors cursor-pointer ${
              isActive
                ? "bg-logo-primary/15 text-text font-medium"
                : "text-secondary-label hover:bg-fill hover:text-text"
            }`}
          >
            {t(config.labelKey)}
          </button>
        );
      })}
    </nav>
  );
};
