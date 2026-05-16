import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";

import type { LayoutSurface, SurfaceView } from "./types";
import {
  CANVAS_WHEEL_EVENT_OPTIONS,
  canvasPanRenderState,
  defaultCanvasPan,
  isCanvasDrag,
  meaningfulTerminalCanvasHeight,
  panYFromVerticalScrollbarThumb,
  panCanvasBy,
  panCanvasByWheel,
  resizeCanvasPan,
  shouldConsumeCanvasWheel,
  shouldStartCanvasPanDrag,
  terminalCanScrollHistory,
  touchHistoryScrollLines,
  verticalScrollbarMetrics,
  type CanvasPoint,
  type CanvasSize,
} from "./mobile_canvas";
import { shouldFocusTerminalElement } from "./focus_policy";
import { parseAiChatTranscript, type AiChatMessage } from "./ai_chat_transcript";
import { aiChatStopControlState } from "./ai_chat_controls";
import { isMobileRemoteShell, shouldUseCanvasPan, shouldUseViewportFit } from "./mobile_layout";
import { mobileVisualZoomPercent, scaleVisualCanvasSize } from "./mobile_visual_zoom";
import { setNativeTerminalInputBlocked, shouldBlockNativeTerminalInput } from "./terminal_input_guard";
import { cursorMoveSequence, emptyState, shortSurfaceId, validPositiveInteger } from "./utils";
import { activeSurfaceIdForInput, currentTab, resetSurfaceViews, state } from "./state";
import { getTerminalPalette, subscribeToTheme } from "./theme";
import { REMOTE_TERMINAL_SCROLLBACK } from "./terminal_options";

const PENDING_OUTPUT_LIMIT = 128 * 1024;
const MOBILE_CANVAS_BOTTOM_GUTTER = 12;
const DESKTOP_SCROLLBAR_MIN_THUMB_HEIGHT = 32;
const DESKTOP_SCROLLBAR_VERTICAL_INSET = 10;

type InputHandler = (surfaceId: string, data: string) => void;
let inputHandler: InputHandler = () => {
  // no-op until transport registers
};

export function setSurfaceInputHandler(handler: InputHandler): void {
  inputHandler = handler;
}

subscribeToTheme((palette) => {
  for (const view of state.surfaceViews.values()) {
    view.term.options.theme = palette;
    if (view.opened && view.term.rows > 0) {
      view.term.refresh(0, view.term.rows - 1);
    }
  }
});

export function ensureSurfaceView(surfaceId: string): SurfaceView {
  const existing = state.surfaceViews.get(surfaceId);
  if (existing) return existing;

  const host = document.createElement("div");
  host.className = "terminal-host";
  const panel = document.createElement("section");
  panel.className = "remote-panel";
  panel.dataset.surfaceId = surfaceId;
  const header = document.createElement("div");
  header.className = "panel-header";
  const title = document.createElement("span");
  title.className = "panel-title";
  const meta = document.createElement("small");
  const copyButton = document.createElement("button");
  copyButton.type = "button";
  copyButton.className = "panel-copy";
  copyButton.textContent = "Copy";
  copyButton.title = "Copy selection or visible text";
  copyButton.setAttribute("aria-label", "Copy terminal text");
  header.appendChild(title);
  header.appendChild(meta);
  header.appendChild(copyButton);
  const mount = document.createElement("div");
  mount.className = "terminal-mount";
  const scrollbar = document.createElement("div");
  scrollbar.className = "canvas-scrollbar";
  scrollbar.dataset.visible = "false";
  scrollbar.setAttribute("aria-hidden", "true");
  const scrollbarThumb = document.createElement("div");
  scrollbarThumb.className = "canvas-scrollbar-thumb";
  scrollbar.appendChild(scrollbarThumb);
  mount.appendChild(host);
  mount.appendChild(scrollbar);
  panel.appendChild(header);
  panel.appendChild(mount);

  const selectThis = (): void => {
    state.selectedSurfaceId = surfaceId;
    renderRemotePanels();
  };
  panel.addEventListener("pointerdown", selectThis);
  panel.addEventListener("click", () => {
    selectThis();
    focusSurfaceView(surfaceId);
  });

  const fit = new FitAddon();
  const term = new Terminal({
    cursorBlink: true,
    cursorInactiveStyle: "outline",
    cursorStyle: "bar",
    cursorWidth: 2,
    convertEol: true,
    disableStdin: false,
    fontFamily: '"JetBrains Mono", "Cascadia Mono", monospace',
    fontSize: 13,
    scrollback: REMOTE_TERMINAL_SCROLLBACK,
    theme: getTerminalPalette(),
  });
  term.loadAddon(fit);

  const view: SurfaceView = {
    panel,
    title,
    meta,
    copyButton,
    mount,
    host,
    scrollbar,
    scrollbarThumb,
    aiContainer: null,
    aiTranscript: null,
    aiInput: null,
    aiSend: null,
    aiStop: null,
    term,
    fit,
    decoder: new TextDecoder(),
    disposeInput: term.onData((data) => {
      if (isViewModeInputBlocked()) return;
      const current = state.layoutState?.tabs
        .flatMap((tab) => tab.surfaces)
        .find((surface) => surface.id === surfaceId);
      if (current?.kind === "ai_chat") return;
      if (current?.readOnly) return;
      inputHandler(surfaceId, data);
    }),
    disposeMiddleClickGesture: null,
    disposeCanvasPan: null,
    resizeObserver: null,
    fitQueued: false,
    canvasPan: { x: 0, y: 0 },
    lastCanvasViewport: null,
    needsDefaultCanvasPan: false,
    hasLiveOutput: false,
    snapshotApplied: false,
    snapshotText: null,
    opened: false,
    pendingOutput: "",
    remoteCols: null,
    remoteRows: null,
  };
  copyButton.addEventListener("pointerdown", (event) => {
    event.stopPropagation();
  });
  copyButton.addEventListener("click", (event) => {
    event.preventDefault();
    event.stopPropagation();
    void copyTerminalText(view);
  });
  view.disposeMiddleClickGesture = bindTwoFingerMiddleClick(view);
  view.disposeCanvasPan = bindCanvasPan(view);
  state.surfaceViews.set(surfaceId, view);
  return view;
}

