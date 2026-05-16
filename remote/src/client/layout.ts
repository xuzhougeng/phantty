import type { LayoutState, LayoutSurface, LayoutTab, RelayMessage } from "./types";
import { numberOr, shortSurfaceId } from "./utils";

export function isLayoutMessage(message: RelayMessage): boolean {
  return message.type === "layout" && Array.isArray(message.tabs);
}

export function normalizeLayout(message: RelayMessage): LayoutState {
  const activeTab = typeof message.activeTab === "number" ? message.activeTab : 0;
  const rawTabs = Array.isArray(message.tabs) ? message.tabs : [];
  const tabs: LayoutTab[] = rawTabs
    .map((raw): LayoutTab | null => {
      if (!raw || typeof raw !== "object") return null;
      const tab = raw as Record<string, unknown>;
      const index = typeof tab.index === "number" ? tab.index : 0;
      const surfaces = Array.isArray(tab.surfaces)
        ? tab.surfaces.map(normalizeSurface).filter((surface): surface is LayoutSurface => Boolean(surface))
        : [];
      return {
        index,
        title: typeof tab.title === "string" ? tab.title : `Tab ${index + 1}`,
        focusedSurfaceId: typeof tab.focusedSurfaceId === "string" ? tab.focusedSurfaceId : surfaces[0]?.id,
        surfaces,
      };
    })
    .filter((tab): tab is LayoutTab => Boolean(tab));
  return { activeTab, tabs };
}

function normalizeSurface(raw: unknown): LayoutSurface | null {
  if (!raw || typeof raw !== "object") return null;
  const surface = raw as Record<string, unknown>;
  if (typeof surface.id !== "string") return null;
  return {
    id: surface.id,
    kind: surface.kind === "ai_chat" ? "ai_chat" : "terminal",
    readOnly: surface.readOnly === true,
    title: typeof surface.title === "string" ? surface.title : shortSurfaceId(surface.id),
    focused: surface.focused === true,
    snapshot: typeof surface.snapshot === "string" ? surface.snapshot : "",
    cols: numberOr(surface.cols, 0),
    rows: numberOr(surface.rows, 0),
    cursorX: numberOr(surface.cursorX, 0),
    cursorY: numberOr(surface.cursorY, 0),
    requestInflight: surface.requestInflight === true,
    requestStopping: surface.requestStopping === true,
    x: numberOr(surface.x, 0),
    y: numberOr(surface.y, 0),
    w: numberOr(surface.w, 1),
    h: numberOr(surface.h, 1),
  };
}
