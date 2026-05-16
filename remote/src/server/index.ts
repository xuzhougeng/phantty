/// <reference types="node" />

import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import type { Socket } from "node:net";
import { readFile, stat } from "node:fs/promises";
import { extname, join, normalize, resolve } from "node:path";

import { WeixinBindingStore } from "./bridge/weixin/binding.js";
import { WeixinClient } from "./bridge/weixin/client.js";
import { WeixinPoller } from "./bridge/weixin/poller.js";
import { handleWeixinRoute } from "./bridge/weixin/routes.js";
import { getSession, listSessions } from "./session.js";
import { createRelayWebSocketServer } from "./websocket.js";

type SessionPayload = {
  username: string;
  exp: number;
};

type LoginBody = {
  username?: string;
  password?: string;
};

const COOKIE_NAME = "phantty_remote";
const SESSION_TTL_SECONDS = 24 * 60 * 60;

const PORT = Number(process.env.PORT ?? 8787);
const HOST = process.env.HOST ?? "0.0.0.0";
const DIST_DIR = resolve(process.env.DIST_DIR ?? "./dist");
const DATA_DIR = resolve(process.env.REMOTE_DATA_DIR ?? "./data");
const ADMIN_USERNAME = requireEnv("ADMIN_USERNAME").trim();
const ADMIN_PASSWORD_HASH = requireEnv("ADMIN_PASSWORD_HASH");
const SESSION_SIGNING_SECRET = requireEnv("SESSION_SIGNING_SECRET");
const COOKIE_SECURE = (process.env.REMOTE_COOKIE_SECURE ?? "true").toLowerCase() !== "false";

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    console.error(`[remote] missing required env var ${name}`);
    process.exit(1);
  }
  return value;
}

const wss = createRelayWebSocketServer();
const weixinStore = new WeixinBindingStore(DATA_DIR);
const weixinPoller = new WeixinPoller(
  weixinStore,
  () => listSessions().filter(({ connected }) => connected).map(({ key }) => ({ key, session: getSession(key) })),
);

weixinPoller.start();

const server = createServer((req, res) => {
  void routeHttp(req, res).catch((err) => {
    console.error("[remote] http error:", err);
    if (!res.headersSent) {
      res.statusCode = 500;
      res.end("internal error");
    }
  });
});

server.on("upgrade", (req, socket, head) => {
  void handleUpgrade(req, socket as Socket, head as Buffer).catch((err) => {
    console.error("[remote] upgrade error:", err);
    rejectUpgrade(socket as Socket, 500, "internal error");
  });
});

server.listen(PORT, HOST, () => {
  console.log(`[remote] listening on http://${HOST}:${PORT}`);
});

async function handleUpgrade(req: IncomingMessage, socket: Socket, head: Buffer): Promise<void> {
  const url = new URL(req.url ?? "/", "http://localhost");
  if (url.pathname !== "/ws/browser" && url.pathname !== "/ws/phantty") {
    return rejectUpgrade(socket, 404, "not found");
  }

  const sessionKey = url.searchParams.get("session")?.trim();
  if (!sessionKey) return rejectUpgrade(socket, 400, "session key required");

  if (url.pathname === "/ws/browser") {
    const session = await readSession(req);
    if (!session) return rejectUpgrade(socket, 401, "login required");
  }

  wss.handleUpgrade(req, socket, head, (ws) => {
    const remote = getSession(sessionKey);
    if (url.pathname === "/ws/phantty") remote.attachPhantty(ws);
    else remote.attachBrowser(ws);
  });
}

function rejectUpgrade(socket: Socket, status: number, message: string): void {
  const statusText = `${status} ${message}`;
  const body = message;
  socket.write(
    `HTTP/1.1 ${statusText}\r\n` +
      `Content-Type: text/plain; charset=utf-8\r\n` +
      `Content-Length: ${Buffer.byteLength(body)}\r\n` +
      `Connection: close\r\n\r\n${body}`,
  );
  socket.destroy();
}

async function routeHttp(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const url = new URL(req.url ?? "/", "http://localhost");
  const method = (req.method ?? "GET").toUpperCase();

  if (url.pathname === "/api/login" && method === "POST") return login(req, res);
  if (url.pathname === "/api/logout" && method === "POST") return logout(res);
  if (url.pathname === "/api/me" && method === "GET") {
    const session = await readSession(req);
    return sendJson(
      res,
      session ? { authenticated: true, username: session.username } : { authenticated: false },
    );
  }

  if (url.pathname.startsWith("/api/weixin/")) {
    const session = await readSession(req);
    if (!session) return sendJson(res, { error: "login required" }, 401);
    const handled = await handleWeixinRoute(req, res, {
      store: weixinStore,
      createClient: (token, baseUrl) => new WeixinClient({ token, baseUrl }),
      listSessions,
      restartPoller: () => {
        weixinPoller.stop();
        weixinPoller.start();
      },
    });
    if (handled) return;
  }

  await serveStatic(res, url.pathname);
}

async function login(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const body = await readJson<LoginBody>(req);
  const username = (body?.username ?? "").trim();
  const password = body?.password ?? "";

  if (username !== ADMIN_USERNAME) {
    return sendJson(res, { error: "invalid credentials" }, 401);
  }
  const ok = await verifyPassword(password, ADMIN_PASSWORD_HASH);
  if (!ok) return sendJson(res, { error: "invalid credentials" }, 401);

  const now = Math.floor(Date.now() / 1000);
  const token = await signSession({ username, exp: now + SESSION_TTL_SECONDS });
  sendJson(res, { authenticated: true, username }, 200, {
    "set-cookie": cookieHeader(token, SESSION_TTL_SECONDS),
  });
}

