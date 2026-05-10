import type { LayoutState, LayoutTab, SurfaceView } from "./types";
import { readSavedKbdVisible, readSavedSidebarCollapsed } from "./storage";

type Listener = () => void;

const listeners = new Set<Listener>();

function notify(): void {
  for (const listener of listeners) listener();
}

export const state = {
  socket: null as WebSocket | null,
  layoutState: null as LayoutState | null,
  selectedTabIndex: 0,
  selectedSurfaceId: null as string | null,
  surfaceViews: new Map<string, SurfaceView>(),
  notices: [] as string[],
  hasSeenLayout: false,
  kbdVisible: readSavedKbdVisible() ?? true,
  drawerOpen: false,
  sidebarCollapsed: readSavedSidebarCollapsed() ?? false,
  activeSessionKey: null as string | null,
};

export function onStateChange(listener: Listener): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function emitStateChange(): void {
  notify();
}

export function currentTab(): LayoutTab | null {
  const layout = state.layoutState;
  if (!layout) return null;
  return (
    layout.tabs.find((tab) => tab.index === state.selectedTabIndex) ??
    layout.tabs.find((tab) => tab.index === layout.activeTab) ??
    layout.tabs[0] ??
    null
  );
}

export function activeSurfaceIdForInput(): string | null {
  return state.selectedSurfaceId ?? currentTab()?.surfaces[0]?.id ?? null;
}

export function pushNotice(message: string): void {
  state.notices = [...state.notices.slice(-5), message];
}

export function resetSurfaceViews(): void {
  state.surfaceViews = new Map();
}
