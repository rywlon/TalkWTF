import { commands, type Theme } from "@/bindings";

/**
 * Appearance theme handling.
 *
 * Handy already ships a full light palette and a full dark palette (see
 * `App.css`). This module lets the user pick which one is used instead of
 * always following the OS:
 *  - `system` removes the override so the `prefers-color-scheme` media query
 *    governs (the historical behaviour).
 *  - `light` / `dark` set `data-theme` on the document root, whose
 *    higher-specificity CSS selectors win over the media query.
 *
 * The choice is persisted in `AppSettings` (source of truth) and mirrored to
 * localStorage so it can be applied synchronously on boot, before React mounts,
 * avoiding a flash of the wrong palette.
 */

export const THEME_STORAGE_KEY = "handy.theme";

export const THEME_OPTIONS: Theme[] = ["system", "light", "dark"];

const isTheme = (value: unknown): value is Theme =>
  value === "system" || value === "light" || value === "dark";

/** Apply a theme to the document root and remember it for the next launch. */
export const applyTheme = (theme: Theme): void => {
  const root = document.documentElement;
  if (theme === "system") {
    delete root.dataset.theme;
  } else {
    root.dataset.theme = theme;
  }
  try {
    localStorage.setItem(THEME_STORAGE_KEY, theme);
  } catch {
    // localStorage may be unavailable (e.g. private mode); the setting still
    // persists in AppSettings, so this only costs a one-frame flash on boot.
  }
};

/** Read the last-applied theme for synchronous boot-time application. */
export const getStoredTheme = (): Theme => {
  try {
    const stored = localStorage.getItem(THEME_STORAGE_KEY);
    if (isTheme(stored)) return stored;
  } catch {
    // ignore
  }
  return "system";
};

/** Apply the persisted theme from AppSettings (the source of truth). */
export const syncThemeFromSettings = async (): Promise<void> => {
  try {
    const result = await commands.getAppSettings();
    if (result.status === "ok") {
      applyTheme(result.data.theme ?? "system");
    }
  } catch (e) {
    console.warn("Failed to sync theme from settings:", e);
  }
};

/**
 * Apply an explicit accent color (`#rrggbb`) to the document root. macOS uses
 * one accent for both appearances, so overriding the themed token in both light
 * and dark is correct. An empty value clears the override, restoring the CSS
 * fallback (system blue).
 */
export const applyAccent = (hex: string): void => {
  const root = document.documentElement;
  if (hex) {
    root.style.setProperty("--color-accent", hex);
    root.style.setProperty("--color-logo-primary", hex);
    root.style.setProperty("--color-background-ui", hex);
  } else {
    root.style.removeProperty("--color-accent");
    root.style.removeProperty("--color-logo-primary");
    root.style.removeProperty("--color-background-ui");
  }
};

/** Read the OS accent color and apply it. Falls back to the CSS default. */
export const syncAccentFromSystem = async (): Promise<void> => {
  try {
    const hex = await commands.getSystemAccentColor();
    applyAccent(hex);
  } catch (e) {
    console.warn("Failed to read the system accent color:", e);
  }
};