function logout(res: ServerResponse): void {
  sendJson(res, { authenticated: false }, 200, { "set-cookie": cookieHeader("", 0) });
}

function cookieHeader(token: string, maxAge: number): string {
  const parts = [`${COOKIE_NAME}=${token}`, "HttpOnly", "SameSite=Strict", "Path=/", `Max-Age=${maxAge}`];
  if (COOKIE_SECURE) parts.splice(1, 0, "Secure");
  return parts.join("; ");
}

async function verifyPassword(password: string, expectedHash: string): Promise<boolean> {
  const [scheme, hash] = expectedHash.trim().split(":", 2);
  if (!scheme || !hash) return false;
  if (scheme.toLowerCase() !== "sha256") return false;
  const actual = await sha256Hex(password);
  return timingSafeEqual(actual, hash.trim().toLowerCase());
}

async function readSession(req: IncomingMessage): Promise<SessionPayload | null> {
  const cookie = req.headers.cookie ?? "";
  const token = cookie
    .split(";")
    .map((part) => part.trim())
    .find((part) => part.startsWith(`${COOKIE_NAME}=`))
    ?.slice(COOKIE_NAME.length + 1);
  if (!token) return null;

  const [payloadPart, sigPart] = token.split(".", 2);
  if (!payloadPart || !sigPart) return null;
  const expected = await hmacHex(SESSION_SIGNING_SECRET, payloadPart);
  if (!timingSafeEqual(expected, sigPart)) return null;

  let payload: SessionPayload;
  try {
    payload = JSON.parse(decodeBase64Url(payloadPart)) as SessionPayload;
  } catch {
    return null;
  }
  if (!payload.username || payload.exp < Math.floor(Date.now() / 1000)) return null;
  return payload;
}

async function signSession(payload: SessionPayload): Promise<string> {
  const payloadPart = encodeBase64Url(JSON.stringify(payload));
  const sig = await hmacHex(SESSION_SIGNING_SECRET, payloadPart);
  return `${payloadPart}.${sig}`;
}

async function sha256Hex(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const digest = await globalThis.crypto.subtle.digest("SHA-256", bytes);
  return hex(new Uint8Array(digest));
}

async function hmacHex(secret: string, value: string): Promise<string> {
  const key = await globalThis.crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await globalThis.crypto.subtle.sign("HMAC", key, new TextEncoder().encode(value));
  return hex(new Uint8Array(sig));
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i += 1) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function hex(bytes: Uint8Array): string {
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function encodeBase64Url(value: string): string {
  return Buffer.from(value, "utf8").toString("base64url");
}

function decodeBase64Url(value: string): string {
  return Buffer.from(value, "base64url").toString("utf8");
}

async function readJson<T>(req: IncomingMessage): Promise<T | null> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  if (chunks.length === 0) return null;
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8")) as T;
  } catch {
    return null;
  }
}

function sendJson(
  res: ServerResponse,
  body: unknown,
  status = 200,
  headers: Record<string, string> = {},
): void {
  res.statusCode = status;
  res.setHeader("content-type", "application/json; charset=utf-8");
  res.setHeader("cache-control", "no-store");
  for (const [k, v] of Object.entries(headers)) res.setHeader(k, v);
  res.end(JSON.stringify(body));
}

const MIME_TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".mjs": "application/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".ico": "image/x-icon",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".ttf": "font/ttf",
  ".otf": "font/otf",
  ".map": "application/json; charset=utf-8",
};

async function serveStatic(res: ServerResponse, pathname: string): Promise<void> {
  const safePath = resolveSafe(DIST_DIR, pathname);
  if (safePath) {
    const file = await readFileIfExists(safePath);
    if (file) return sendFile(res, file.path, file.body);
  }

  const fallback = await readFileIfExists(join(DIST_DIR, "index.html"));
  if (fallback) {
    res.statusCode = 200;
    res.setHeader("content-type", MIME_TYPES[".html"]!);
    res.setHeader("cache-control", "no-store");
    res.end(fallback.body);
    return;
  }
  res.statusCode = 404;
  res.setHeader("content-type", "text/plain; charset=utf-8");
  res.end("not found");
}

type FileResult = { path: string; body: Buffer };

async function readFileIfExists(path: string): Promise<FileResult | null> {
  try {
    const info = await stat(path);
    if (info.isDirectory()) {
      const indexPath = join(path, "index.html");
      const indexInfo = await stat(indexPath).catch(() => null);
      if (!indexInfo?.isFile()) return null;
      return { path: indexPath, body: await readFile(indexPath) };
    }
    if (!info.isFile()) return null;
    return { path, body: await readFile(path) };
  } catch {
    return null;
  }
}

function resolveSafe(root: string, pathname: string): string | null {
  let decoded: string;
  try {
    decoded = decodeURIComponent(pathname);
  } catch {
    return null;
  }
  const target = normalize(join(root, decoded));
  const rootWithSep = root.endsWith("/") ? root : `${root}/`;
  if (target !== root && !target.startsWith(rootWithSep)) return null;
  return target;
}

function sendFile(res: ServerResponse, path: string, body: Buffer): void {
  res.statusCode = 200;
  const ext = extname(path).toLowerCase();
  res.setHeader("content-type", MIME_TYPES[ext] ?? "application/octet-stream");
  if (path.endsWith("index.html")) {
    res.setHeader("cache-control", "no-store");
  } else {
    res.setHeader("cache-control", "public, max-age=31536000, immutable");
  }
  res.end(body);
}
