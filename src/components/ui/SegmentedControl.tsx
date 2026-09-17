import React from "react";

export interface SegmentedOption<T extends string> {
  value: T;
  label: string;
  icon?: React.ComponentType<{
    className?: string;
    width?: number;
    height?: number;
  }>;
}

interface SegmentedControlProps<T extends string> {
  options: SegmentedOption<T>[];
  value: T;
  onChange: (value: T) => void;
  className?: string;
  ariaLabel?: string;
}

/**
 * macOS-style segmented control: a light rounded track with the selected
 * segment as a raised white pill. Used for the Library and Personalization tabs.
 */
export function SegmentedControl<T extends string>({
  options,
  value,
  onChange,
  className = "",
  ariaLabel,
}: SegmentedControlProps<T>) {
  return (
    <div
      role="tablist"
      aria-label={ariaLabel}
      className={`inline-flex items-center gap-0.5 rounded-control border border-separator bg-fill p-0.5 ${className}`}
    >
      {options.map(({ value: optionValue, label, icon: Icon }) => {
        const active = optionValue === value;
        return (
          <button
            key={optionValue}
            type="button"
            role="tab"
            aria-selected={active}
            onClick={() => onChange(optionValue)}
            className={`inline-flex items-center justify-center gap-1.5 h-7 px-3 rounded-[6px] text-callout transition-colors cursor-pointer ${
              active
                ? "bg-background text-text font-medium shadow-sm"
                : "text-secondary-label hover:text-text"
            }`}
          >
            {Icon && <Icon className="h-3.5 w-3.5" />}
            {label}
          </button>
        );
      })}
    </div>
  );
}
