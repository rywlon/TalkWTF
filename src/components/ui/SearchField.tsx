import React from "react";
import { Search } from "lucide-react";

interface SearchFieldProps {
  value: string;
  onChange: (value: string) => void;
  placeholder?: string;
  className?: string;
}

/** macOS-style search field: rounded, subtle fill, leading magnifier. */
export const SearchField: React.FC<SearchFieldProps> = ({
  value,
  onChange,
  placeholder,
  className = "",
}) => (
  <div className={`relative ${className}`}>
    <Search className="pointer-events-none absolute start-2.5 top-1/2 h-4 w-4 -translate-y-1/2 text-tertiary-label" />
    <input
      type="search"
      value={value}
      onChange={(event) => onChange(event.target.value)}
      placeholder={placeholder}
      className="h-7 w-full rounded-[10px] border border-separator bg-fill ps-8 pe-3 text-body text-text placeholder:text-secondary-label focus:outline-none focus:ring-1 focus:ring-logo-primary [&::-webkit-search-cancel-button]:hidden"
    />
  </div>
);
