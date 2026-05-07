import { DurableObject } from "cloudflare:workers";

type Env = {
  ASSETS: Fetcher;
  REMOTE_SESSION: DurableObjectNamespace<RemoteSession>;
  ADMIN_USERNAME: string;
  ADMIN_PASSWORD_HASH: string;
  SESSION_SIGNING_SECRET: string;
};

type LoginBody = {
  username?: string;
  password?: string;
};

type RelayMessage = {
  type?: string;
  data?: string;
  encoding?: string;
  surfaceId?: string;
  message?: string;
};

const COOKIE_NAME = "phantty_remote";
const SESSION_TTL_SECONDS = 8 * 60 * 60;

export class RemoteSession extends DurableObject<Env> {
  private phantty: WebSocket | null = null;
  private browsers = new Set<WebSocket>();
  private lastLayout: RelayMessage | null = null;
  private controlEnabled = false;
  private controlPending = false;

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.headers.get("upgrade") !== "websocket") {
      return json({ error: "websocket required" }, 426);
    }

    const role = url.searchParams.get("role");
    if (role !== "browser" && role !== "phantty") {
      return json({ error: "invalid role" }, 400);
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair) as [WebSocket, WebSocket];
    server.accept();

    if (role === "phantty") {
      this.attachPhantty(server);
    } else {
      this.attachBrowser(server);
    }

    return new Response(null, { status: 101, webSocket: client });
  }

  private attachPhantty(socket: WebSocket): void {
    this.phantty?.close(1012, "replaced by a new Phantty connection");
    this.phantty = socket;
    this.controlEnabled = false;
    this.controlPending = false;
    this.broadcast({ type: "notice", message: "Phantty connected" });
    this.broadcast({ type: "control-revoked" });

    socket.addEventListener("message", (event) => {
      if (typeof event.data !== "string") return;
      const message = safeJson(event.data);
      if (!message) return;

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
        this.lastLayout = message;
        this.broadcast(message);
      } else if (message.type === "control-requested") {
        this.controlPending = true;
        this.broadcast({ type: "control-requested" });
      } else if (message.type === "control-granted") {
        this.controlPending = false;
        this.controlEnabled = true;
        this.broadcast({ type: "control-granted" });
      } else if (message.type === "control-revoked") {
        this.controlPending = false;
        this.controlEnabled = false;
        this.broadcast({ type: "control-revoked" });
      }
    });

    socket.addEventListener("close", () => {
      if (this.phantty !== socket) return;
      this.phantty = null;
      this.controlEnabled = false;
      this.controlPending = false;
      this.broadcast({ type: "control-revoked" });
      this.broadcast({ type: "notice", message: "Phantty disconnected" });
    });
  }

  private attachBrowser(socket: WebSocket): void {
    this.browsers.add(socket);
    socket.send(JSON.stringify({ type: "notice", message: "Browser paired" }));
    if (this.phantty) socket.send(JSON.stringify({ type: "notice", message: "Phantty connected" }));
    if (this.lastLayout) socket.send(JSON.stringify(this.lastLayout));
    socket.send(
      JSON.stringify({
        type: this.controlEnabled ? "control-granted" : this.controlPending ? "control-requested" : "control-revoked",
      }),
    );

    socket.addEventListener("message", (event) => {
      if (typeof event.data !== "string") return;
      const message = safeJson(event.data);
      if (!message) return;

      if (message.type === "request-control") {
        this.requestControl(socket);
      } else if (
        message.type === "input-bytes" &&
        typeof message.surfaceId === "string" &&
        typeof message.data === "string"
      ) {
        if (!this.controlEnabled) {
          socket.send(JSON.stringify({ type: "input-denied", message: "Remote input is waiting for local approval" }));
          return;
        }
        this.phantty?.send(
          JSON.stringify({
            type: "input-bytes",
            surfaceId: message.surfaceId,
            encoding: message.encoding,
            data: message.data,
          }),
        );
      }
    });

    socket.addEventListener("close", () => {
      this.browsers.delete(socket);
      if (this.browsers.size === 0 && (this.controlEnabled || this.controlPending)) {
        this.controlEnabled = false;
        this.controlPending = false;
        this.phantty?.send(JSON.stringify({ type: "control-revoked" }));
      }
    });
  }

  private requestControl(socket: WebSocket): void {
    if (!this.phantty) {
      socket.send(JSON.stringify({ type: "notice", message: "Phantty is not connected yet" }));
      return;
    }
    if (this.controlEnabled) {
      socket.send(JSON.stringify({ type: "control-granted" }));
      return;
    }

    this.controlPending = true;
    this.broadcast({ type: "control-requested" });
    this.phantty.send(JSON.stringify({ type: "request-control" }));
  }

  private broadcast(message: RelayMessage): void {
    const data = JSON.stringify(message);
    for (const browser of this.browsers) {
      try {
        browser.send(data);
      } catch {
        this.browsers.delete(browser);
      }
    }
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/api/login" && request.method === "POST") {
      return login(request, env);
    }
    if (url.pathname === "/api/logout" && request.method === "POST") {
      return logout();
    }
    if (url.pathname === "/api/me" && request.method === "GET") {
      const session = await readSession(request, env);
      return json(session ? { authenticated: true, username: session.username } : { authenticated: false });
    }
    if (url.pathname === "/ws/browser") {
      const session = await readSession(request, env);
      if (!session) return json({ error: "login required" }, 401);
      return routeWebSocket(request, env, "browser");
    }
    if (url.pathname === "/ws/phantty") {
      // Phase 1 scaffold: the future Phantty client must add device
      // challenge/response before this route is trusted for production.
      return routeWebSocket(request, env, "phantty");
    }

    return env.ASSETS.fetch(request);
  },
};

