import React from "react";
import { useTranslation } from "react-i18next";
import { LayoutDashboard, Library, Settings2 } from "lucide-react";
import TalkWtfLogo from "./icons/TalkWtfLogo";

/** The three top-level destinations. Settings has its own secondary nav. */
export type SidebarSection = "dashboard" | "library" | "settings";

interface IconProps {
  width?: number | string;
  height?: number | string;
  size?: number | string;
  className?: string;
  [key: string]: unknown;
}

interface SectionConfig {
  labelKey: string;
  icon: React.ComponentType<IconProps>;
}

export const SECTIONS_CONFIG = {
  dashboard: { labelKey: "sidebar.dashboard", icon: LayoutDashboard },
  library: { labelKey: "sidebar.library", icon: Library },
  settings: { labelKey: "sidebar.settings", icon: Settings2 },
} as const satisfies Record<SidebarSection, SectionConfig>;

export const SIDEBAR_SECTIONS: SidebarSection[] = [
  "dashboard",
  "library",
  "settings",
];

interface SidebarProps {
  activeSection: SidebarSection;
  onSectionChange: (section: SidebarSection) => void;
}

export const Sidebar: React.FC<SidebarProps> = ({
  activeSection,
  onSectionChange,
}) => {
  const { t } = useTranslation();

  return (
    <div className="flex flex-col w-56 h-full border-e border-separator items-center px-3">
      {/* mt clears the traffic lights: the title bar is an overlay, so the
          content runs to the top edge of the window. */}
      <TalkWtfLogo width={140} className="mt-10 mb-3 text-text" />
      <div className="flex flex-col w-full items-center gap-1 pt-3 border-t border-separator">
        {SIDEBAR_SECTIONS.map((id) => {
          const { labelKey, icon: Icon } = SECTIONS_CONFIG[id];
          const isActive = activeSection === id;

          return (
            <div
              key={id}
              role="button"
              tabIndex={0}
              className={`flex gap-3 items-center h-[34px] px-3 w-full rounded-control cursor-pointer transition-colors ${
                isActive
                  ? "bg-logo-primary/15 text-text"
                  : "hover:bg-fill text-secondary-label"
              }`}
              onClick={() => onSectionChange(id)}
              onKeyDown={(event) => {
                if (event.key === "Enter" || event.key === " ") {
                  event.preventDefault();
                  onSectionChange(id);
                }
              }}
            >
              <Icon
                width={18}
                height={18}
                className={`shrink-0 ${isActive ? "text-logo-primary" : ""}`}
              />
              <p className="text-body font-medium truncate" title={t(labelKey)}>
                {t(labelKey)}
              </p>
            </div>
          );
        })}
      </div>
    </div>
  );
};