export function renderRemotePanels(): void {
  const panelsRoot = document.querySelector<HTMLDivElement>("#remote-panels");
  const titleRoot = document.querySelector<HTMLSpanElement>("#workspace-title");
  if (!panelsRoot) return;

  const tab = currentTab();
  if (!tab || tab.surfaces.length === 0) {
    panelsRoot.className = "panels-stage empty";
    delete panelsRoot.dataset.mobileMode;
    delete panelsRoot.dataset.desktopMode;
    panelsRoot.replaceChildren(emptyState("No panels for this tab yet."));
    const fallback = "Remote workspace";
    if (titleRoot) titleRoot.textContent = fallback;
    const mobileTitleRoot = document.querySelector<HTMLSpanElement>("#mobile-workspace-title");
    if (mobileTitleRoot) mobileTitleRoot.textContent = fallback;
    return;
  }

  const tabTitle = tab.title || `Tab ${tab.index + 1}`;
  if (titleRoot) titleRoot.textContent = tabTitle;
  const mobileTitleRoot = document.querySelector<HTMLSpanElement>("#mobile-workspace-title");
  if (mobileTitleRoot) mobileTitleRoot.textContent = tabTitle;
  panelsRoot.className = "panels-stage";
  panelsRoot.dataset.mobileMode = "single";
  panelsRoot.dataset.desktopMode = state.desktopPanelMode;
  panelsRoot.querySelectorAll(".empty-state").forEach((node) => node.remove());
  const visible = new Set(tab.surfaces.map((surface) => surface.id));

  for (const surface of tab.surfaces) {
    const view = ensureSurfaceView(surface.id);
    const selected = surface.id === state.selectedSurfaceId;
    view.panel.className = `remote-panel${selected ? " selected" : ""}${surface.kind === "ai_chat" ? " ai-chat-panel" : ""}`;
    view.panel.style.left = `${(surface.x ?? 0) * 100}%`;
    view.panel.style.top = `${(surface.y ?? 0) * 100}%`;
    view.panel.style.width = `${Math.max(0.05, surface.w ?? 1) * 100}%`;
    view.panel.style.height = `${Math.max(0.05, surface.h ?? 1) * 100}%`;
    view.panel.dataset.surfaceId = surface.id;
    view.title.textContent = surface.title || shortSurfaceId(surface.id);
    view.copyButton.hidden = surface.kind === "ai_chat";
    applySurfaceInputPolicy(view, surface);
    const nextRemoteCols = validPositiveInteger(surface.cols);
    const nextRemoteRows = validPositiveInteger(surface.rows);
    const gridChanged = view.remoteCols !== nextRemoteCols || view.remoteRows !== nextRemoteRows;
    view.remoteCols = nextRemoteCols;
    view.remoteRows = nextRemoteRows;
    if (gridChanged) view.needsDefaultCanvasPan = true;
    const grid = view.remoteCols && view.remoteRows ? `${view.remoteCols}×${view.remoteRows}` : null;
    const stateLabel = surface.readOnly ? "read-only" : surface.focused ? "focused" : shortSurfaceId(surface.id);
    const kindLabel = surface.kind === "ai_chat" ? "AI chat" : null;
    view.meta.textContent = [grid, kindLabel, stateLabel].filter(Boolean).join(" · ");

    if (view.panel.parentElement !== panelsRoot) {
      panelsRoot.appendChild(view.panel);
    }

    if (surface.kind === "ai_chat") {
      renderAiChatPanel(view, surface);
      continue;
    }

    ensureTerminalMount(view);
    applySurfaceVisualZoom(view);
    if (!view.opened) {
      view.term.open(view.host);
      view.opened = true;
      applySurfaceVisualZoom(view);
      syncTerminalNativeInputGuard(view);
      view.resizeObserver = new ResizeObserver(() => scheduleFit(view));
      view.resizeObserver.observe(view.host);
      flushPendingOutput(view);
    }
    updateSurfaceCursor(view, surface.id);
    applyInitialSnapshot(view, surface);
    scheduleFit(view);

    if (
      surface.id === state.selectedSurfaceId &&
      shouldFocusTerminalElement() &&
      document.activeElement &&
      view.panel.contains(document.activeElement)
    ) {
      view.term.focus();
    }
  }

  for (const [surfaceId, view] of state.surfaceViews) {
    if (!visible.has(surfaceId) && view.panel.parentElement === panelsRoot) {
      view.panel.remove();
    }
  }
}

