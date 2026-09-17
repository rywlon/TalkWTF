import React, { useState } from "react";
import { useTranslation } from "react-i18next";
import { Sparkles, Languages } from "lucide-react";
import { PostProcessingSettings } from "../post-processing/PostProcessingSettings";
import { TranslationSettings } from "../translation/TranslationSettings";
import { SegmentedControl } from "../../ui/SegmentedControl";

type PersonalizationTab = "polish" | "translation";

/**
 * Personalization: how the app rewrites your words — AI polish (provider,
 * style, scenes) and translation (target languages, shortcut).
 */
export const PersonalizationSettings: React.FC = () => {
  const { t } = useTranslation();
  const [tab, setTab] = useState<PersonalizationTab>("polish");

  const tabs: {
    id: PersonalizationTab;
    labelKey: string;
    icon: React.ComponentType<any>;
  }[] = [
    {
      id: "polish",
      labelKey: "settings.personalization.polish",
      icon: Sparkles,
    },
    {
      id: "translation",
      labelKey: "settings.personalization.translation",
      icon: Languages,
    },
  ];

  return (
    <div className="w-full flex flex-col items-start gap-5">
      <SegmentedControl
        ariaLabel={t("settings.panes.personalization")}
        value={tab}
        onChange={setTab}
        options={tabs.map(({ id, labelKey, icon }) => ({
          value: id,
          label: t(labelKey),
          icon,
        }))}
      />

      <div className="w-full">
        {tab === "polish" ? (
          <PostProcessingSettings />
        ) : (
          <TranslationSettings />
        )}
      </div>
    </div>
  );
};