async function login(request: Request, env: Env): Promise<Response> {
  const body = (await request.json().catch(() => null)) as LoginBody | null;
  const username = (body?.username ?? "").trim();
  const password = body?.password ?? "";

  if (username !== env.ADMIN_USERNAME.trim()) {
    return json({ error: "invalid credentials" }, 401);
  }

  const ok = await verifyPassword(password, env.ADMIN_PASSWORD_HASH);
  if (!ok) return json({ error: "invalid credentials" }, 401);

  const now = Math.floor(Date.now() / 1000);
  const token = await signSession(env, {
    username,
    exp: now + SESSION_TTL_SECONDS,
  });

  return json(
    { authenticated: true, username },
    200,
    {
      "set-cookie": `${COOKIE_NAME}=${token}; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=${SESSION_TTL_SECONDS}`,
    },
  );
}

function logout(): Response {
  return json(
    { authenticated: false },
    200,
    {
      "set-cookie": `${COOKIE_NAME}=; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=0`,
    },
  );
}

async function routeWebSocket(request: Request, env: Env, role: "browser" | "phantty"): Promise<Response> {
  if (request.headers.get("upgrade") !== "websocket") {
    return json({ error: "websocket required" }, 426);
  }

  const url = new URL(request.url);
  const sessionKey = url.searchParams.get("session")?.trim();
  if (!sessionKey) return json({ error: "session key required" }, 400);

  const id = env.REMOTE_SESSION.idFromName(sessionKey);
  const stub = env.REMOTE_SESSION.get(id);
  const target = new URL(request.url);
  target.searchParams.set("role", role);
  return stub.fetch(new Request(target, request));
}

async function verifyPassword(password: string, expectedHash: string): Promise<boolean> {
  const [scheme, hash] = expectedHash.trim().split(":", 2);
  if (scheme.toLowerCase() !== "sha256" || !hash) return false;
  const actual = await sha256Hex(password);
  return timingSafeEqual(actual, hash.trim().toLowerCase());
}

type SessionPayload = {
  username: string;
  exp: number;
};

async function readSession(request: Request, env: Env): Promise<SessionPayload | null> {
  const cookie = request.headers.get("cookie") ?? "";
  const token = cookie
    .split(";")
    .map((part) => part.trim())
    .find((part) => part.startsWith(`${COOKIE_NAME}=`))
    ?.slice(COOKIE_NAME.length + 1);

  if (!token) return null;

  const [payloadPart, sigPart] = token.split(".", 2);
  if (!payloadPart || !sigPart) return null;

  const expected = await hmacHex(env.SESSION_SIGNING_SECRET, payloadPart);
  if (!timingSafeEqual(expected, sigPart)) return null;

  const payload = JSON.parse(decodeBase64Url(payloadPart)) as SessionPayload;
  if (!payload.username || payload.exp < Math.floor(Date.now() / 1000)) return null;
  return payload;
}

async function signSession(env: Env, payload: SessionPayload): Promise<string> {
  const payloadPart = encodeBase64Url(JSON.stringify(payload));
  const sig = await hmacHex(env.SESSION_SIGNING_SECRET, payloadPart);
  return `${payloadPart}.${sig}`;
}

async function sha256Hex(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return hex(new Uint8Array(digest));
}

async function hmacHex(secret: string, value: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(value));
  return hex(new Uint8Array(sig));
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i += 1) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

function hex(bytes: Uint8Array): string {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function encodeBase64Url(value: string): string {
  const bytes = new TextEncoder().encode(value);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function decodeBase64Url(value: string): string {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return new TextDecoder().decode(bytes);
}

function safeJson(data: string): RelayMessage | null {
  try {
    return JSON.parse(data) as RelayMessage;
  } catch {
    return null;
  }
}

function json(body: unknown, status = 200, headers: HeadersInit = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      ...headers,
    },
  });
}
