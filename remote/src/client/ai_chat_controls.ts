import type { LayoutSurface } from "./types";

export function aiChatStopControlState(surface: LayoutSurface, connected: boolean): { disabled: boolean; label: string } {
  if (surface.requestStopping) return { disabled: true, label: "Stopping" };
  const hasRuntimeState = typeof surface.requestInflight === "boolean";
  return {
    disabled: !connected || (hasRuntimeState && surface.requestInflight !== true),
    label: "Stop",
  };
}
