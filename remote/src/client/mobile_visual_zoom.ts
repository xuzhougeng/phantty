import type { CanvasSize } from "./mobile_canvas";
import type { MobileVisualZoom } from "./types";

export const MOBILE_VISUAL_ZOOM_LEVELS: readonly MobileVisualZoom[] = [1, 0.75, 0.5, 0.25];

export function normalizeMobileVisualZoom(raw: unknown): MobileVisualZoom {
  const text = typeof raw === "number" ? String(raw) : String(raw ?? "").trim();
  if (!text) return 1;

  const numeric = Number(text.endsWith("%") ? text.slice(0, -1) : text);
  if (!Number.isFinite(numeric)) return 1;

  const normalized = numeric > 1 ? numeric / 100 : numeric;
  return findZoomLevel(normalized);
}

export function nextMobileVisualZoom(zoom: MobileVisualZoom): MobileVisualZoom {
  const index = MOBILE_VISUAL_ZOOM_LEVELS.indexOf(zoom);
  return MOBILE_VISUAL_ZOOM_LEVELS[(index + 1) % MOBILE_VISUAL_ZOOM_LEVELS.length] ?? 1;
}

export function mobileVisualZoomLabel(zoom: MobileVisualZoom): string {
  return `${mobileVisualZoomPercent(zoom)}%`;
}

export function mobileVisualZoomPercent(zoom: MobileVisualZoom): number {
  return Math.round(zoom * 100);
}

export function scaleVisualCanvasSize(size: CanvasSize, zoom: MobileVisualZoom): CanvasSize {
  if (zoom === 1) return size;
  return {
    width: Math.max(0, Math.round(size.width * zoom)),
    height: Math.max(0, Math.round(size.height * zoom)),
  };
}

function findZoomLevel(value: number): MobileVisualZoom {
  for (const level of MOBILE_VISUAL_ZOOM_LEVELS) {
    if (Math.abs(value - level) < 0.001) return level;
  }
  return 1;
}
