import React from "react";
import SelectComponent from "react-select";
import CreatableSelect from "react-select/creatable";
import type {
  ActionMeta,
  Props as ReactSelectProps,
  SingleValue,
  StylesConfig,
} from "react-select";

export type SelectOption = {
  value: string;
  label: string;
  isDisabled?: boolean;
};

type BaseProps = {
  value: string | null;
  options: SelectOption[];
  placeholder?: string;
  disabled?: boolean;
  isLoading?: boolean;
  isClearable?: boolean;
  onChange: (value: string | null, action: ActionMeta<SelectOption>) => void;
  onBlur?: () => void;
  className?: string;
  formatCreateLabel?: (input: string) => string;
};

type CreatableProps = {
  isCreatable: true;
  onCreateOption: (value: string) => void;
};

type NonCreatableProps = {
  isCreatable?: false;
  onCreateOption?: never;
};

export type SelectProps = BaseProps & (CreatableProps | NonCreatableProps);

const controlBackground =
  "color-mix(in srgb, var(--color-text) 6%, transparent)";
const hoverBackground =
  "color-mix(in srgb, var(--color-text) 10%, transparent)";
const selectedBackground =
  "color-mix(in srgb, var(--color-logo-primary) 16%, transparent)";
const neutralBorder = "var(--color-separator)";

/** macOS pop-up button chevron (up + down), replacing react-select's caret. */
const DropdownIndicator = () => (
  <svg
    className="mx-1.5 h-3.5 w-3.5 shrink-0 text-secondary-label"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    strokeWidth={2.2}
    aria-hidden="true"
  >
    <path
      strokeLinecap="round"
      strokeLinejoin="round"
      d="M8 9l4-4 4 4M8 15l4 4 4-4"
    />
  </svg>
);

const selectStyles: StylesConfig<SelectOption, false> = {
  control: (base, state) => ({
    ...base,
    minHeight: 28,
    height: 28,
    borderRadius: 8,
    borderColor: state.isFocused ? "var(--color-logo-primary)" : neutralBorder,
    boxShadow: state.isFocused ? "0 0 0 1px var(--color-logo-primary)" : "none",
    backgroundColor: state.isFocused ? hoverBackground : controlBackground,
    fontSize: "14px",
    color: "var(--color-text)",
    transition: "background-color 120ms ease",
    ":hover": { backgroundColor: hoverBackground },
  }),
  valueContainer: (base) => ({
    ...base,
    paddingInline: 10,
    paddingBlock: 0,
  }),
  indicatorsContainer: (base) => ({ ...base, height: 28 }),
  input: (base) => ({ ...base, color: "var(--color-text)" }),
  singleValue: (base) => ({ ...base, color: "var(--color-text)" }),
  dropdownIndicator: () => ({ display: "flex", padding: 0 }),
  clearIndicator: (base) => ({
    ...base,
    color: "var(--color-mid-gray)",
    padding: 0,
    ":hover": { color: "var(--color-text)" },
  }),
  indicatorSeparator: () => ({ display: "none" }),
  // Opaque: the window background is a translucent material on macOS, and a
  // translucent menu is unreadable over the content behind it.
  menu: (provided) => ({
    ...provided,
    zIndex: 30,
    marginTop: 4,
    backgroundColor: "var(--color-popover)",
    color: "var(--color-text)",
    border: "1px solid var(--color-separator)",
    borderRadius: 10,
    overflow: "hidden",
    boxShadow: "0 8px 28px rgba(0, 0, 0, 0.18)",
  }),
  menuList: (base) => ({ ...base, paddingTop: 4, paddingBottom: 4 }),
  option: (base, state) => ({
    ...base,
    fontSize: "14px",
    padding: "6px 10px",
    backgroundColor: state.isSelected
      ? selectedBackground
      : state.isFocused
        ? hoverBackground
        : "transparent",
    color: "var(--color-text)",
    cursor: state.isDisabled ? "not-allowed" : "pointer",
    opacity: state.isDisabled ? 0.5 : 1,
  }),
  placeholder: (base) => ({ ...base, color: "var(--color-secondary-label)" }),
};

export const Select: React.FC<SelectProps> = React.memo(
  ({
    value,
    options,
    placeholder,
    disabled,
    isLoading,
    isClearable = true,
    onChange,
    onBlur,
    className = "",
    isCreatable,
    formatCreateLabel,
    onCreateOption,
  }) => {
    const selectValue = React.useMemo(() => {
      if (!value) return null;
      const existing = options.find((option) => option.value === value);
      if (existing) return existing;
      return { value, label: value, isDisabled: false };
    }, [value, options]);

    const handleChange = (
      option: SingleValue<SelectOption>,
      action: ActionMeta<SelectOption>,
    ) => {
      onChange(option?.value ?? null, action);
    };

    const sharedProps: Partial<ReactSelectProps<SelectOption, false>> = {
      className,
      classNamePrefix: "app-select",
      value: selectValue,
      options,
      onChange: handleChange,
      placeholder,
      isDisabled: disabled,
      isLoading,
      onBlur,
      isClearable,
      styles: selectStyles,
      components: { DropdownIndicator },
    };

    if (isCreatable) {
      return (
        <CreatableSelect<SelectOption, false>
          {...sharedProps}
          onCreateOption={onCreateOption}
          formatCreateLabel={formatCreateLabel}
        />
      );
    }

    return <SelectComponent<SelectOption, false> {...sharedProps} />;
  },
);

Select.displayName = "Select";