export function focusAndFitSelectedSurface(): void {
  const id = state.selectedSurfaceId;
  if (!id) return;
  const view = state.surfaceViews.get(id);
  if (!view) return;
  if (view.aiInput) {
    if (!isMobileRemoteShell()) view.aiInput.focus();
    return;
  }
  if (shouldFocusTerminalElement()) view.term.focus();
  scheduleFit(view);
}

export function reconcileSurfaceViews(): void {
  if (!state.layoutState) return;
  const live = new Set(state.layoutState.tabs.flatMap((tab) => tab.surfaces.map((surface) => surface.id)));
  for (const [surfaceId, view] of state.surfaceViews) {
    if (!live.has(surfaceId)) {
      view.resizeObserver?.disconnect();
      view.disposeInput.dispose();
      view.disposeMiddleClickGesture?.();
      view.disposeCanvasPan?.();
      view.term.dispose();
      state.surfaceViews.delete(surfaceId);
    }
  }
}

export function disposeSurfaceViews(): void {
  for (const view of state.surfaceViews.values()) {
    view.resizeObserver?.disconnect();
    view.disposeInput.dispose();
    view.disposeMiddleClickGesture?.();
    view.disposeCanvasPan?.();
    view.term.dispose();
  }
  resetSurfaceViews();
}

export function writeSurfaceBytes(surfaceId: string, bytes: Uint8Array): void {
  const view = ensureSurfaceView(surfaceId);
  view.hasLiveOutput = true;
  writeSurfaceText(view, view.decoder.decode(bytes, { stream: true }));
}

export function writeLegacyOutput(data: string): void {
  const surfaceId = state.selectedSurfaceId ?? currentTab()?.surfaces[0]?.id ?? "legacy";
  const view = ensureSurfaceView(surfaceId);
  view.hasLiveOutput = true;
  writeSurfaceText(view, data);
}

export function focusActiveSurface(): void {
  const id = activeSurfaceIdForInput();
  if (id) focusSurfaceView(id);
}

export function refitAllSurfaces(): void {
  for (const view of state.surfaceViews.values()) scheduleFit(view);
}

export function updateSurfaceCursors(): void {
  for (const [surfaceId, view] of state.surfaceViews) {
    const surface = state.layoutState?.tabs
      .flatMap((tab) => tab.surfaces)
      .find((candidate) => candidate.id === surfaceId);
    applySurfaceInputPolicy(view, surface);
    updateSurfaceCursor(view, surfaceId);
  }
}

export function syncTerminalNativeInputGuards(): void {
  for (const view of state.surfaceViews.values()) {
    syncTerminalNativeInputGuard(view);
  }
}

export function syncSurfaceVisualZooms(): void {
  for (const view of state.surfaceViews.values()) {
    applySurfaceVisualZoom(view);
    view.needsDefaultCanvasPan = true;
    view.lastCanvasViewport = null;
    scheduleFit(view);
  }
}

function focusSurfaceView(surfaceId: string): void {
  const view = ensureSurfaceView(surfaceId);
  if (view.aiInput) {
    if (!isMobileRemoteShell()) view.aiInput.focus();
    return;
  }
  if (shouldFocusTerminalElement()) view.term.focus();
}

function ensureTerminalMount(view: SurfaceView): void {
  if (view.host.parentElement === view.mount && view.scrollbar.parentElement === view.mount) return;
  view.mount.className = "terminal-mount";
  view.mount.replaceChildren(view.host, view.scrollbar);
}

function applySurfaceVisualZoom(view: SurfaceView): void {
  const zoom = isMobileRemoteShell() ? state.mobileVisualZoom : 1;
  view.panel.dataset.visualZoom = String(mobileVisualZoomPercent(zoom));
  view.host.style.setProperty("--remote-terminal-visual-zoom", String(zoom));
}

function renderAiChatPanel(view: SurfaceView, surface: LayoutSurface): void {
  const container = ensureAiChatElements(view, surface.id);
  if (container.parentElement !== view.mount) {
    view.mount.className = "terminal-mount ai-chat-mount";
    view.mount.replaceChildren(container);
  }
  const snapshot = surface.snapshot || "No messages yet.";
  if (view.snapshotText !== snapshot && view.aiTranscript) {
    view.snapshotText = snapshot;
    renderAiChatTranscript(view.aiTranscript, snapshot);
    requestAnimationFrame(() => {
      if (view.aiTranscript) view.aiTranscript.scrollTop = view.aiTranscript.scrollHeight;
    });
  }
  updateAiChatControl(view, surface);
}

