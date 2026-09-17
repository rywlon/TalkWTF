import React from "react";

interface SettingsGroupProps {
  title?: string;
  description?: string;
  children: React.ReactNode;
}

export const SettingsGroup: React.FC<SettingsGroupProps> = ({
  title,
  description,
  children,
}) => {
  return (
    <div className="space-y-2">
      {title && (
        <div className="px-1">
          <h2 className="text-callout font-semibold text-secondary-label">
            {title}
          </h2>
          {description && (
            <p className="text-caption text-tertiary-label mt-0.5">
              {description}
            </p>
          )}
        </div>
      )}
      <div className="glass-rim bg-background border border-separator rounded-card overflow-visible">
        <div className="divide-y divide-separator">{children}</div>
      </div>
    </div>
  );
};
