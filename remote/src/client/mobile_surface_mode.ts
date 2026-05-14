import type { LayoutState, LayoutSurface } from "./types";

export type MobileSurfaceKind = "terminal" | "ai_chat" | "none";

export function selectedMobileSurfaceKind(
  layoutState: LayoutState | null,
  selectedTabIndex: number,
  selectedSurfaceId: string | null,
): MobileSurfaceKind {
  const tab =
    layoutState?.tabs.find((candidate) => candidate.index === selectedTabIndex) ??
    layoutState?.tabs.find((candidate) => candidate.index === layoutState.activeTab) ??
    layoutState?.tabs[0] ??
    null;
  if (!tab) return "none";

  const surface =
    findSurface(tab.surfaces, selectedSurfaceId) ??
    findSurface(tab.surfaces, tab.focusedSurfaceId ?? null) ??
    tab.surfaces[0] ??
    null;
  if (!surface) return "none";

  return surface.kind === "ai_chat" ? "ai_chat" : "terminal";
}

export function shouldShowMobileVirtualKeyboard(
  surfaceKind: MobileSurfaceKind,
  keyboardVisible: boolean,
): boolean {
  return keyboardVisible && surfaceKind === "terminal";
}

function findSurface(surfaces: LayoutSurface[], id: string | null): LayoutSurface | null {
  if (!id) return null;
  return surfaces.find((surface) => surface.id === id) ?? null;
}
