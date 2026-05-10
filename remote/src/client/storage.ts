import type { ThemeMode } from "./types";

const SESSION_KEY_STORAGE_KEY = "phantty.remote.sessionKey";
const KBD_VISIBLE_STORAGE_KEY = "phantty.remote.kbdVisible";
const THEME_STORAGE_KEY = "phantty.remote.theme";
const SIDEBAR_COLLAPSED_STORAGE_KEY = "phantty.remote.sidebarCollapsed";

export function readSavedSessionKey(): string {
  try {
    return localStorage.getItem(SESSION_KEY_STORAGE_KEY)?.trim() ?? "";
  } catch {
    return "";
  }
}

export function saveSessionKey(sessionKey: string): void {
  if (!sessionKey) {
    clearSessionKey();
    return;
  }
  try {
    localStorage.setItem(SESSION_KEY_STORAGE_KEY, sessionKey);
  } catch {
    // Storage may be unavailable in restricted browser contexts.
  }
}

export function clearSessionKey(): void {
  try {
    localStorage.removeItem(SESSION_KEY_STORAGE_KEY);
  } catch {
    // Storage may be unavailable in restricted browser contexts.
  }
}

export function maskSessionKey(sessionKey: string): string {
  if (!sessionKey) return "";
  return `${sessionKey.slice(0, 4)}****`;
}

export function readSavedKbdVisible(): boolean | null {
  try {
    const raw = localStorage.getItem(KBD_VISIBLE_STORAGE_KEY);
    if (raw === "1") return true;
    if (raw === "0") return false;
    return null;
  } catch {
    return null;
  }
}

export function saveKbdVisible(visible: boolean): void {
  try {
    localStorage.setItem(KBD_VISIBLE_STORAGE_KEY, visible ? "1" : "0");
  } catch {
    // Storage may be unavailable in restricted browser contexts.
  }
}

export function readSavedSidebarCollapsed(): boolean | null {
  try {
    const raw = localStorage.getItem(SIDEBAR_COLLAPSED_STORAGE_KEY);
    if (raw === "1") return true;
    if (raw === "0") return false;
    return null;
  } catch {
    return null;
  }
}

export function saveSidebarCollapsed(collapsed: boolean): void {
  try {
    localStorage.setItem(SIDEBAR_COLLAPSED_STORAGE_KEY, collapsed ? "1" : "0");
  } catch {
    // Storage may be unavailable in restricted browser contexts.
  }
}

export function readSavedTheme(): ThemeMode {
  try {
    const raw = localStorage.getItem(THEME_STORAGE_KEY);
    if (raw === "light" || raw === "dark") return raw;
  } catch {
    // localStorage may be unavailable.
  }
  return "dark";
}

export function saveTheme(mode: ThemeMode): void {
  try {
    localStorage.setItem(THEME_STORAGE_KEY, mode);
  } catch {
    // Storage may be unavailable.
  }
}
