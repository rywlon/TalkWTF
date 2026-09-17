import React, { useState } from "react";
import { useTranslation } from "react-i18next";
import { BookOpen, History } from "lucide-react";
import { HistorySettings } from "../settings/history/HistorySettings";
import { DictionarySettings } from "../settings/dictionary/DictionarySettings";

type LibraryTab = "history" | "dictionary";

const TABS: {
  id: LibraryTab;
  labelKey: string;
  icon: React.ComponentType<any>;
}[] = [
  { id: "history", labelKey: "sidebar.history", icon: History },
  { id: "dictionary", labelKey: "sidebar.dictionary", icon: BookOpen },
];

/**
 * Library: the user's data — transcription history and the dictionary — in one
 * place, switched with a segmented control.
 */
export const Library: React.FC = () => {
  const { t } = useTranslation();
  const [tab, setTab] = useState<LibraryTab>("history");

  return (
    <div className="w-full flex flex-col items-center gap-4">
      <div
        role="tablist"
        className="flex gap-1 rounded-lg border border-separator bg-fill p-1 w-full max-w-md"
      >
        {TABS.map(({ id, labelKey, icon: Icon }) => (
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
        {tab === "history" ? <HistorySettings /> : <DictionarySettings />}
      </div>
    </div>
  );
};
