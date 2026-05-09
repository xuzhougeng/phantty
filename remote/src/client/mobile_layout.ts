export const MOBILE_REMOTE_MEDIA_QUERY =
  "(max-width: 860px), (pointer: coarse) and (max-width: 1024px)";

export type SurfaceFitMode = "remote-grid" | "viewport";

export function fitModeForSurface(hasRemoteGridDimensions: boolean): SurfaceFitMode {
  return hasRemoteGridDimensions ? "remote-grid" : "viewport";
}

export function shouldUseViewportFit(hasRemoteGridDimensions: boolean): boolean {
  return fitModeForSurface(hasRemoteGridDimensions) === "viewport";
}

export function shouldUseCanvasPan(
  hasRemoteGridDimensions: boolean,
  win: Pick<Window, "matchMedia"> = window,
): boolean {
  return hasRemoteGridDimensions || isMobileRemoteShell(win);
}

export function isMobileRemoteShell(win: Pick<Window, "matchMedia"> = window): boolean {
  return win.matchMedia(MOBILE_REMOTE_MEDIA_QUERY).matches;
}
