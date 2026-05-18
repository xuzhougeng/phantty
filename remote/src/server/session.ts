import type { WebSocket } from "ws";

export type RelayMessage = {
  type?: string;
  at?: number;
  data?: string;
  encoding?: string;
  surfaceId?: string;
  message?: string;
  requestId?: string;
  status?: string;
  phanttyConnected?: boolean;
  activeTab?: number;
  tabs?: Array<{
    index: number;
    focusedSurfaceId?: string;
    surfaces: Array<{
      id: string;
      title?: string;
      focused?: boolean;
      kind?: "terminal" | "ai_chat";
      readOnly?: boolean;
      snapshot?: string;
    }>;
  }>;
};

export type RemoteSurfaceRef = { id: string; title: string };
export type AiAgentOpenStatus = "opened" | "no-profile" | "failed";
export type AiAgentOpenResult = AiAgentOpenStatus | "offline" | "timeout";
type LayoutTab = NonNullable<RelayMessage["tabs"]>[number];
type LayoutSurface = LayoutTab["surfaces"][number];

const HEARTBEAT_INTERVAL_MS = 25_000;
const SOCKET_OPEN = 1;
const AI_AGENT_OPEN_STATUSES = new Set<AiAgentOpenStatus>(["opened", "no-profile", "failed"]);

const sessions = new Map<string, RemoteSession>();
const heartbeatState = new WeakMap<WebSocket, { alive: boolean }>();
const heartbeatSockets = new Set<WebSocket>();

export function getSession(key: string): RemoteSession {
  let session = sessions.get(key);
  if (!session) {
    session = new RemoteSession(key);
    sessions.set(key, session);
  }
  return session;
}

export function listSessions(): Array<{ key: string; connected: boolean }> {
  return [...sessions.entries()].map(([key, session]) => ({
    key,
    connected: session.isPhanttyConnected(),
  }));
}

export class RemoteSession {
  readonly key: string;
  phantty: WebSocket | null = null;
  browsers = new Set<WebSocket>();
  lastLayout: RelayMessage | null = null;
  private layoutListeners = new Set<() => void>();
  private pendingAiAgentOpenRequests = new Map<string, (status: AiAgentOpenResult) => void>();

  constructor(key: string) {
    this.key = key;
  }

  isPhanttyConnected(): boolean {
    return isSocketOpen(this.phantty);
  }

  applyLayout(message: RelayMessage): void {
    this.lastLayout = message;
    for (const listener of [...this.layoutListeners]) {
      try {
        listener();
      } catch {
        // Layout listeners are auxiliary observers; a failure must not break relay updates.
      }
    }
  }

  onLayout(listener: () => void): () => void {
    this.layoutListeners.add(listener);
    return () => {
      this.layoutListeners.delete(listener);
    };
  }

  findAiChatSurface(): RemoteSurfaceRef | null {
    for (const surface of this.layoutSurfaces()) {
      if (surface.kind === "ai_chat") return { id: surface.id, title: surface.title ?? surface.id };
    }
    return null;
  }

  findDefaultWritableSurface(): RemoteSurfaceRef | null {
    const activeTab = this.activeTab();
    const activeSurfaces = activeTab?.surfaces ?? [];
    const byFocusedSurfaceId = activeSurfaces.find(
      (surface) => surface.id === activeTab?.focusedSurfaceId && isWritableTerminalSurface(surface),
    );
    if (byFocusedSurfaceId) {
      return { id: byFocusedSurfaceId.id, title: byFocusedSurfaceId.title ?? byFocusedSurfaceId.id };
    }

    const focused = activeSurfaces.find(
      (surface) => surface.focused && isWritableTerminalSurface(surface),
    );
    if (focused) return { id: focused.id, title: focused.title ?? focused.id };

    const firstActive = activeSurfaces.find(isWritableTerminalSurface);
    if (firstActive) return { id: firstActive.id, title: firstActive.title ?? firstActive.id };

    const first = this.layoutSurfaces().find(isWritableTerminalSurface);
    return first ? { id: first.id, title: first.title ?? first.id } : null;
  }

  latestAiChatTranscript(): string {
    for (const surface of this.layoutSurfaces()) {
      if (surface.kind === "ai_chat") return surface.snapshot ?? "";
    }
    return "";
  }

