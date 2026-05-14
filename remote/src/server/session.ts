import type { WebSocket } from "ws";

export type RelayMessage = {
  type?: string;
  data?: string;
  encoding?: string;
  surfaceId?: string;
  message?: string;
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

const HEARTBEAT_INTERVAL_MS = 25_000;

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

  constructor(key: string) {
    this.key = key;
  }

  isPhanttyConnected(): boolean {
    return this.phantty !== null;
  }

  applyLayout(message: RelayMessage): void {
    this.lastLayout = message;
  }

  findAiChatSurface(): RemoteSurfaceRef | null {
    for (const surface of this.layoutSurfaces()) {
      if (surface.kind === "ai_chat") return { id: surface.id, title: surface.title ?? surface.id };
    }
    return null;
  }

  findDefaultWritableSurface(): RemoteSurfaceRef | null {
    const focused = this.layoutSurfaces().find(
      (surface) => surface.focused && surface.kind !== "ai_chat" && surface.readOnly !== true,
    );
    if (focused) return { id: focused.id, title: focused.title ?? focused.id };
    const first = this.layoutSurfaces().find(
      (surface) => surface.kind !== "ai_chat" && surface.readOnly !== true,
    );
    return first ? { id: first.id, title: first.title ?? first.id } : null;
  }

  latestAiChatTranscript(): string {
    for (const surface of this.layoutSurfaces()) {
      if (surface.kind === "ai_chat") return surface.snapshot ?? "";
    }
    return "";
  }

  sendInput(surfaceId: string, text: string): boolean {
    if (!this.phantty) return false;
    safeSend(this.phantty, {
      type: "input-bytes",
      surfaceId,
      encoding: "hex",
      data: Buffer.from(text, "utf8").toString("hex"),
    });
    return true;
  }

  sendNotice(message: string): void {
    this.broadcast({ type: "notice", message });
  }

  private layoutSurfaces(): NonNullable<NonNullable<RelayMessage["tabs"]>[number]["surfaces"]> {
    return this.lastLayout?.tabs?.flatMap((tab) => tab.surfaces ?? []) ?? [];
  }

  attachPhantty(socket: WebSocket): void {
    try {
      this.phantty?.close(1012, "replaced by a new Phantty connection");
    } catch {
      // ignore
    }
    this.phantty = socket;
    trackHeartbeat(socket);
    this.broadcast({ type: "notice", message: "Phantty connected" });

    socket.on("message", (raw) => {
      const message = safeJson(raw.toString());
      if (!message) return;
      if (message.type === "ping") {
        safeSend(socket, { type: "pong" });
        return;
      }
      if (message.type === "pong") return;
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
      this.phantty = null;
      this.broadcast({ type: "notice", message: "Phantty disconnected" });
    });
  }

  attachBrowser(socket: WebSocket): void {
    this.browsers.add(socket);
    trackHeartbeat(socket);
    safeSend(socket, { type: "notice", message: "Browser paired; input enabled" });
    if (this.phantty) safeSend(socket, { type: "notice", message: "Phantty connected" });
    if (this.lastLayout) safeSend(socket, this.lastLayout);

    socket.on("message", (raw) => {
      const message = safeJson(raw.toString());
      if (!message) return;
      if (message.type === "ping") {
        safeSend(socket, { type: "pong" });
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
}

export function safeSend(socket: WebSocket, message: unknown): void {
  try {
    socket.send(JSON.stringify(message));
  } catch {
    // ignore
  }
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
