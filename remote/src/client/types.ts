import type { Terminal } from "@xterm/xterm";
import type { FitAddon } from "@xterm/addon-fit";
import type { CanvasPoint, CanvasSize } from "./mobile_canvas";

export type MeResponse = { authenticated: boolean; username?: string };

export type LayoutSurface = {
  id: string;
  kind?: "terminal" | "ai_chat";
  readOnly?: boolean;
  title?: string;
  focused?: boolean;
  snapshot?: string;
  cols?: number;
  rows?: number;
  cursorX?: number;
  cursorY?: number;
  requestInflight?: boolean;
  requestStopping?: boolean;
  x?: number;
  y?: number;
  w?: number;
  h?: number;
};

export type LayoutTab = {
  index: number;
  title?: string;
  focusedSurfaceId?: string;
  surfaces: LayoutSurface[];
};

export type LayoutState = { activeTab: number; tabs: LayoutTab[] };

export type RelayMessage = {
  type?: unknown;
  data?: unknown;
  encoding?: unknown;
  message?: unknown;
  surfaceId?: unknown;
  activeTab?: unknown;
  tabs?: unknown;
};

export type SurfaceView = {
  panel: HTMLElement;
  title: HTMLSpanElement;
  meta: HTMLElement;
  mount: HTMLDivElement;
  host: HTMLDivElement;
  scrollbar: HTMLDivElement;
  scrollbarThumb: HTMLDivElement;
  aiContainer: HTMLDivElement | null;
  aiTranscript: HTMLDivElement | null;
  aiInput: HTMLTextAreaElement | null;
  aiSend: HTMLButtonElement | null;
  aiStop: HTMLButtonElement | null;
  term: Terminal;
  fit: FitAddon;
  decoder: TextDecoder;
  disposeInput: { dispose(): void };
  disposeMiddleClickGesture: (() => void) | null;
  disposeCanvasPan: (() => void) | null;
  resizeObserver: ResizeObserver | null;
  fitQueued: boolean;
  canvasPan: CanvasPoint;
  lastCanvasViewport: CanvasSize | null;
  needsDefaultCanvasPan: boolean;
  hasLiveOutput: boolean;
  snapshotApplied: boolean;
  snapshotText: string | null;
  opened: boolean;
  pendingOutput: string;
  remoteCols: number | null;
  remoteRows: number | null;
};

export type ThemeMode = "dark" | "light";

export type StatusKind = "offline" | "connecting" | "online";