  sendInput(surfaceId: string, text: string): boolean {
    if (!isSocketOpen(this.phantty)) return false;
    return safeSend(this.phantty, {
      type: "input-bytes",
      surfaceId,
      encoding: "hex",
      data: Buffer.from(text, "utf8").toString("hex"),
    });
  }

  async requestAiAgentOpen(requestId: string, timeoutMs = 2000): Promise<AiAgentOpenResult> {
    if (!isSocketOpen(this.phantty)) return "offline";

    const wait = this.registerAiAgentOpenWait(requestId, timeoutMs);
    if (!safeSend(this.phantty, { type: "open-ai-agent", requestId })) {
      wait.cancel();
      return "offline";
    }

    return await wait.promise;
  }

  sendNotice(message: string): void {
    this.broadcast({ type: "notice", message });
  }

  private layoutSurfaces(): NonNullable<NonNullable<RelayMessage["tabs"]>[number]["surfaces"]> {
    return this.lastLayout?.tabs?.flatMap((tab) => tab.surfaces ?? []) ?? [];
  }

  private activeTab(): LayoutTab | null {
    const tabs = this.lastLayout?.tabs ?? [];
    if (tabs.length === 0) return null;
    return tabs.find((tab) => tab.index === this.lastLayout?.activeTab) ?? tabs[0] ?? null;
  }

  private registerAiAgentOpenWait(
    requestId: string,
    timeoutMs: number,
  ): { promise: Promise<AiAgentOpenResult>; cancel: () => void } {
    let settled = false;
    let timer: ReturnType<typeof setTimeout> | null = null;
    let resolvePromise: (status: AiAgentOpenResult) => void = () => {};

    const settle = (status: AiAgentOpenResult): void => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      this.pendingAiAgentOpenRequests.delete(requestId);
      resolvePromise(status);
    };

    const promise = new Promise<AiAgentOpenResult>((resolve) => {
      resolvePromise = resolve;
    });

    this.pendingAiAgentOpenRequests.set(requestId, (status) => settle(status));
    timer = setTimeout(() => settle("timeout"), Math.max(0, timeoutMs));

