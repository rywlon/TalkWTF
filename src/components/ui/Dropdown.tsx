import React, { useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";

export interface DropdownOption {
  value: string;
  label: string;
  description?: string;
  disabled?: boolean;
}

interface DropdownProps {
  options: DropdownOption[];
  className?: string;
  menuClassName?: string;
  selectedValue: string | null;
  onSelect: (value: string) => void;
  placeholder?: string;
  disabled?: boolean;
  onRefresh?: () => void;
}

export const Dropdown: React.FC<DropdownProps> = ({
  options,
  selectedValue,
  onSelect,
  className = "",
  menuClassName,
  placeholder = "Select an option...",
  disabled = false,
  onRefresh,
}) => {
  const { t } = useTranslation();
  const [isOpen, setIsOpen] = useState(false);
  const dropdownRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const handleClickOutside = (event: MouseEvent) => {
      if (
        dropdownRef.current &&
        !dropdownRef.current.contains(event.target as Node)
      ) {
        setIsOpen(false);
      }
    };
    document.addEventListener("mousedown", handleClickOutside);
    return () => document.removeEventListener("mousedown", handleClickOutside);
  }, []);

  const selectedOption = options.find(
    (option) => option.value === selectedValue,
  );

  const handleSelect = (value: string) => {
    onSelect(value);
    setIsOpen(false);
  };

  const handleToggle = () => {
    if (disabled) return;
    if (!isOpen && onRefresh) onRefresh();
    setIsOpen(!isOpen);
  };

  return (
    <div className={`relative ${className}`} ref={dropdownRef}>
      {/* Native pop-up button: 28pt tall, hairline border, subtle fill and the
          double chevron. No heavy border or oversized min-width. */}
      <button
        type="button"
        className={`h-7 min-w-[150px] px-2.5 grid grid-cols-[1fr_auto] gap-2 items-center rounded-control border border-separator bg-fill text-body text-text text-start transition-colors ${
          disabled
            ? "opacity-50 cursor-not-allowed"
            : "hover:bg-mid-gray/20 cursor-pointer"
        }`}
        onClick={handleToggle}
        disabled={disabled}
      >
        <span className="truncate">{selectedOption?.label || placeholder}</span>
        <svg
          className="w-3.5 h-3.5 shrink-0 text-secondary-label"
          fill="none"
          stroke="currentColor"
          strokeWidth={2.2}
          viewBox="0 0 24 24"
          aria-hidden="true"
        >
          <path
            strokeLinecap="round"
            strokeLinejoin="round"
            d="M8 9l4-4 4 4M8 15l4 4 4-4"
          />
        </svg>
      </button>
      {isOpen && !disabled && (
        <div
          className={`absolute top-full mt-1 bg-popover border border-separator rounded-[10px] shadow-[0_8px_28px_rgba(0,0,0,0.18)] z-50 max-h-72 overflow-y-auto py-1 ${
            menuClassName ?? "left-0 right-0"
          }`}
        >
          {options.length === 0 ? (
            <div className="px-2.5 py-1.5 text-callout text-secondary-label">
              {t("common.noOptionsFound")}
            </div>
          ) : (
            options.map((option) => (
              <button
                key={option.value}
                type="button"
                className={`w-full text-start px-2.5 py-1.5 transition-colors duration-100 ${
                  option.description ? "" : ""
                } ${
                  selectedValue === option.value
                    ? "bg-logo-primary/15"
                    : "hover:bg-fill"
                } ${option.disabled ? "opacity-50 cursor-not-allowed" : ""}`}
                onClick={() => handleSelect(option.value)}
                disabled={option.disabled}
              >
                <span className="flex items-center gap-2 text-body text-text">
                  {selectedValue === option.value && (
                    <svg
                      className="w-3.5 h-3.5 shrink-0 text-logo-primary"
                      viewBox="0 0 24 24"
                      fill="none"
                      stroke="currentColor"
                      strokeWidth={2.5}
                      aria-hidden="true"
                    >
                      <path
                        strokeLinecap="round"
                        strokeLinejoin="round"
                        d="M5 13l4 4L19 7"
                      />
                    </svg>
                  )}
                  <span className="truncate">{option.label}</span>
                </span>
                {option.description && (
                  <span className="mt-0.5 block ps-[22px] text-caption leading-snug text-tertiary-label">
                    {option.description}
                  </span>
                )}
              </button>
            ))
          )}
        </div>
      )}
    </div>
  );
};
