import React from "react";
import { useTranslation } from "react-i18next";
import { type } from "@tauri-apps/plugin-os";
import { ShortcutInput } from "../ShortcutInput";
import { SettingsGroup } from "../../ui/SettingsGroup";
import { ShortcutActivationSetting } from "../ShortcutActivation";
import { StartHidden } from "../StartHidden";
import { AutostartToggle } from "../AutostartToggle";
import { ShowTrayIcon } from "../ShowTrayIcon";
import { ShowOverlay } from "../ShowOverlay";
import { AppLanguageSelector } from "../AppLanguageSelector";
import { ThemeSelector } from "../ThemeSelector";

export const GeneralSettings: React.FC = () => {
  const { t } = useTranslation();
  const isLinux = type() === "linux";

  return (
    <div className="max-w-[880px] w-full mx-auto space-y-6">
      <SettingsGroup title={t("settings.general.title")}>
        <AppLanguageSelector descriptionMode="tooltip" grouped={true} />
        <ThemeSelector descriptionMode="tooltip" grouped={true} />
      </SettingsGroup>

      <SettingsGroup title={t("settings.general.shortcutsGroup")}>
        <ShortcutInput shortcutId="transcribe" grouped={true} />
        <ShortcutActivationSetting descriptionMode="tooltip" grouped={true} />
        {/* Cancel shortcut remains hidden on Linux because of dynamic shortcut instability. */}
        {!isLinux && <ShortcutInput shortcutId="cancel" grouped={true} />}
      </SettingsGroup>

      <SettingsGroup title={t("settings.general.behaviorGroup")}>
        <StartHidden descriptionMode="tooltip" grouped={true} />
        <AutostartToggle descriptionMode="tooltip" grouped={true} />
        <ShowTrayIcon descriptionMode="tooltip" grouped={true} />
        <ShowOverlay descriptionMode="tooltip" grouped={true} />
      </SettingsGroup>
    </div>
  );
};