    return {
      promise,
      cancel: () => settle("timeout"),
    };
  }

  private handleAiAgentOpenResult(message: RelayMessage): void {
    if (typeof message.requestId !== "string" || !isAiAgentOpenStatus(message.status)) return;
    const settle = this.pendingAiAgentOpenRequests.get(message.requestId);
    settle?.(message.status);
  }

  private resolvePendingAiAgentOpenRequests(status: AiAgentOpenResult): void {
    for (const settle of [...this.pendingAiAgentOpenRequests.values()]) {
      settle(status);
    }
  }

  attachPhantty(socket: WebSocket): void {
    if (this.phantty) this.resolvePendingAiAgentOpenRequests("offline");
    try {
      this.phantty?.close(1012, "replaced by a new Phantty connection");
    } catch {
      // ignore
    }
    this.phantty = socket;
    trackHeartbeat(socket);
    this.broadcast({ type: "notice", message: "Phantty connected" });
    this.broadcastPeerStatus();

    socket.on("error", (err) => {
      if (this.phantty !== socket) return;
      console.warn(`[remote] Phantty websocket error: ${socketErrorMessage(err)}`);
      this.resolvePendingAiAgentOpenRequests("offline");
      this.phantty = null;
      this.broadcast({ type: "notice", message: "Phantty disconnected" });
      this.broadcastPeerStatus();
      terminateSocket(socket);
    });

    socket.on("message", (raw) => {
      const message = safeJson(raw.toString());
      if (!message) return;
      if (message.type === "ping") {
        safeSend(socket, pongMessage(message));
        return;
      }
      if (message.type === "pong") return;
      if (message.type === "open-ai-agent-result") {
        this.handleAiAgentOpenResult(message);
        return;
      }
      if (message.type === "output" && typeof message.data === "string") {
        this.broadcast({ type: "output", data: message.data });
      } else if (message.type === "output-bytes" && typeof message.data === "string") {
        this.broadcast({
          type: "output-bytes",
          surfaceId: message.surfaceId,
          encoding: message.encoding,
          data: message.data,
        });
      } else if (message.type === "layout") {
        this.applyLayout(message);
        this.broadcast(message);
      }
    });

    socket.on("close", () => {
      if (this.phantty !== socket) return;
      this.resolvePendingAiAgentOpenRequests("offline");
      this.phantty = null;
      this.broadcast({ type: "notice", message: "Phantty disconnected" });
      this.broadcastPeerStatus();
    });
  }

  attachBrowser(socket: WebSocket): void {
    this.browsers.add(socket);
    trackHeartbeat(socket);
    safeSend(socket, { type: "notice", message: "Browser paired; input enabled" });
    this.sendPeerStatus(socket);
    if (this.isPhanttyConnected()) safeSend(socket, { type: "notice", message: "Phantty connected" });
    if (this.lastLayout) safeSend(socket, this.lastLayout);

    socket.on("error", (err) => {
      console.warn(`[remote] browser websocket error: ${socketErrorMessage(err)}`);
      this.browsers.delete(socket);
      terminateSocket(socket);
    });

    socket.on("message", (raw) => {
      const message = safeJson(raw.toString());
      if (!message) return;
      if (message.type === "ping") {
        safeSend(socket, pongMessage(message));
        return;
      }
      if (message.type === "pong") return;
      if (
        message.type === "input-bytes" &&
        typeof message.surfaceId === "string" &&
        typeof message.data === "string"
      ) {
        if (this.phantty) {
          safeSend(this.phantty, {
            type: "input-bytes",
            surfaceId: message.surfaceId,
            encoding: message.encoding,
            data: message.data,
          });
        }
      }
    });

    socket.on("close", () => {
      this.browsers.delete(socket);
    });
  }

  broadcast(message: RelayMessage): void {
    const payload = JSON.stringify(message);
    for (const browser of this.browsers) {
      try {
        browser.send(payload);
      } catch {
        this.browsers.delete(browser);
      }
    }
  }

  private sendPeerStatus(socket: WebSocket): void {
    safeSend(socket, { type: "peer-status", phanttyConnected: this.isPhanttyConnected() });
  }

  private broadcastPeerStatus(): void {
    this.broadcast({ type: "peer-status", phanttyConnected: this.isPhanttyConnected() });
  }
}

export function safeSend(socket: WebSocket, message: unknown): boolean {
  if (!isSocketOpen(socket)) return false;
  try {
    socket.send(JSON.stringify(message));
    return true;
  } catch {
    return false;
  }
}

function isSocketOpen(socket: WebSocket | null): socket is WebSocket {
  return socket?.readyState === SOCKET_OPEN;
}

function terminateSocket(socket: WebSocket): void {
  try {
    socket.terminate();
  } catch {
    try {
      socket.close();
    } catch {
      // ignore
    }
  }
}

function socketErrorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

function pongMessage(message: RelayMessage): RelayMessage {
  return typeof message.at === "number" ? { type: "pong", at: message.at } : { type: "pong" };
}

function isWritableTerminalSurface(surface: LayoutSurface): boolean {
  return surface.kind !== "ai_chat" && surface.readOnly !== true;
}

function isAiAgentOpenStatus(value: unknown): value is AiAgentOpenStatus {
  return typeof value === "string" && AI_AGENT_OPEN_STATUSES.has(value as AiAgentOpenStatus);
}

export function safeJson(data: string): RelayMessage | null {
  try {
    return JSON.parse(data) as RelayMessage;
  } catch {
    return null;
  }
}

export function trackHeartbeat(socket: WebSocket): void {
  heartbeatState.set(socket, { alive: true });
  heartbeatSockets.add(socket);
  socket.on("pong", () => {
    const state = heartbeatState.get(socket);
    if (state) state.alive = true;
  });
  socket.on("close", () => {
    heartbeatState.delete(socket);
    heartbeatSockets.delete(socket);
  });
}

const heartbeatTimer = setInterval(() => {
  for (const ws of heartbeatSockets) {
    const state = heartbeatState.get(ws);
    if (!state) continue;
    if (!state.alive) {
      try {
        ws.terminate();
      } catch {
        // ignore
      }
      continue;
    }
    state.alive = false;
    try {
      ws.ping();
    } catch {
      // ignore
    }
  }
}, HEARTBEAT_INTERVAL_MS);
heartbeatTimer.unref?.();
