import type { LayoutSurface } from "./types";

export function aiChatStopControlState(surface: LayoutSurface, connected: boolean): { disabled: boolean; label: string } {
  if (surface.requestStopping) return { disabled: true, label: "Stopping" };
  return {
    disabled: !connected || surface.requestInflight !== true,
    label: "Stop",
  };
}