function ensureAiChatElements(view: SurfaceView, surfaceId: string): HTMLDivElement {
  if (view.aiContainer && view.aiTranscript && view.aiInput && view.aiSend && view.aiStop) return view.aiContainer;

  const container = document.createElement("div");
  container.className = "ai-chat-remote";

  const transcript = document.createElement("div");
  transcript.className = "ai-chat-transcript";

  const form = document.createElement("form");
  form.className = "ai-chat-composer";

  const input = document.createElement("textarea");
  input.className = "ai-chat-input";
  input.rows = 3;
  input.placeholder = "Ask Agent";
  input.spellcheck = false;

  const send = document.createElement("button");
  send.className = "ai-chat-send";
  send.type = "submit";
  send.textContent = "Send";

  const stop = document.createElement("button");
  stop.className = "ai-chat-stop";
  stop.type = "button";
  stop.textContent = "Stop";
  stop.disabled = true;

  const submit = (): void => {
    const text = input.value.trim();
    if (!text) return;
    input.value = "";
    inputHandler(surfaceId, `${text}\r`);
  };

  input.addEventListener("keydown", (event) => {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      submit();
      return;
    }
    if (event.key === "Escape") {
      event.preventDefault();
      inputHandler(surfaceId, "\x1b");
    }
  });

  form.addEventListener("submit", (event) => {
    event.preventDefault();
    submit();
  });

  stop.addEventListener("click", () => {
    stop.disabled = true;
    stop.textContent = "Stopping";
    stop.dataset.active = "false";
    inputHandler(surfaceId, "\x1b");
  });

  form.appendChild(input);
  form.appendChild(send);
  form.appendChild(stop);
  container.appendChild(transcript);
  container.appendChild(form);

  view.aiContainer = container;
  view.aiTranscript = transcript;
  view.aiInput = input;
  view.aiSend = send;
  view.aiStop = stop;
  return container;
}

function updateAiChatControl(view: SurfaceView, surface: LayoutSurface): void {
  if (!view.aiStop) return;
  const connected = state.socket?.readyState === WebSocket.OPEN;
  const stopState = aiChatStopControlState(surface, connected);
  view.aiStop.disabled = stopState.disabled;
  view.aiStop.textContent = stopState.label;
  view.aiStop.dataset.active = String(surface.requestInflight === true && !stopState.disabled);
}

export function updateAiChatControls(): void {
  const surfaces = state.layoutState?.tabs.flatMap((tab) => tab.surfaces) ?? [];
  for (const surface of surfaces) {
    if (surface.kind !== "ai_chat") continue;
    const view = state.surfaceViews.get(surface.id);
    if (view) updateAiChatControl(view, surface);
  }
}

async function copyTerminalText(view: SurfaceView): Promise<void> {
  const text = terminalCopyText(view);
  if (!text) {
    flashCopyButton(view.copyButton, "Empty");
    return;
  }

  try {
    await writeClipboardText(text);
    flashCopyButton(view.copyButton, "Copied");
  } catch {
    flashCopyButton(view.copyButton, "Failed");
  }
}

function terminalCopyText(view: SurfaceView): string {
  const selection = view.term.getSelection();
  if (selection.length > 0) return selection;
  return visibleTerminalText(view);
}

