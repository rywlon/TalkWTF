import React, { useState } from "react";
import { useTranslation } from "react-i18next";
import { BookOpen, History } from "lucide-react";
import { HistorySettings } from "../settings/history/HistorySettings";
import { DictionarySettings } from "../settings/dictionary/DictionarySettings";
import { SegmentedControl } from "../ui/SegmentedControl";

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
    <div className="w-full flex flex-col items-start gap-5">
      <SegmentedControl
        ariaLabel={t("sidebar.library")}
        value={tab}
        onChange={setTab}
        options={TABS.map(({ id, labelKey, icon }) => ({
          value: id,
          label: t(labelKey),
          icon,
        }))}
      />

      <div className="w-full">
        {tab === "history" ? <HistorySettings /> : <DictionarySettings />}
      </div>
    </div>
  );
};
