import React, { useState } from "react";
import { useTranslation } from "react-i18next";
import { Sparkles, Languages } from "lucide-react";
import { PostProcessingSettings } from "../post-processing/PostProcessingSettings";
import { TranslationSettings } from "../translation/TranslationSettings";

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
    <div className="w-full flex flex-col items-center gap-4">
      <div
        role="tablist"
        className="flex gap-1 rounded-lg border border-separator bg-fill p-1 w-full max-w-md"
      >
        {tabs.map(({ id, labelKey, icon: Icon }) => (
          <button
            key={id}
            type="button"
            role="tab"
            aria-selected={tab === id}
            onClick={() => setTab(id)}
            className={`flex-1 flex items-center justify-center gap-2 rounded-md px-3 py-1.5 text-sm font-medium transition-colors cursor-pointer ${
              tab === id
                ? "bg-background text-text shadow-sm"
                : "text-secondary-label hover:text-text"
            }`}
          >
            <Icon width={16} height={16} />
            {t(labelKey)}
          </button>
        ))}
      </div>

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