function visibleTerminalText(view: SurfaceView): string {
  const buffer = view.term.buffer.active;
  const lines: string[] = [];
  const start = buffer.viewportY;
  for (let row = 0; row < view.term.rows; row += 1) {
    lines.push(buffer.getLine(start + row)?.translateToString(true) ?? "");
  }
  while (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
  return lines.join("\n");
}

async function writeClipboardText(text: string): Promise<void> {
  if (navigator.clipboard?.writeText && window.isSecureContext) {
    await navigator.clipboard.writeText(text);
    return;
  }

  const textarea = document.createElement("textarea");
  textarea.value = text;
  textarea.setAttribute("readonly", "true");
  textarea.style.position = "fixed";
  textarea.style.left = "-9999px";
  textarea.style.top = "0";
  document.body.appendChild(textarea);
  textarea.select();
  const ok = document.execCommand("copy");
  textarea.remove();
  if (!ok) throw new Error("copy command failed");
}

function flashCopyButton(button: HTMLButtonElement, label: string): void {
  const previous = button.textContent || "Copy";
  button.textContent = label;
  window.setTimeout(() => {
    if (button.isConnected) button.textContent = previous;
  }, 1200);
}

function renderAiChatTranscript(root: HTMLDivElement, snapshot: string): void {
  const messages = parseAiChatTranscript(snapshot);
  root.replaceChildren();

  if (messages.length === 0) {
    const empty = document.createElement("div");
    empty.className = "ai-chat-empty";
    empty.textContent = "No messages yet.";
    root.appendChild(empty);
    return;
  }

  for (const message of messages) {
    root.appendChild(renderAiChatMessage(message));
  }
}

function renderAiChatMessage(message: AiChatMessage): HTMLElement {
  const item = document.createElement("article");
  item.className = `ai-chat-message ${message.role}`;

  const label = document.createElement("div");
  label.className = "ai-chat-message-label";
  label.textContent = message.label;

  const bubble = document.createElement("div");
  bubble.className = "ai-chat-bubble";
  bubble.textContent = message.content || " ";

  item.appendChild(label);
  item.appendChild(bubble);
  return item;
}

function updateSurfaceCursor(view: SurfaceView, surfaceId: string): void {
  const selected = surfaceId === state.selectedSurfaceId;
  view.term.options.cursorBlink = selected;
  view.term.options.cursorInactiveStyle = selected ? "outline" : "none";
}

function applySurfaceInputPolicy(view: SurfaceView, surface: LayoutSurface | undefined): void {
  view.term.options.disableStdin =
    surface?.kind === "ai_chat" || surface?.readOnly === true || isViewModeInputBlocked();
  syncTerminalNativeInputGuard(view);
}

function syncTerminalNativeInputGuard(view: SurfaceView): void {
  setNativeTerminalInputBlocked(view.host, isViewModeInputBlocked(), document.activeElement);
}

function isViewModeInputBlocked(): boolean {
  return shouldBlockNativeTerminalInput(isMobileRemoteShell(), state.mobileInputMode);
}

function fitOrResize(view: SurfaceView): void {
  const hasRemoteGridDimensions = view.remoteCols !== null && view.remoteRows !== null;
  const useViewportFit = shouldUseViewportFit(hasRemoteGridDimensions);
  if (!useViewportFit && view.remoteCols && view.remoteRows) {
    if (view.term.cols !== view.remoteCols || view.term.rows !== view.remoteRows) {
      view.term.resize(view.remoteCols, view.remoteRows);
    }
    return;
  }

  view.fit.fit();
}

function scheduleFit(view: SurfaceView): void {
  if (view.fitQueued) return;
  view.fitQueued = true;
  requestAnimationFrame(() => {
    view.fitQueued = false;
    if (!view.host.isConnected) return;
    try {
      fitOrResize(view);
      updateCanvasPan(view);
      view.term.refresh(0, Math.max(0, view.term.rows - 1));
    } catch {
      // xterm can briefly report zero-sized panels while layout is settling.
    }
  });
}

function applyInitialSnapshot(view: SurfaceView, surface: LayoutSurface): void {
  if (!surface.snapshot) return;
  if (surface.kind === "ai_chat") {
    if (view.snapshotText === surface.snapshot) return;
    view.snapshotText = surface.snapshot;
    view.snapshotApplied = true;
    view.hasLiveOutput = false;
  } else {
    if (view.snapshotApplied || view.hasLiveOutput) return;
    view.snapshotApplied = true;
    view.snapshotText = surface.snapshot;
  }
  requestAnimationFrame(() => {
    if (!view.host.isConnected || (surface.kind !== "ai_chat" && view.hasLiveOutput)) return;
    try {
      fitOrResize(view);
      updateCanvasPan(view);
    } catch {
      // xterm can briefly report zero-sized panels while layout is settling.
    }
    view.term.reset();
    view.term.write((surface.snapshot ?? "") + cursorMoveSequence(surface));
    view.term.refresh(0, Math.max(0, view.term.rows - 1));
  });
}

function writeSurfaceText(view: SurfaceView, text: string): void {
  if (!text) return;
  if (!view.opened) {
    view.pendingOutput = capPendingOutput(view.pendingOutput + text);
    return;
  }
  flushPendingOutput(view);
  view.term.write(text);
}

function flushPendingOutput(view: SurfaceView): void {
  if (!view.opened || !view.pendingOutput) return;
  const pending = view.pendingOutput;
  view.pendingOutput = "";
  view.term.write(pending);
}

function capPendingOutput(value: string): string {
  return value.length > PENDING_OUTPUT_LIMIT ? value.slice(value.length - PENDING_OUTPUT_LIMIT) : value;
}

function bindCanvasPan(view: SurfaceView): () => void {
  const mount = view.mount;
  const scrollbar = view.scrollbar;
  const scrollbarThumb = view.scrollbarThumb;
  let activePointerId: number | null = null;
  let startClient: CanvasPoint = { x: 0, y: 0 };
  let startPan: CanvasPoint = { x: 0, y: 0 };
  let lastHistoryClientY = 0;
  let dragged = false;
  let suppressClick = false;
  let suppressClickButton: number | null = null;
  let scrollbarPointerId: number | null = null;
  let scrollbarGrabOffset = 0;

  const onPointerDown = (event: PointerEvent): void => {
    if (
      !shouldStartCanvasPanDrag({
        mobile: isMobileRemoteShell(),
        isPrimary: event.isPrimary,
        button: event.button,
      })
    ) return;
    const mobile = isMobileRemoteShell();
    updateCanvasPan(view);
    const viewport = canvasViewportSize(view);
    const canvas = canvasContentSize(view);
    const hasScrollableHistory = mobile && view.term.buffer.active.baseY > 0;
    if (canvas.width <= viewport.width && canvas.height <= viewport.height && !hasScrollableHistory) return;

    event.preventDefault();
    activePointerId = event.pointerId;
    startClient = { x: event.clientX, y: event.clientY };
    lastHistoryClientY = event.clientY;
    startPan = view.canvasPan;
    dragged = false;
    try {
      mount.setPointerCapture(event.pointerId);
    } catch {
      // Pointer capture can fail if the browser cancels the touch during layout changes.
    }
  };

  const onPointerMove = (event: PointerEvent): void => {
    if (activePointerId !== event.pointerId) return;
    const delta = { x: event.clientX - startClient.x, y: event.clientY - startClient.y };
    if (!dragged && !isCanvasDrag(delta)) return;
    if (isMobileRemoteShell() && Math.abs(delta.y) >= Math.abs(delta.x)) {
      const historyLines = touchHistoryScrollLines(event.clientY - lastHistoryClientY, terminalRowHeight(view));
      if (
        historyLines !== 0 &&
        terminalCanScrollHistory({
          baseY: view.term.buffer.active.baseY,
          viewportY: view.term.buffer.active.viewportY,
          deltaY: historyLines,
        })
      ) {
        dragged = true;
        event.preventDefault();
        view.term.scrollLines(historyLines);
        lastHistoryClientY = event.clientY;
        startClient = { x: event.clientX, y: event.clientY };
        startPan = view.canvasPan;
        return;
      }
    }
    dragged = true;
    event.preventDefault();
    const viewport = canvasViewportSize(view);
    const canvas = canvasContentSize(view);
    if (canvas.width <= viewport.width && canvas.height <= viewport.height) return;
    view.canvasPan = panCanvasBy(startPan, delta, viewport, canvas);
    applyCanvasPan(view);
    updateCanvasScrollbar(view);
  };

  const onWheel = (event: WheelEvent): void => {
    const hasRemoteGridDimensions = view.remoteCols !== null && view.remoteRows !== null;
    const mobile = isMobileRemoteShell();
    const useCanvasPan = shouldUseCanvasPan(hasRemoteGridDimensions);
    const canScrollHistory = terminalCanScrollHistory({
      baseY: view.term.buffer.active.baseY,
      viewportY: view.term.buffer.active.viewportY,
      deltaY: event.deltaY,
    });
    if (!shouldConsumeCanvasWheel({ mobile, useCanvasPan, terminalCanScrollHistory: canScrollHistory })) return;

    updateCanvasPan(view);
    const viewport = canvasViewportSize(view);
    const canvas = canvasContentSize(view);
    event.preventDefault();
    event.stopPropagation();
    if (canvas.width <= viewport.width && canvas.height <= viewport.height) return;

    const nextPan = panCanvasByWheel(
      view.canvasPan,
      wheelDelta(event, viewport),
      viewport,
      canvas,
    );
    if (nextPan.x === view.canvasPan.x && nextPan.y === view.canvasPan.y) return;

    view.canvasPan = nextPan;
    applyCanvasPan(view);
    updateCanvasScrollbar(view, viewport, canvas);
  };

  const finishPointer = (event: PointerEvent): void => {
    if (activePointerId !== event.pointerId) return;
    activePointerId = null;
    if (dragged) {
      suppressClick = true;
      suppressClickButton = event.button;
      event.preventDefault();
    }
    try {
      mount.releasePointerCapture(event.pointerId);
    } catch {
      // Pointer capture may already be gone after pointercancel.
    }
  };

  const onClick = (event: MouseEvent): void => {
    if (!suppressClick) return;
    suppressClick = false;
    suppressClickButton = null;
    event.preventDefault();
    event.stopPropagation();
  };

  const onAuxClick = (event: MouseEvent): void => {
    if (!suppressClick || event.button !== suppressClickButton) return;
    suppressClick = false;
    suppressClickButton = null;
    event.preventDefault();
    event.stopPropagation();
  };

  const applyScrollbarPointer = (event: PointerEvent): void => {
    const viewport = canvasViewportSize(view);
    const canvas = canvasContentSize(view);
    const trackRect = scrollbar.getBoundingClientRect();
    const nextThumbTop = event.clientY - trackRect.top - scrollbarGrabOffset;
    view.canvasPan = {
      x: view.canvasPan.x,
      y: panYFromVerticalScrollbarThumb(nextThumbTop, trackRect.height, viewport, canvas),
    };
    applyCanvasPan(view);
    updateCanvasScrollbar(view, viewport, canvas);
  };

  const onScrollbarPointerDown = (event: PointerEvent): void => {
    if (isMobileRemoteShell() || scrollbar.dataset.visible !== "true" || !event.isPrimary) return;
    event.preventDefault();
    event.stopPropagation();
    scrollbarPointerId = event.pointerId;
    const thumbRect = scrollbarThumb.getBoundingClientRect();
    scrollbarGrabOffset =
      event.target === scrollbarThumb
        ? event.clientY - thumbRect.top
        : thumbRect.height / 2;
    applyScrollbarPointer(event);
    try {
      scrollbar.setPointerCapture(event.pointerId);
    } catch {
      // Pointer capture can fail if the browser cancels during layout changes.
    }
  };

  const onScrollbarPointerMove = (event: PointerEvent): void => {
    if (scrollbarPointerId !== event.pointerId) return;
    event.preventDefault();
    event.stopPropagation();
    applyScrollbarPointer(event);
  };

  const finishScrollbarPointer = (event: PointerEvent): void => {
    if (scrollbarPointerId !== event.pointerId) return;
    scrollbarPointerId = null;
    event.preventDefault();
    event.stopPropagation();
    try {
      scrollbar.releasePointerCapture(event.pointerId);
    } catch {
      // Pointer capture may already be gone after pointercancel.
    }
  };

  mount.addEventListener("pointerdown", onPointerDown);
  mount.addEventListener("pointermove", onPointerMove);
  mount.addEventListener("pointerup", finishPointer);
  mount.addEventListener("pointercancel", finishPointer);
  mount.addEventListener("click", onClick, true);
  mount.addEventListener("auxclick", onAuxClick, true);
  mount.addEventListener("wheel", onWheel, CANVAS_WHEEL_EVENT_OPTIONS);
  scrollbar.addEventListener("pointerdown", onScrollbarPointerDown);
  scrollbar.addEventListener("pointermove", onScrollbarPointerMove);
  scrollbar.addEventListener("pointerup", finishScrollbarPointer);
  scrollbar.addEventListener("pointercancel", finishScrollbarPointer);

  return () => {
    mount.removeEventListener("pointerdown", onPointerDown);
    mount.removeEventListener("pointermove", onPointerMove);
    mount.removeEventListener("pointerup", finishPointer);
    mount.removeEventListener("pointercancel", finishPointer);
    mount.removeEventListener("click", onClick, true);
    mount.removeEventListener("auxclick", onAuxClick, true);
    mount.removeEventListener("wheel", onWheel, CANVAS_WHEEL_EVENT_OPTIONS);
    scrollbar.removeEventListener("pointerdown", onScrollbarPointerDown);
    scrollbar.removeEventListener("pointermove", onScrollbarPointerMove);
    scrollbar.removeEventListener("pointerup", finishScrollbarPointer);
    scrollbar.removeEventListener("pointercancel", finishScrollbarPointer);
  };
}

function terminalRowHeight(view: SurfaceView): number {
  const screen = view.host.querySelector<HTMLElement>(".xterm-screen");
  const height = screen?.getBoundingClientRect().height ?? 0;
  return height > 0 && view.term.rows > 0 ? height / view.term.rows : 18;
}

function resetCanvasPan(view: SurfaceView): void {
  view.canvasPan = { x: 0, y: 0 };
  view.lastCanvasViewport = null;
  applyCanvasPan(view);
  hideCanvasScrollbar(view);
}

function updateCanvasPan(view: SurfaceView): void {
  const hasRemoteGridDimensions = view.remoteCols !== null && view.remoteRows !== null;
  if (!shouldUseCanvasPan(hasRemoteGridDimensions)) {
    view.needsDefaultCanvasPan = false;
    resetCanvasPan(view);
    return;
  }
  const viewport = canvasViewportSize(view);
  const canvas = canvasContentSize(view);
  if (viewport.width <= 0 || viewport.height <= 0 || canvas.width <= 0 || canvas.height <= 0) return;
  const bottomGutter = isMobileRemoteShell() ? MOBILE_CANVAS_BOTTOM_GUTTER : 0;
  if (view.needsDefaultCanvasPan) {
    view.canvasPan = defaultCanvasPan(viewport, canvas, { bottomGutter });
    view.needsDefaultCanvasPan = false;
  } else {
    view.canvasPan = resizeCanvasPan({
      pan: view.canvasPan,
      previousViewport: view.lastCanvasViewport,
      viewport,
      canvas,
      bottomGutter,
    });
  }
  view.lastCanvasViewport = viewport;
  applyCanvasPan(view);
  updateCanvasScrollbar(view, viewport, canvas, bottomGutter);
}

function applyCanvasPan(view: SurfaceView): void {
  const mode = isMobileRemoteShell() ? "transform" : "scroll";
  const renderState = canvasPanRenderState(view.canvasPan, mode);
  view.host.style.transform = renderState.transform;
  view.host.scrollLeft = renderState.scrollLeft;
  view.host.scrollTop = renderState.scrollTop;
  if (mode === "scroll") {
    view.canvasPan = {
      x: -view.host.scrollLeft,
      y: -view.host.scrollTop,
    };
  }
}

function updateCanvasScrollbar(
  view: SurfaceView,
  viewport: CanvasSize = canvasViewportSize(view),
  canvas: CanvasSize = canvasContentSize(view),
  bottomGutter: number = isMobileRemoteShell() ? MOBILE_CANVAS_BOTTOM_GUTTER : 0,
): void {
  const hasRemoteGridDimensions = view.remoteCols !== null && view.remoteRows !== null;
  if (isMobileRemoteShell() || !shouldUseCanvasPan(hasRemoteGridDimensions)) {
    hideCanvasScrollbar(view);
    return;
  }

  const trackHeight =
    view.scrollbar.clientHeight ||
    Math.max(0, view.mount.clientHeight - DESKTOP_SCROLLBAR_VERTICAL_INSET * 2);
  const metrics = verticalScrollbarMetrics(view.canvasPan, viewport, canvas, trackHeight, {
    bottomGutter,
    minThumbHeight: DESKTOP_SCROLLBAR_MIN_THUMB_HEIGHT,
  });
  if (!metrics.visible) {
    hideCanvasScrollbar(view);
    return;
  }

  view.scrollbar.dataset.visible = "true";
  view.scrollbar.setAttribute("aria-hidden", "false");
  view.scrollbarThumb.style.height = `${metrics.thumbHeight}px`;
  view.scrollbarThumb.style.transform = `translateY(${metrics.thumbTop}px)`;
}

function hideCanvasScrollbar(view: SurfaceView): void {
  view.scrollbar.dataset.visible = "false";
  view.scrollbar.setAttribute("aria-hidden", "true");
  view.scrollbarThumb.style.height = "";
  view.scrollbarThumb.style.transform = "";
}

function canvasViewportSize(view: SurfaceView): CanvasSize {
  return {
    width: view.host.clientWidth,
    height: view.host.clientHeight,
  };
}

function canvasContentSize(view: SurfaceView): CanvasSize {
  const screen = view.host.querySelector<HTMLElement>(".xterm-screen");
  const xterm = view.host.querySelector<HTMLElement>(".xterm");
  const terminalHeight = terminalCanvasHeight(view, screen);
  const rawSize = {
    width: Math.max(
      view.host.clientWidth,
      view.host.offsetWidth,
      view.host.scrollWidth,
      xterm?.offsetWidth ?? 0,
      xterm?.scrollWidth ?? 0,
      screen?.offsetWidth ?? 0,
      screen?.scrollWidth ?? 0,
    ),
    height: terminalHeight,
  };
  return scaleVisualCanvasSize(rawSize, isMobileRemoteShell() ? state.mobileVisualZoom : 1);
}

function terminalCanvasHeight(view: SurfaceView, screen: HTMLElement | null): number {
  const measuredHeight = Math.max(
    screen?.offsetHeight ?? 0,
    screen?.scrollHeight ?? 0,
  );
  if (measuredHeight <= 0) {
    const xterm = view.host.querySelector<HTMLElement>(".xterm");
    return Math.max(
      view.host.offsetHeight,
      view.host.scrollHeight,
      xterm?.offsetHeight ?? 0,
      xterm?.scrollHeight ?? 0,
    );
  }

  const buffer = view.term.buffer.active;
  return meaningfulTerminalCanvasHeight({
    measuredHeight,
    rows: view.term.rows,
    cursorY: buffer.cursorY,
    lastNonBlankRow: lastNonBlankTerminalRow(view),
  });
}

function lastNonBlankTerminalRow(view: SurfaceView): number {
  const buffer = view.term.buffer.active;
  const rows = Math.max(0, view.term.rows);
  for (let row = rows - 1; row >= 0; row -= 1) {
    const line = buffer.getLine(buffer.baseY + row);
    if (line && line.translateToString(true).trim().length > 0) return row;
  }
  return Math.max(0, Math.min(rows - 1, buffer.cursorY));
}

function wheelDelta(event: WheelEvent, viewport: CanvasSize): CanvasPoint {
  const scale =
    event.deltaMode === WheelEvent.DOM_DELTA_LINE
      ? 24
      : event.deltaMode === WheelEvent.DOM_DELTA_PAGE
        ? viewport.height
        : 1;
  return { x: event.deltaX * scale, y: event.deltaY * scale };
}

function bindTwoFingerMiddleClick(view: SurfaceView): () => void {
  const host = view.host;
  const MOVE_THRESHOLD = 14;
  const TIME_THRESHOLD = 700;
  let active = false;
  let startTime = 0;
  let centroid: { x: number; y: number } | null = null;

  const onTouchStart = (event: TouchEvent): void => {
    if (event.touches.length === 2) {
      active = true;
      startTime = Date.now();
      const a = event.touches[0];
      const b = event.touches[1];
      centroid = { x: (a.clientX + b.clientX) / 2, y: (a.clientY + b.clientY) / 2 };
    } else if (event.touches.length > 2) {
      active = false;
      centroid = null;
    }
  };

  const onTouchMove = (event: TouchEvent): void => {
    if (!active || !centroid) return;
    if (event.touches.length !== 2) {
      active = false;
      return;
    }
    const a = event.touches[0];
    const b = event.touches[1];
    const cx = (a.clientX + b.clientX) / 2;
    const cy = (a.clientY + b.clientY) / 2;
    if (Math.hypot(cx - centroid.x, cy - centroid.y) > MOVE_THRESHOLD) {
      active = false;
    }
  };

  const onTouchEnd = (event: TouchEvent): void => {
    if (!active || !centroid) {
      if (event.touches.length === 0) {
        active = false;
        centroid = null;
      }
      return;
    }
    if (event.touches.length >= 2) return;
    const within = Date.now() - startTime <= TIME_THRESHOLD;
    const point = centroid;
    active = false;
    centroid = null;
    if (!within) return;
    event.preventDefault();
    dispatchMiddleClick(host, point.x, point.y);
  };

  const onTouchCancel = (): void => {
    active = false;
    centroid = null;
  };

  host.addEventListener("touchstart", onTouchStart, { passive: true });
  host.addEventListener("touchmove", onTouchMove, { passive: true });
  host.addEventListener("touchend", onTouchEnd, { passive: false });
  host.addEventListener("touchcancel", onTouchCancel, { passive: true });

  return () => {
    host.removeEventListener("touchstart", onTouchStart);
    host.removeEventListener("touchmove", onTouchMove);
    host.removeEventListener("touchend", onTouchEnd);
    host.removeEventListener("touchcancel", onTouchCancel);
  };
}

function dispatchMiddleClick(host: HTMLElement, clientX: number, clientY: number): void {
  const target =
    host.querySelector<HTMLElement>(".xterm-screen") ??
    host.querySelector<HTMLElement>(".xterm") ??
    host;
  const baseInit: MouseEventInit = {
    bubbles: true,
    cancelable: true,
    composed: true,
    view: window,
    clientX,
    clientY,
    screenX: clientX,
    screenY: clientY,
    button: 1,
  };
  target.dispatchEvent(new MouseEvent("mousedown", { ...baseInit, buttons: 4 }));
  target.dispatchEvent(new MouseEvent("mouseup", { ...baseInit, buttons: 0 }));
  target.dispatchEvent(new MouseEvent("auxclick", { ...baseInit, buttons: 0, detail: 1 }));
}
