# Remote Weixin iLink Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Weixin iLink Bot bridge to the Phantty Remote Node backend so a bound Weixin user can scan a QR code and send messages into the selected Remote session's AI Agent or terminal.

**Architecture:** The Node Remote server owns iLink QR binding, file-backed binding/settings storage, polling, and Weixin replies. The Zig Phantty app remains unchanged for v1; Weixin input is converted into the existing Remote `input-bytes` message and sent to either an `ai_chat` surface or an explicit terminal surface. The browser console gains an authenticated Weixin settings panel that calls new `/api/weixin/*` routes.

**Tech Stack:** TypeScript NodeNext, Node `http` tests via `node --test`, `ws`, Vite web client, iLink Bot HTTP API, `qrcode` for server-side QR data URLs.

---

## File Structure

Create or modify these files:

- Modify `remote/package.json`: add `qrcode`, `@types/qrcode`, and server test scripts.
- Create `remote/src/server/session.ts`: exported `RemoteSession`, session map, `sendInput`, surface lookup, transcript helpers.
- Modify `remote/src/server/index.ts`: import session helpers, wire Weixin routes, initialize the Weixin poller.
- Create `remote/src/server/bridge/weixin/types.ts`: iLink API and bridge settings types.
- Create `remote/src/server/bridge/weixin/client.ts`: small iLink Bot HTTP client.
- Create `remote/src/server/bridge/weixin/binding.ts`: file-backed binding, settings, and sync buffer store.
- Create `remote/src/server/bridge/weixin/agent.ts`: Weixin command router into `RemoteSession`.
- Create `remote/src/server/bridge/weixin/poller.ts`: polling loop and batch processing.
- Create `remote/src/server/bridge/weixin/routes.ts`: authenticated HTTP route handler.
- Create `remote/src/client/weixin.ts`: web client API helpers and response types.
- Modify `remote/src/client/views/console.ts`: Weixin panel markup and event binding.
- Modify `remote/src/client/styles/console.css`: desktop Weixin panel styles.
- Modify `remote/src/client/styles/responsive.css`: mobile Weixin panel adjustments.
- Modify `remote/README.md`: document Node-only v1 bridge env vars and API routes.
- Create `remote/test/server/*.test.ts`: server unit tests for session, iLink client, store, router, and poller.
- Create `remote/test/client/weixin.test.ts`: pure client helper tests.

Keep Cloudflare Worker parity out of this implementation. Do not touch `remote/src/worker.ts` except to add a short README note that Worker deployment does not support Weixin bridge in v1.

---

### Task 1: Server Test Harness And RemoteSession Extraction

**Files:**
- Modify: `remote/package.json`
- Create: `remote/src/server/session.ts`
- Modify: `remote/src/server/index.ts`
- Test: `remote/test/server/session.test.ts`

- [x] **Step 1: Write the failing session helper tests**

Create `remote/test/server/session.test.ts`:

```ts
import test from "node:test";
import assert from "node:assert/strict";

import { RemoteSession } from "../../src/server/session";

class FakeSocket {
  sent: string[] = [];
  listeners = new Map<string, Array<(raw?: unknown) => void>>();
  send(payload: string): void {
    this.sent.push(payload);
  }
  close(): void {}
  on(event: string, fn: (raw?: unknown) => void): void {
    const list = this.listeners.get(event) ?? [];
    list.push(fn);
    this.listeners.set(event, list);
  }
  emit(event: string, raw?: unknown): void {
    for (const fn of this.listeners.get(event) ?? []) fn(raw);
  }
}

test("RemoteSession finds ai chat and writable terminal surfaces from latest layout", () => {
  const session = new RemoteSession("alpha");
  session.applyLayout({
    type: "layout",
    activeTab: 0,
    tabs: [
      {
        index: 0,
        focusedSurfaceId: "term1",
        surfaces: [
          { id: "term1", title: "PowerShell", focused: true, kind: "terminal", readOnly: false },
          { id: "aichat0000000000", title: "AI", kind: "ai_chat", snapshot: "You\nhello\n\nAI\nhi" },
        ],
      },
    ],
  });

  assert.deepEqual(session.findAiChatSurface(), { id: "aichat0000000000", title: "AI" });
  assert.deepEqual(session.findDefaultWritableSurface(), { id: "term1", title: "PowerShell" });
  assert.equal(session.latestAiChatTranscript(), "You\nhello\n\nAI\nhi");
});

test("RemoteSession sends utf8 input bytes to connected Phantty socket", () => {
  const session = new RemoteSession("alpha");
  const phantty = new FakeSocket();
  session.attachPhantty(phantty as never);

  assert.equal(session.sendInput("surface1", "pwd\r"), true);
  assert.equal(phantty.sent.length, 1);
  assert.deepEqual(JSON.parse(phantty.sent[0]), {
    type: "input-bytes",
    surfaceId: "surface1",
    encoding: "hex",
    data: "7077640d",
  });
});

test("RemoteSession refuses input when Phantty socket is disconnected", () => {
  const session = new RemoteSession("alpha");
  assert.equal(session.sendInput("surface1", "pwd\r"), false);
});
```

- [x] **Step 2: Add server test script and run the failing tests**

Modify `remote/package.json` scripts:

```json
"test:server": "node --import tsx --test test/server/*.test.ts",
"test": "npm run test:client && npm run test:server"
```

Run:

```bash
cd remote
npm run test:server
```

Expected: FAIL because `remote/src/server/session.ts` does not exist.

- [x] **Step 3: Create `RemoteSession` module**

Create `remote/src/server/session.ts` by moving the existing `RemoteSession`, `RelayMessage`, `safeSend`, `safeJson`, `trackHeartbeat`, `getSession`, and `sessions` map out of `index.ts`. Add these public helpers:

```ts
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

const sessions = new Map<string, RemoteSession>();

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
    const focused = this.layoutSurfaces().find((surface) => surface.focused && surface.kind !== "ai_chat" && surface.readOnly !== true);
    if (focused) return { id: focused.id, title: focused.title ?? focused.id };
    const first = this.layoutSurfaces().find((surface) => surface.kind !== "ai_chat" && surface.readOnly !== true);
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

  attachPhantty(socket: WebSocket): void;

  attachBrowser(socket: WebSocket): void;

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
    /* ignore send failure */
  }
}
```

Implement `attachPhantty` and `attachBrowser` by moving the complete current implementations from `index.ts` into this module. Keep the relay behavior identical, including heartbeat handling, JSON parsing, socket close cleanup, browser replay of the latest layout, and Phantty replacement behavior. The only intentional change inside the moved Phantty message handler is:

```ts
if (message.type === "layout") {
  this.applyLayout(message);
}
this.broadcast(message);
```

- [x] **Step 4: Wire `index.ts` to the extracted module**

Modify `remote/src/server/index.ts`:

```ts
import { getSession } from "./session";
```

Remove the local `RelayMessage`, `RemoteSession`, `sessions`, `getSession`, `safeSend`, and `safeJson` definitions after moving them. Keep `WebSocketServer`, `handleUpgrade`, login, static serving, and cookie code in `index.ts`.

- [x] **Step 5: Run session tests**

Run:

```bash
cd remote
npm run test:server
npm run typecheck
```

Expected: PASS.

- [x] **Step 6: Commit**

```bash
git add remote/package.json remote/src/server/index.ts remote/src/server/session.ts remote/test/server/session.test.ts
git commit -m "Refactor remote session helpers"
```

---

### Task 2: iLink Client And Types

**Files:**
- Create: `remote/src/server/bridge/weixin/types.ts`
- Create: `remote/src/server/bridge/weixin/client.ts`
- Test: `remote/test/server/weixin_client.test.ts`

- [x] **Step 1: Write failing iLink client tests**

Create `remote/test/server/weixin_client.test.ts`:

```ts
import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";

import { WeixinClient } from "../../src/server/bridge/weixin/client";

async function withServer(handler: Parameters<typeof createServer>[0]) {
  const server = createServer(handler);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("missing server address");
  return {
    baseUrl: `http://127.0.0.1:${address.port}`,
    close: () => new Promise<void>((resolve) => server.close(() => resolve())),
  };
}

test("WeixinClient requests QR code with bot_type 3", async () => {
  const seen: string[] = [];
  const server = await withServer((req, res) => {
    seen.push(req.url ?? "");
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ ret: 0, qrcode: "qr-session", qrcode_img_content: "qr-content" }));
  });
  try {
    const client = new WeixinClient({ baseUrl: server.baseUrl, token: "" });
    const qr = await client.getQRCode();
    assert.deepEqual(qr, { ret: 0, qrcode: "qr-session", qrcode_img_content: "qr-content" });
    assert.equal(seen[0], "/ilink/bot/get_bot_qrcode?bot_type=3");
  } finally {
    await server.close();
  }
});

test("WeixinClient posts getupdates with auth headers", async () => {
  let auth = "";
  let authType = "";
  let bodyText = "";
  const server = await withServer((req, res) => {
    auth = req.headers.authorization ?? "";
    authType = String(req.headers.authorizationtype ?? "");
    req.on("data", (chunk) => { bodyText += chunk; });
    req.on("end", () => {
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify({ ret: 0, msgs: [], get_updates_buf: "next" }));
    });
  });
  try {
    const client = new WeixinClient({ baseUrl: server.baseUrl, token: "secret" });
    const updates = await client.getUpdates("cursor");
    assert.equal(auth, "Bearer secret");
    assert.equal(authType, "ilink_bot_token");
    assert.equal(JSON.parse(bodyText).get_updates_buf, "cursor");
    assert.equal(updates.get_updates_buf, "next");
  } finally {
    await server.close();
  }
});

test("WeixinClient sends text messages through sendmessage", async () => {
  let body: unknown = null;
  const server = await withServer((req, res) => {
    assert.equal(req.url, "/ilink/bot/sendmessage");
    req.on("data", (chunk) => { body = JSON.parse(String(chunk)); });
    req.on("end", () => {
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify({ ret: 0 }));
    });
  });
  try {
    const client = new WeixinClient({ baseUrl: server.baseUrl, token: "secret" });
    await client.sendTextMessage("user@im.wechat", "hello", "ctx");
    assert.equal((body as { msg: { to_user_id: string } }).msg.to_user_id, "user@im.wechat");
  } finally {
    await server.close();
  }
});
```

- [x] **Step 2: Run test to verify it fails**

Run:

```bash
cd remote
npm run test:server
```

Expected: FAIL because `client.ts` and `types.ts` do not exist.

- [x] **Step 3: Add iLink types**

Create `remote/src/server/bridge/weixin/types.ts`:

```ts
export const WEIXIN_DEFAULT_BASE_URL = "https://ilinkai.weixin.qq.com";
export const WEIXIN_BOT_TYPE = "3";
export const WEIXIN_CHANNEL_VERSION = "1.0.2";

export type WeixinBaseInfo = { channel_version: string };

export type WeixinQRCodeResponse = {
  ret: number;
  qrcode?: string;
  qrcode_img_content?: string;
  message?: string;
};

export type WeixinQRCodeStatusResponse = {
  ret: number;
  status?: "wait" | "scaned" | "confirmed" | "expired" | string;
  bot_token?: string;
  baseurl?: string;
  ilink_bot_id?: string;
  ilink_user_id?: string;
  message?: string;
};

export type WeixinMessageItem = {
  type?: number;
  text_item?: { text?: string };
  voice_item?: { text?: string };
};

export type WeixinMessage = {
  from_user_id?: string;
  to_user_id?: string;
  client_id?: string;
  message_type?: number;
  message_state?: number;
  context_token?: string;
  group_id?: string;
  item_list?: WeixinMessageItem[];
};

export type WeixinGetUpdatesResponse = {
  ret: number;
  msgs?: WeixinMessage[];
  get_updates_buf?: string;
  longpolling_timeout_ms?: number;
  errcode?: number;
  message?: string;
};

export type WeixinSendMessageResponse = {
  ret: number;
  errcode?: number;
  message?: string;
};

export type WeixinBindingRecord = {
  token: string;
  base_url: string;
  user_id: string;
  account_id: string;
  bound_at: string;
};

export type WeixinSettings = {
  enabled: boolean;
  target_session: string;
  reply_timeout_ms: number;
};
```

- [x] **Step 4: Add iLink client**

Create `remote/src/server/bridge/weixin/client.ts`:

```ts
import {
  WEIXIN_BOT_TYPE,
  WEIXIN_CHANNEL_VERSION,
  WEIXIN_DEFAULT_BASE_URL,
  type WeixinGetUpdatesResponse,
  type WeixinQRCodeResponse,
  type WeixinQRCodeStatusResponse,
  type WeixinSendMessageResponse,
} from "./types";

export type WeixinClientOptions = {
  baseUrl?: string;
  token?: string;
  fetchImpl?: typeof fetch;
};

export class WeixinClient {
  private readonly baseUrl: string;
  private readonly token: string;
  private readonly fetchImpl: typeof fetch;

  constructor(options: WeixinClientOptions = {}) {
    this.baseUrl = (options.baseUrl || WEIXIN_DEFAULT_BASE_URL).replace(/\/+$/, "");
    this.token = options.token ?? "";
    this.fetchImpl = options.fetchImpl ?? fetch;
  }

  getBaseUrl(): string {
    return this.baseUrl;
  }

  async getQRCode(): Promise<WeixinQRCodeResponse> {
    const res = await this.fetchImpl(`${this.baseUrl}/ilink/bot/get_bot_qrcode?bot_type=${WEIXIN_BOT_TYPE}`, {
      headers: this.headers(),
    });
    return this.decodeJson<WeixinQRCodeResponse>(res, "get_bot_qrcode");
  }

  async getQRCodeStatus(qrcode: string): Promise<WeixinQRCodeStatusResponse> {
    const url = `${this.baseUrl}/ilink/bot/get_qrcode_status?qrcode=${encodeURIComponent(qrcode)}`;
    const res = await this.fetchImpl(url, { headers: this.headers() });
    return this.decodeJson<WeixinQRCodeStatusResponse>(res, "get_qrcode_status");
  }

  async getUpdates(buf: string): Promise<WeixinGetUpdatesResponse> {
    return this.post<WeixinGetUpdatesResponse>("/ilink/bot/getupdates", {
      get_updates_buf: buf,
      base_info: { channel_version: WEIXIN_CHANNEL_VERSION },
    });
  }

  async sendTextMessage(toUserId: string, text: string, contextToken = ""): Promise<void> {
    const result = await this.post<WeixinSendMessageResponse>("/ilink/bot/sendmessage", {
      msg: {
        to_user_id: toUserId,
        client_id: `phantty-weixin-${Date.now()}-${Math.floor(Math.random() * 100000)}`,
        message_type: 2,
        message_state: 2,
        context_token: contextToken,
        item_list: [{ type: 1, text_item: { text } }],
      },
      base_info: { channel_version: WEIXIN_CHANNEL_VERSION },
    });
    if (result.ret !== 0) throw new Error(`sendmessage ret=${result.ret} errcode=${result.errcode ?? 0}: ${result.message ?? ""}`);
  }

  private async post<T>(path: string, body: unknown): Promise<T> {
    const res = await this.fetchImpl(`${this.baseUrl}${path}`, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify(body),
    });
    return this.decodeJson<T>(res, path);
  }

  private headers(): Record<string, string> {
    const headers: Record<string, string> = {
      "content-type": "application/json",
      AuthorizationType: "ilink_bot_token",
      "X-WECHAT-UIN": Buffer.from(String(Math.floor(Math.random() * 2 ** 32))).toString("base64"),
    };
    if (this.token) headers.Authorization = `Bearer ${this.token}`;
    return headers;
  }

  private async decodeJson<T>(res: Response, label: string): Promise<T> {
    if (!res.ok) throw new Error(`iLink API ${label} returned ${res.status}`);
    return (await res.json()) as T;
  }
}
```

- [x] **Step 5: Run tests**

Run:

```bash
cd remote
npm run test:server
npm run typecheck
```

Expected: PASS.

- [x] **Step 6: Commit**

```bash
git add remote/src/server/bridge/weixin/types.ts remote/src/server/bridge/weixin/client.ts remote/test/server/weixin_client.test.ts
git commit -m "Add Weixin iLink client"
```

---

### Task 3: File-Backed Weixin Binding Store

**Files:**
- Create: `remote/src/server/bridge/weixin/binding.ts`
- Test: `remote/test/server/weixin_binding.test.ts`

- [x] **Step 1: Write failing binding store tests**

Create `remote/test/server/weixin_binding.test.ts`:

```ts
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { WeixinBindingStore } from "../../src/server/bridge/weixin/binding";

test("WeixinBindingStore persists binding, settings, and sync buffer", async () => {
  const dir = await mkdtemp(join(tmpdir(), "phantty-weixin-"));
  const store = new WeixinBindingStore(dir);

  assert.equal(await store.loadBinding(), null);
  assert.deepEqual(await store.loadSettings(), { enabled: false, target_session: "", reply_timeout_ms: 60000 });

  await store.saveBinding({
    token: "secret-token",
    base_url: "https://ilink.example",
    user_id: "user@im.wechat",
    account_id: "bot@im.bot",
    bound_at: "2026-05-14T00:00:00Z",
  });
  await store.saveSettings({ enabled: true, target_session: "alpha", reply_timeout_ms: 45000 });
  await store.saveSyncBuf("cursor");

  assert.equal((await store.loadBinding())?.token, "secret-token");
  assert.deepEqual(await store.loadSettings(), { enabled: true, target_session: "alpha", reply_timeout_ms: 45000 });
  assert.equal(await store.loadSyncBuf(), "cursor");

  const bindingRaw = await readFile(join(dir, "weixin", "binding.json"), "utf8");
  assert.equal(JSON.parse(bindingRaw).token, "secret-token");
});

test("WeixinBindingStore public summary hides token", async () => {
  const dir = await mkdtemp(join(tmpdir(), "phantty-weixin-"));
  const store = new WeixinBindingStore(dir);
  await store.saveBinding({
    token: "secret-token",
    base_url: "https://ilink.example",
    user_id: "user@im.wechat",
    account_id: "bot@im.bot",
    bound_at: "2026-05-14T00:00:00Z",
  });

  assert.deepEqual(await store.bindingSummary(), {
    bound: true,
    base_url: "https://ilink.example",
    user_id: "user@im.wechat",
    account_id: "bot@im.bot",
    bound_at: "2026-05-14T00:00:00Z",
  });
});

test("WeixinBindingStore unbind removes binding and sync buffer", async () => {
  const dir = await mkdtemp(join(tmpdir(), "phantty-weixin-"));
  const store = new WeixinBindingStore(dir);
  await store.saveBinding({
    token: "secret-token",
    base_url: "https://ilink.example",
    user_id: "user@im.wechat",
    account_id: "bot@im.bot",
    bound_at: "2026-05-14T00:00:00Z",
  });
  await store.saveSyncBuf("cursor");
  await store.clearBinding();

  assert.equal(await store.loadBinding(), null);
  assert.equal(await store.loadSyncBuf(), "");
  await assert.rejects(stat(join(dir, "weixin", "binding.json")));
});
```

- [x] **Step 2: Run failing tests**

Run:

```bash
cd remote
npm run test:server
```

Expected: FAIL because `binding.ts` does not exist.

- [x] **Step 3: Implement binding store**

Create `remote/src/server/bridge/weixin/binding.ts`:

```ts
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";

import type { WeixinBindingRecord, WeixinSettings } from "./types";

export type WeixinBindingSummary = {
  bound: boolean;
  base_url?: string;
  user_id?: string;
  account_id?: string;
  bound_at?: string;
};

export const DEFAULT_WEIXIN_SETTINGS: WeixinSettings = {
  enabled: false,
  target_session: "",
  reply_timeout_ms: 60000,
};

export class WeixinBindingStore {
  readonly root: string;
  readonly dir: string;
  readonly bindingPath: string;
  readonly settingsPath: string;
  readonly syncBufPath: string;

  constructor(root: string) {
    this.root = root;
    this.dir = join(root, "weixin");
    this.bindingPath = join(this.dir, "binding.json");
    this.settingsPath = join(this.dir, "settings.json");
    this.syncBufPath = join(this.dir, "sync_buf");
  }

  async loadBinding(): Promise<WeixinBindingRecord | null> {
    const raw = await readOptional(this.bindingPath);
    if (!raw.trim()) return null;
    return JSON.parse(raw) as WeixinBindingRecord;
  }

  async saveBinding(binding: WeixinBindingRecord): Promise<void> {
    await writeAtomicJson(this.bindingPath, binding, 0o600);
  }

  async clearBinding(): Promise<void> {
    await rm(this.bindingPath, { force: true });
    await rm(this.syncBufPath, { force: true });
  }

  async bindingSummary(): Promise<WeixinBindingSummary> {
    const binding = await this.loadBinding();
    if (!binding) return { bound: false };
    return {
      bound: true,
      base_url: binding.base_url,
      user_id: binding.user_id,
      account_id: binding.account_id,
      bound_at: binding.bound_at,
    };
  }

  async loadSettings(): Promise<WeixinSettings> {
    const raw = await readOptional(this.settingsPath);
    if (!raw.trim()) return { ...DEFAULT_WEIXIN_SETTINGS };
    const parsed = JSON.parse(raw) as Partial<WeixinSettings>;
    return normalizeSettings(parsed);
  }

  async saveSettings(settings: WeixinSettings): Promise<void> {
    await writeAtomicJson(this.settingsPath, normalizeSettings(settings), 0o600);
  }

  async loadSyncBuf(): Promise<string> {
    return (await readOptional(this.syncBufPath)).trim();
  }

  async saveSyncBuf(value: string): Promise<void> {
    await writeAtomicText(this.syncBufPath, value.trim(), 0o600);
  }
}

export function normalizeSettings(input: Partial<WeixinSettings>): WeixinSettings {
  const timeout = Number(input.reply_timeout_ms ?? DEFAULT_WEIXIN_SETTINGS.reply_timeout_ms);
  return {
    enabled: input.enabled === true,
    target_session: String(input.target_session ?? "").trim(),
    reply_timeout_ms: Number.isFinite(timeout) && timeout >= 5000 && timeout <= 180000 ? timeout : 60000,
  };
}

async function readOptional(path: string): Promise<string> {
  try {
    return await readFile(path, "utf8");
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") return "";
    throw err;
  }
}

async function writeAtomicJson(path: string, value: unknown, mode: number): Promise<void> {
  await writeAtomicText(path, `${JSON.stringify(value, null, 2)}\n`, mode);
}

async function writeAtomicText(path: string, value: string, mode: number): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const tmp = `${path}.${process.pid}.${Date.now()}.tmp`;
  await writeFile(tmp, value, { mode });
  await rename(tmp, path);
}
```

- [x] **Step 4: Run tests**

Run:

```bash
cd remote
npm run test:server
npm run typecheck
```

Expected: PASS.

- [x] **Step 5: Commit**

```bash
git add remote/src/server/bridge/weixin/binding.ts remote/test/server/weixin_binding.test.ts
git commit -m "Add Weixin binding store"
```

---

### Task 4: Weixin Agent Router

**Files:**
- Create: `remote/src/server/bridge/weixin/agent.ts`
- Test: `remote/test/server/weixin_agent.test.ts`

- [x] **Step 1: Write failing router tests**

Create `remote/test/server/weixin_agent.test.ts`:

```ts
import test from "node:test";
import assert from "node:assert/strict";

import { routeWeixinText, maskSessionKey } from "../../src/server/bridge/weixin/agent";
import { RemoteSession } from "../../src/server/session";

function sessionWithLayout(): RemoteSession {
  const session = new RemoteSession("alpha-secret");
  session.applyLayout({
    type: "layout",
    activeTab: 0,
    tabs: [{
      index: 0,
      focusedSurfaceId: "term1",
      surfaces: [
        { id: "term1", title: "PowerShell", kind: "terminal", focused: true, readOnly: false },
        { id: "aichat0000000000", title: "AI", kind: "ai_chat", snapshot: "AI\nready" },
      ],
    }],
  });
  session.phantty = { send: (payload: string) => { sent.push(JSON.parse(payload)); } } as never;
  return session;
}

let sent: unknown[] = [];

test("maskSessionKey keeps only a short prefix", () => {
  assert.equal(maskSessionKey("abcdef123456"), "abcd****");
});

test("plain text routes to ai chat with carriage return", async () => {
  sent = [];
  const reply = await routeWeixinText({
    text: "summarize current work",
    settings: { enabled: true, target_session: "alpha-secret", reply_timeout_ms: 10000 },
    sessions: [{ key: "alpha-secret", session: sessionWithLayout() }],
  });
  assert.match(reply.text, /已发送给 Phantty AI Agent/);
  assert.equal((sent[0] as { surfaceId: string }).surfaceId, "aichat0000000000");
  assert.equal((sent[0] as { data: string }).data, "73756d6d6172697a652063757272656e7420776f726b0d");
});

test("/term routes to writable terminal with carriage return", async () => {
  sent = [];
  const reply = await routeWeixinText({
    text: "/term pwd",
    settings: { enabled: true, target_session: "alpha-secret", reply_timeout_ms: 10000 },
    sessions: [{ key: "alpha-secret", session: sessionWithLayout() }],
  });
  assert.match(reply.text, /已发送到终端/);
  assert.equal((sent[0] as { surfaceId: string }).surfaceId, "term1");
  assert.equal((sent[0] as { data: string }).data, "7077640d");
});

test("router asks user to choose session when multiple sessions exist and no target is configured", async () => {
  const reply = await routeWeixinText({
    text: "hello",
    settings: { enabled: true, target_session: "", reply_timeout_ms: 10000 },
    sessions: [
      { key: "alpha-secret", session: sessionWithLayout() },
      { key: "beta-secret", session: sessionWithLayout() },
    ],
  });
  assert.match(reply.text, /请先发送 `\/use/);
});
```

- [x] **Step 2: Run failing tests**

Run:

```bash
cd remote
npm run test:server
```

Expected: FAIL because `agent.ts` does not exist.

- [x] **Step 3: Implement router**

Create `remote/src/server/bridge/weixin/agent.ts`:

```ts
import type { RemoteSession } from "../../session";
import type { WeixinSettings } from "./types";

export type RoutedSession = { key: string; session: RemoteSession };
export type WeixinRouteInput = {
  text: string;
  settings: WeixinSettings;
  sessions: RoutedSession[];
  saveTargetSession?: (key: string) => Promise<void>;
};
export type WeixinRouteReply = { text: string };

export async function routeWeixinText(input: WeixinRouteInput): Promise<WeixinRouteReply> {
  const text = input.text.trim();
  if (!text) return { text: "" };

  const activeSessions = input.sessions.filter(({ session }) => session.isPhanttyConnected());
  const [cmd, arg] = splitCommand(text);
  if (cmd === "/help") return { text: helpText() };
  if (cmd === "/sessions") return { text: sessionsText(input.sessions) };
  if (cmd === "/status") return { text: statusText(input.settings, input.sessions) };
  if (cmd === "/use") return useSession(arg, input);

  const target = resolveTargetSession(input.settings, activeSessions);
  if (!target.session) return { text: target.error };

  if (cmd === "/term") return sendTerminal(target.session, arg, true);
  if (cmd === "/keys") return sendTerminal(target.session, arg, false);
  if (cmd === "/ai") return sendAi(target.session, arg);
  if (cmd.startsWith("/")) return { text: `未知命令：${cmd}\n\n${helpText()}` };
  return sendAi(target.session, text);
}

export function maskSessionKey(key: string): string {
  const trimmed = key.trim();
  if (trimmed.length <= 4) return `${trimmed}****`;
  return `${trimmed.slice(0, 4)}****`;
}

function splitCommand(text: string): [string, string] {
  const normalized = text.startsWith("／") ? `/${text.slice(1)}` : text;
  if (!normalized.startsWith("/")) return ["", normalized];
  const [command, ...rest] = normalized.split(/\s+/);
  return [command.toLowerCase(), rest.join(" ").trim()];
}

function resolveTargetSession(settings: WeixinSettings, sessions: RoutedSession[]): { session: RemoteSession | null; error: string } {
  const configured = settings.target_session.trim();
  if (configured) {
    const matched = sessions.find((candidate) => candidate.key === configured);
    if (!matched) return { session: null, error: `目标 Remote session 不在线：${maskSessionKey(configured)}。发送 /sessions 查看在线会话。` };
    return { session: matched.session, error: "" };
  }
  if (sessions.length === 1) return { session: sessions[0].session, error: "" };
  if (sessions.length === 0) return { session: null, error: "当前没有在线的 Phantty Remote session。请先在 Phantty 中启用 remote 并连接到该后台。" };
  return { session: null, error: `当前有多个在线 session：\n${sessionsText(sessions)}\n\n请先发送 \`/use <session>\` 选择目标。` };
}

async function useSession(arg: string, input: WeixinRouteInput): Promise<WeixinRouteReply> {
  const key = arg.trim();
  if (!key) return { text: sessionsText(input.sessions) + "\n\n发送 `/use <完整 session>` 选择目标。" };
  const matched = input.sessions.find((candidate) => candidate.key === key);
  if (!matched) return { text: `未找到在线 session：${maskSessionKey(key)}。` };
  await input.saveTargetSession?.(key);
  return { text: `已选择 Remote session：${maskSessionKey(key)}` };
}

function sendAi(session: RemoteSession, text: string): WeixinRouteReply {
  const ai = session.findAiChatSurface();
  if (!ai) return { text: "当前 Remote session 没有 AI Chat tab。请先在 Phantty 打开 AI Chat，或使用 `/term <命令>` 显式发送到终端。" };
  if (!session.sendInput(ai.id, `${text}\r`)) return { text: "Phantty 当前离线，无法发送给 AI Agent。" };
  return { text: "已发送给 Phantty AI Agent，等待结果中。" };
}

function sendTerminal(session: RemoteSession, text: string, enter: boolean): WeixinRouteReply {
  const terminal = session.findDefaultWritableSurface();
  if (!terminal) return { text: "当前 Remote session 没有可写终端 surface。" };
  const payload = enter ? `${text}\r` : text;
  if (!session.sendInput(terminal.id, payload)) return { text: "Phantty 当前离线，无法发送到终端。" };
  return { text: `已发送到终端：${terminal.title}` };
}

function sessionsText(sessions: RoutedSession[]): string {
  if (sessions.length === 0) return "当前没有在线 Remote session。";
  return sessions.map(({ key, session }) => `- ${maskSessionKey(key)} ${session.isPhanttyConnected() ? "online" : "offline"}`).join("\n");
}

function statusText(settings: WeixinSettings, sessions: RoutedSession[]): string {
  return [
    `微信桥接：${settings.enabled ? "已开启" : "已关闭"}`,
    `目标 session：${settings.target_session ? maskSessionKey(settings.target_session) : "未选择"}`,
    `在线 session：${sessions.length}`,
  ].join("\n");
}

function helpText(): string {
  return [
    "Phantty Weixin Bridge 命令：",
    "/status 查看状态",
    "/sessions 查看在线 Remote session",
    "/use <session> 选择目标 session",
    "/ai <内容> 发送给 AI Agent",
    "/term <命令> 显式发送到终端并回车",
    "/keys <文本> 显式发送原始文本到终端",
    "普通文本默认发送给 AI Agent。",
  ].join("\n");
}
```

- [x] **Step 4: Run tests**

Run:

```bash
cd remote
npm run test:server
npm run typecheck
```

Expected: PASS.

- [x] **Step 5: Commit**

```bash
git add remote/src/server/bridge/weixin/agent.ts remote/test/server/weixin_agent.test.ts
git commit -m "Add Weixin remote agent router"
```

---

### Task 5: Weixin Poller

**Files:**
- Create: `remote/src/server/bridge/weixin/poller.ts`
- Test: `remote/test/server/weixin_poller.test.ts`

- [ ] **Step 1: Write failing poller tests**

Create `remote/test/server/weixin_poller.test.ts`:

```ts
import test from "node:test";
import assert from "node:assert/strict";

import { processWeixinUpdates, shouldHandleWeixinMessage } from "../../src/server/bridge/weixin/poller";
import type { WeixinBindingRecord, WeixinMessage } from "../../src/server/bridge/weixin/types";

const binding: WeixinBindingRecord = {
  token: "token",
  base_url: "https://ilink.example",
  user_id: "user@im.wechat",
  account_id: "bot@im.bot",
  bound_at: "2026-05-14T00:00:00Z",
};

test("shouldHandleWeixinMessage rejects group messages, bot echoes, and unexpected users", () => {
  assert.equal(shouldHandleWeixinMessage(binding, { group_id: "group", from_user_id: "user@im.wechat" }).ok, false);
  assert.equal(shouldHandleWeixinMessage(binding, { from_user_id: "bot@im.bot" }).reason, "bot_echo");
  assert.equal(shouldHandleWeixinMessage(binding, { from_user_id: "other@im.wechat" }).reason, "unexpected_sender");
  assert.equal(shouldHandleWeixinMessage(binding, { from_user_id: "user@im.wechat", to_user_id: "bot@im.bot" }).ok, true);
});

test("processWeixinUpdates extracts text and sends replies", async () => {
  const sent: Array<{ to: string; text: string; contextToken: string }> = [];
  const messages: WeixinMessage[] = [{
    from_user_id: "user@im.wechat",
    to_user_id: "bot@im.bot",
    context_token: "ctx",
    item_list: [{ type: 1, text_item: { text: "hello" } }],
  }];

  await processWeixinUpdates({
    binding,
    messages,
    routeText: async (text) => ({ text: `reply:${text}` }),
    sendText: async (to, text, contextToken) => {
      sent.push({ to, text, contextToken });
    },
  });

  assert.deepEqual(sent, [{ to: "user@im.wechat", text: "reply:hello", contextToken: "ctx" }]);
});
```

- [ ] **Step 2: Run failing tests**

Run:

```bash
cd remote
npm run test:server
```

Expected: FAIL because `poller.ts` does not exist.

- [ ] **Step 3: Implement poller primitives**

Create `remote/src/server/bridge/weixin/poller.ts`:

```ts
import { routeWeixinText, type RoutedSession } from "./agent";
import { WeixinClient } from "./client";
import type { WeixinBindingStore } from "./binding";
import type { WeixinBindingRecord, WeixinMessage } from "./types";

export const WEIXIN_SESSION_EXPIRED_ERRCODE = -14;

export type HandleDecision = { ok: boolean; reason: string };

export type ProcessUpdatesInput = {
  binding: WeixinBindingRecord;
  messages: WeixinMessage[];
  routeText: (text: string) => Promise<{ text: string }>;
  sendText: (toUserId: string, text: string, contextToken: string) => Promise<void>;
};

export function shouldHandleWeixinMessage(binding: WeixinBindingRecord, message: WeixinMessage): HandleDecision {
  const from = (message.from_user_id ?? "").trim();
  const to = (message.to_user_id ?? "").trim();
  if ((message.group_id ?? "").trim()) return { ok: false, reason: "group_message" };
  if (!from) return { ok: false, reason: "missing_sender" };
  if (binding.account_id && from === binding.account_id) return { ok: false, reason: "bot_echo" };
  if (binding.user_id && from !== binding.user_id) return { ok: false, reason: "unexpected_sender" };
  if (binding.account_id && to && to !== binding.account_id) return { ok: false, reason: "unexpected_recipient" };
  return { ok: true, reason: "" };
}

export function extractWeixinText(message: WeixinMessage): string {
  for (const item of message.item_list ?? []) {
    if (item.type === 1 && item.text_item?.text?.trim()) return item.text_item.text.trim();
    if (item.type === 3 && item.voice_item?.text?.trim()) return item.voice_item.text.trim();
  }
  return "";
}

export async function processWeixinUpdates(input: ProcessUpdatesInput): Promise<void> {
  for (const message of input.messages) {
    if (!shouldHandleWeixinMessage(input.binding, message).ok) continue;
    const text = extractWeixinText(message);
    if (!text) continue;
    const reply = await input.routeText(text);
    if (reply.text.trim()) {
      await input.sendText(message.from_user_id ?? "", reply.text.trim(), message.context_token ?? "");
    }
  }
}

export class WeixinPoller {
  private timer: NodeJS.Timeout | null = null;
  private running = false;

  constructor(
    private readonly store: WeixinBindingStore,
    private readonly sessions: () => RoutedSession[],
    private readonly logger: Pick<Console, "log" | "warn" | "error"> = console,
  ) {}

  start(): void {
    if (this.timer) return;
    this.timer = setTimeout(() => void this.tick(), 0);
  }

  stop(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  }

  private schedule(ms: number): void {
    this.stop();
    this.timer = setTimeout(() => void this.tick(), ms);
  }

  private async tick(): Promise<void> {
    if (this.running) return this.schedule(1000);
    this.running = true;
    try {
      const settings = await this.store.loadSettings();
      const binding = await this.store.loadBinding();
      if (!settings.enabled || !binding?.token) return this.schedule(5000);

      const client = new WeixinClient({ baseUrl: binding.base_url, token: binding.token });
      const buf = await this.store.loadSyncBuf();
      const updates = await client.getUpdates(buf);
      if (updates.errcode === WEIXIN_SESSION_EXPIRED_ERRCODE) {
        await this.store.saveSettings({ ...settings, enabled: false });
        this.logger.warn("weixin session expired; bridge disabled");
        return this.schedule(30000);
      }
      if (updates.get_updates_buf) await this.store.saveSyncBuf(updates.get_updates_buf);
      await processWeixinUpdates({
        binding,
        messages: updates.msgs ?? [],
        routeText: async (text) => routeWeixinText({
          text,
          settings,
          sessions: this.sessions(),
          saveTargetSession: async (key) => {
            await this.store.saveSettings({ ...(await this.store.loadSettings()), target_session: key });
          },
        }),
        sendText: (to, text, contextToken) => client.sendTextMessage(to, text, contextToken),
      });
      return this.schedule(Math.max(1000, updates.longpolling_timeout_ms ?? 1000));
    } catch (err) {
      this.logger.warn("weixin poll failed", err);
      return this.schedule(5000);
    } finally {
      this.running = false;
    }
  }
}
```

- [ ] **Step 4: Run tests**

Run:

```bash
cd remote
npm run test:server
npm run typecheck
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add remote/src/server/bridge/weixin/poller.ts remote/test/server/weixin_poller.test.ts
git commit -m "Add Weixin polling flow"
```

---

### Task 6: Authenticated Weixin Routes And Server Wiring

**Files:**
- Modify: `remote/package.json`
- Create: `remote/src/server/bridge/weixin/routes.ts`
- Modify: `remote/src/server/index.ts`
- Test: `remote/test/server/weixin_routes.test.ts`

- [ ] **Step 1: Install QR dependency**

Run:

```bash
cd remote
npm install qrcode
npm install --save-dev @types/qrcode
```

Expected: `remote/package.json` and `remote/package-lock.json` update with `qrcode` and `@types/qrcode`.

- [ ] **Step 2: Write failing route tests**

Create `remote/test/server/weixin_routes.test.ts`:

```ts
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { handleWeixinRoute } from "../../src/server/bridge/weixin/routes";
import { WeixinBindingStore } from "../../src/server/bridge/weixin/binding";

function fakeReq(method: string, path: string, body = "") {
  return {
    method,
    url: path,
    async *[Symbol.asyncIterator]() {
      if (body) yield Buffer.from(body);
    },
  };
}

function fakeRes() {
  const headers = new Map<string, string>();
  return {
    statusCode: 0,
    body: "",
    setHeader(name: string, value: string) { headers.set(name.toLowerCase(), value); },
    end(chunk: string) { this.body += chunk; },
    headers,
  };
}

test("GET /api/weixin/settings returns settings and binding summary", async () => {
  const dir = await mkdtemp(join(tmpdir(), "phantty-weixin-route-"));
  const store = new WeixinBindingStore(dir);
  await store.saveSettings({ enabled: true, target_session: "alpha", reply_timeout_ms: 60000 });
  const res = fakeRes();

  const handled = await handleWeixinRoute(fakeReq("GET", "/api/weixin/settings") as never, res as never, {
    store,
    createClient: () => { throw new Error("not used"); },
    listSessions: () => [],
    restartPoller: () => {},
  });

  assert.equal(handled, true);
  assert.equal(res.statusCode, 200);
  assert.equal(JSON.parse(res.body).settings.enabled, true);
});
```

- [ ] **Step 3: Run failing tests**

Run:

```bash
cd remote
npm run test:server
```

Expected: FAIL because `routes.ts` does not exist.

- [ ] **Step 4: Implement route handler**

Create `remote/src/server/bridge/weixin/routes.ts`:

```ts
import type { IncomingMessage, ServerResponse } from "node:http";
import QRCode from "qrcode";

import { WeixinClient } from "./client";
import type { WeixinBindingStore } from "./binding";
import { normalizeSettings } from "./binding";
import type { WeixinQRCodeStatusResponse, WeixinSettings } from "./types";

export type WeixinRouteContext = {
  store: WeixinBindingStore;
  createClient: (token: string, baseUrl?: string) => WeixinClient;
  listSessions: () => Array<{ key: string; connected: boolean }>;
  restartPoller: () => void;
};

export async function handleWeixinRoute(req: IncomingMessage, res: ServerResponse, ctx: WeixinRouteContext): Promise<boolean> {
  const url = new URL(req.url ?? "/", "http://localhost");
  const method = (req.method ?? "GET").toUpperCase();

  if (url.pathname === "/api/weixin/settings" && method === "GET") {
    return sendJson(res, {
      settings: await ctx.store.loadSettings(),
      binding: await ctx.store.bindingSummary(),
      sessions: ctx.listSessions(),
    });
  }
  if (url.pathname === "/api/weixin/settings" && method === "PUT") {
    const body = await readJson<unknown>(req);
    await ctx.store.saveSettings(normalizeSettings((body ?? {}) as Partial<WeixinSettings>));
    ctx.restartPoller();
    return sendJson(res, { success: true, settings: await ctx.store.loadSettings() });
  }
  if (url.pathname === "/api/weixin/bind/start" && method === "POST") {
    const qr = await ctx.createClient("").getQRCode();
    if (qr.ret !== 0 || !qr.qrcode || !qr.qrcode_img_content) {
      return sendJson(res, { error: qr.message || "weixin qrcode unavailable" }, 502);
    }
    const dataUrl = await QRCode.toDataURL(qr.qrcode_img_content, { margin: 1, width: 240 });
    return sendJson(res, { qrcode: qr.qrcode, qrcode_content: qr.qrcode_img_content, qrcode_data_url: dataUrl, status: "wait" });
  }
  if (url.pathname === "/api/weixin/bind/status" && method === "GET") {
    const qrcode = url.searchParams.get("qrcode")?.trim() ?? "";
    if (!qrcode) return sendJson(res, { error: "qrcode required" }, 400);
    const status = await ctx.createClient("").getQRCodeStatus(qrcode);
    await persistConfirmedStatus(status, ctx);
    return sendJson(res, { status: normalizeStatus(status.status), message: status.message ?? "", binding: await ctx.store.bindingSummary() });
  }
  if (url.pathname === "/api/weixin/bind" && method === "DELETE") {
    await ctx.store.clearBinding();
    ctx.restartPoller();
    return sendJson(res, { success: true });
  }
  return false;
}

async function persistConfirmedStatus(status: WeixinQRCodeStatusResponse, ctx: WeixinRouteContext): Promise<void> {
  if (normalizeStatus(status.status) !== "confirmed") return;
  const token = status.bot_token?.trim() ?? "";
  if (!token) throw new Error("confirmed weixin binding missing bot_token");
  await ctx.store.saveBinding({
    token,
    base_url: status.baseurl?.trim() || ctx.createClient("").getBaseUrl(),
    user_id: status.ilink_user_id?.trim() ?? "",
    account_id: status.ilink_bot_id?.trim() ?? "",
    bound_at: new Date().toISOString(),
  });
  await ctx.store.saveSyncBuf("");
  ctx.restartPoller();
}

function normalizeStatus(status = ""): string {
  const value = status.trim().toLowerCase();
  if (!value || value === "wait") return "wait";
  if (value === "scaned") return "scaned";
  if (value === "confirmed") return "confirmed";
  if (value === "expired") return "expired";
  return value;
}

async function readJson<T>(req: IncomingMessage): Promise<T | null> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  if (chunks.length === 0) return null;
  return JSON.parse(Buffer.concat(chunks).toString("utf8")) as T;
}

function sendJson(res: ServerResponse, body: unknown, status = 200): true {
  res.statusCode = status;
  res.setHeader("content-type", "application/json; charset=utf-8");
  res.setHeader("cache-control", "no-store");
  res.end(JSON.stringify(body));
  return true;
}
```

- [ ] **Step 5: Wire routes and poller in `index.ts`**

Modify `remote/src/server/index.ts`:

```ts
import { resolve } from "node:path";
import { WeixinBindingStore } from "./bridge/weixin/binding";
import { WeixinClient } from "./bridge/weixin/client";
import { handleWeixinRoute } from "./bridge/weixin/routes";
import { WeixinPoller } from "./bridge/weixin/poller";
import { getSession, listSessions } from "./session";

const DATA_DIR = resolve(process.env.REMOTE_DATA_DIR ?? "./data");
const weixinStore = new WeixinBindingStore(DATA_DIR);
const weixinPoller = new WeixinPoller(
  weixinStore,
  () => listSessions().filter(({ connected }) => connected).map(({ key }) => ({ key, session: getSession(key) })),
);

weixinPoller.start();
```

In `routeHttp`, after the `/api/me` branch and before static serving:

```ts
if (url.pathname.startsWith("/api/weixin/")) {
  const session = await readSession(req);
  if (!session) return sendJson(res, { error: "login required" }, 401);
  const handled = await handleWeixinRoute(req, res, {
    store: weixinStore,
    createClient: (token, baseUrl) => new WeixinClient({ token, baseUrl }),
    listSessions,
    restartPoller: () => weixinPoller.start(),
  });
  if (handled) return;
}
```

- [ ] **Step 6: Run tests**

Run:

```bash
cd remote
npm run test:server
npm run typecheck
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add remote/package.json remote/package-lock.json remote/src/server/index.ts remote/src/server/bridge/weixin/routes.ts remote/test/server/weixin_routes.test.ts
git commit -m "Wire Weixin bridge routes"
```

---

### Task 7: Remote Web Console Weixin Panel

**Files:**
- Create: `remote/src/client/weixin.ts`
- Modify: `remote/src/client/views/console.ts`
- Modify: `remote/src/client/styles/console.css`
- Modify: `remote/src/client/styles/responsive.css`
- Test: `remote/test/client/weixin.test.ts`

- [ ] **Step 1: Write failing client helper tests**

Create `remote/test/client/weixin.test.ts`:

```ts
import test from "node:test";
import assert from "node:assert/strict";

import { bridgeStatusText, normalizeWeixinSettings } from "../../src/client/weixin";

test("normalizeWeixinSettings applies defaults", () => {
  assert.deepEqual(normalizeWeixinSettings({}), {
    enabled: false,
    target_session: "",
    reply_timeout_ms: 60000,
  });
});

test("bridgeStatusText describes binding and target state", () => {
  assert.equal(
    bridgeStatusText(
      { enabled: true, target_session: "abcdef", reply_timeout_ms: 60000 },
      { bound: true, user_id: "user@im.wechat" },
    ),
    "Weixin bridge enabled · bound to user@im.wechat · target abcd****",
  );
});
```

- [ ] **Step 2: Run failing client tests**

Run:

```bash
cd remote
npm run test:client
```

Expected: FAIL because `remote/src/client/weixin.ts` does not exist.

- [ ] **Step 3: Add client Weixin API helpers**

Create `remote/src/client/weixin.ts`:

```ts
import { api } from "./transport";
import { maskSessionKey } from "./storage";

export type WeixinSettings = {
  enabled: boolean;
  target_session: string;
  reply_timeout_ms: number;
};

export type WeixinBindingSummary = {
  bound: boolean;
  user_id?: string;
  account_id?: string;
  base_url?: string;
  bound_at?: string;
};

export type WeixinSettingsResponse = {
  settings: WeixinSettings;
  binding: WeixinBindingSummary;
  sessions: Array<{ key: string; connected: boolean }>;
};

export type WeixinBindStartResponse = {
  qrcode: string;
  qrcode_content: string;
  qrcode_data_url: string;
  status: string;
};

export function normalizeWeixinSettings(input: Partial<WeixinSettings>): WeixinSettings {
  return {
    enabled: input.enabled === true,
    target_session: String(input.target_session ?? "").trim(),
    reply_timeout_ms: Number.isFinite(input.reply_timeout_ms) ? Number(input.reply_timeout_ms) : 60000,
  };
}

export function bridgeStatusText(settings: WeixinSettings, binding: WeixinBindingSummary): string {
  const parts = [settings.enabled ? "Weixin bridge enabled" : "Weixin bridge disabled"];
  parts.push(binding.bound ? `bound to ${binding.user_id || binding.account_id || "Weixin"}` : "not bound");
  if (settings.target_session) parts.push(`target ${maskSessionKey(settings.target_session)}`);
  return parts.join(" · ");
}

export async function fetchWeixinSettings(): Promise<WeixinSettingsResponse> {
  const res = await api("/api/weixin/settings");
  if (!res.ok) throw new Error("Failed to load Weixin settings");
  return (await res.json()) as WeixinSettingsResponse;
}

export async function saveWeixinSettings(settings: WeixinSettings): Promise<WeixinSettingsResponse> {
  const res = await api("/api/weixin/settings", { method: "PUT", body: JSON.stringify(settings) });
  if (!res.ok) throw new Error("Failed to save Weixin settings");
  return (await res.json()) as WeixinSettingsResponse;
}

export async function startWeixinBind(): Promise<WeixinBindStartResponse> {
  const res = await api("/api/weixin/bind/start", { method: "POST" });
  if (!res.ok) throw new Error("Failed to start Weixin binding");
  return (await res.json()) as WeixinBindStartResponse;
}

export async function pollWeixinBindStatus(qrcode: string): Promise<{ status: string; message?: string; binding: WeixinBindingSummary }> {
  const res = await api(`/api/weixin/bind/status?qrcode=${encodeURIComponent(qrcode)}`);
  if (!res.ok) throw new Error("Failed to poll Weixin binding");
  return (await res.json()) as { status: string; message?: string; binding: WeixinBindingSummary };
}

export async function unbindWeixin(): Promise<void> {
  const res = await api("/api/weixin/bind", { method: "DELETE" });
  if (!res.ok) throw new Error("Failed to unbind Weixin");
}
```

- [ ] **Step 4: Add console panel markup and bindings**

Modify `remote/src/client/views/console.ts`:

```ts
import {
  bridgeStatusText,
  fetchWeixinSettings,
  normalizeWeixinSettings,
  pollWeixinBindStatus,
  saveWeixinSettings,
  startWeixinBind,
  unbindWeixin,
  type WeixinSettingsResponse,
} from "../weixin";
```

Add this panel after the status panel:

```html
<div class="panel weixin-panel">
  <div class="panel-label">Weixin</div>
  <div id="weixin-status" class="weixin-status">Loading Weixin bridge...</div>
  <label class="weixin-toggle">
    <input id="weixin-enabled" type="checkbox" />
    Enable bridge
  </label>
  <label>
    Target session
    <select id="weixin-target-session"></select>
  </label>
  <div class="form-actions">
    <button type="button" class="secondary-button" id="weixin-save">Save</button>
    <button type="button" class="secondary-button" id="weixin-bind">Bind</button>
    <button type="button" class="secondary-button" id="weixin-unbind">Unbind</button>
  </div>
  <div id="weixin-qr" class="weixin-qr" hidden></div>
</div>
```

Add functions:

```ts
let weixinBindTimer: ReturnType<typeof setTimeout> | null = null;
let weixinState: WeixinSettingsResponse | null = null;

function bindWeixinPanel(): void {
  void refreshWeixinPanel();
  document.querySelector<HTMLButtonElement>("#weixin-save")?.addEventListener("click", () => void saveWeixinPanel());
  document.querySelector<HTMLButtonElement>("#weixin-bind")?.addEventListener("click", () => void startWeixinPanelBind());
  document.querySelector<HTMLButtonElement>("#weixin-unbind")?.addEventListener("click", () => void unbindWeixinPanel());
}

async function refreshWeixinPanel(): Promise<void> {
  try {
    weixinState = await fetchWeixinSettings();
    renderWeixinPanel();
  } catch (err) {
    const status = document.querySelector<HTMLDivElement>("#weixin-status");
    if (status) status.textContent = err instanceof Error ? err.message : "Failed to load Weixin settings";
  }
}

function renderWeixinPanel(): void {
  if (!weixinState) return;
  const settings = normalizeWeixinSettings(weixinState.settings);
  const status = document.querySelector<HTMLDivElement>("#weixin-status");
  const enabled = document.querySelector<HTMLInputElement>("#weixin-enabled");
  const target = document.querySelector<HTMLSelectElement>("#weixin-target-session");
  if (status) status.textContent = bridgeStatusText(settings, weixinState.binding);
  if (enabled) enabled.checked = settings.enabled;
  if (target) {
    target.innerHTML = `<option value="">Auto when only one session is online</option>` + weixinState.sessions
      .map((session) => `<option value="${escapeText(session.key)}">${escapeText(maskSessionKey(session.key))} ${session.connected ? "online" : "offline"}</option>`)
      .join("");
    target.value = settings.target_session;
  }
}

async function saveWeixinPanel(): Promise<void> {
  const enabled = document.querySelector<HTMLInputElement>("#weixin-enabled");
  const target = document.querySelector<HTMLSelectElement>("#weixin-target-session");
  weixinState = await saveWeixinSettings({
    enabled: enabled?.checked === true,
    target_session: target?.value ?? "",
    reply_timeout_ms: weixinState?.settings.reply_timeout_ms ?? 60000,
  });
  renderWeixinPanel();
}

async function startWeixinPanelBind(): Promise<void> {
  const qr = await startWeixinBind();
  const qrRoot = document.querySelector<HTMLDivElement>("#weixin-qr");
  if (qrRoot) {
    qrRoot.hidden = false;
    qrRoot.innerHTML = `<img alt="Weixin binding QR" src="${escapeText(qr.qrcode_data_url)}"><small>Scan with Weixin</small>`;
  }
  scheduleWeixinBindPoll(qr.qrcode);
}

function scheduleWeixinBindPoll(qrcode: string): void {
  if (weixinBindTimer) clearTimeout(weixinBindTimer);
  weixinBindTimer = setTimeout(async () => {
    const result = await pollWeixinBindStatus(qrcode);
    if (result.status === "confirmed") {
      await refreshWeixinPanel();
      const qrRoot = document.querySelector<HTMLDivElement>("#weixin-qr");
      if (qrRoot) qrRoot.hidden = true;
      return;
    }
    if (result.status !== "expired") scheduleWeixinBindPoll(qrcode);
  }, 1500);
}

async function unbindWeixinPanel(): Promise<void> {
  await unbindWeixin();
  await refreshWeixinPanel();
}
```

Call `bindWeixinPanel()` near the other bind calls at the end of `renderConsole`.

- [ ] **Step 5: Add minimal styles**

Modify `remote/src/client/styles/console.css`:

```css
.weixin-panel {
  gap: 10px;
}

.weixin-status {
  color: var(--muted);
  font-size: 0.86rem;
  line-height: 1.4;
}

.weixin-toggle {
  display: flex;
  align-items: center;
  gap: 8px;
}

.weixin-qr {
  display: grid;
  gap: 8px;
  justify-items: center;
}

.weixin-qr img {
  width: min(180px, 100%);
  height: auto;
  background: white;
  border-radius: 6px;
  padding: 8px;
}
```

Modify `remote/src/client/styles/responsive.css`:

```css
@media (max-width: 860px), (pointer: coarse) and (max-width: 1024px) {
  .weixin-qr img {
    width: min(220px, 100%);
  }
}
```

- [ ] **Step 6: Run client checks**

Run:

```bash
cd remote
npm run test:client
npm run typecheck
npm run build
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add remote/src/client/weixin.ts remote/src/client/views/console.ts remote/src/client/styles/console.css remote/src/client/styles/responsive.css remote/test/client/weixin.test.ts
git commit -m "Add Weixin bridge settings panel"
```

---

### Task 8: Documentation And Final Verification

**Files:**
- Modify: `remote/README.md`

- [ ] **Step 1: Update Remote README**

Add a "Weixin iLink Bridge" section to `remote/README.md` after "Routes":

```md
## Weixin iLink Bridge

The Node.js Remote server can host a Weixin iLink Bot bridge. This is a Node
deployment feature in v1; Cloudflare Worker deployment does not run the Weixin
poller.

Runtime state is stored under `REMOTE_DATA_DIR` (default `./data`):

- `weixin/binding.json` stores the iLink bot token and bound user identifiers.
- `weixin/settings.json` stores bridge enablement and target Remote session.
- `weixin/sync_buf` stores the iLink update cursor.

Authenticated routes:

- `GET /api/weixin/settings`
- `PUT /api/weixin/settings`
- `POST /api/weixin/bind/start`
- `GET /api/weixin/bind/status?qrcode=<session>`
- `DELETE /api/weixin/bind`

Plain Weixin text is routed to the selected Remote session's AI Chat surface.
Direct terminal input requires `/term <command>` or `/keys <text>`.
```

- [ ] **Step 2: Run full remote verification**

Run:

```bash
cd remote
npm run test
npm run typecheck
npm run build:docker
```

Expected: all commands pass.

- [ ] **Step 3: Check repository status**

Run:

```bash
git status --short
```

Expected: only the intended `remote/` changes are shown. Existing unrelated untracked files such as `.claude/` and `remote/docs/` may still appear and must not be added.

- [ ] **Step 4: Commit docs and final verification fixes**

```bash
git add remote/README.md
git commit -m "Document Weixin remote bridge"
```

If verification required small fixes in previous files, include those exact files in this commit and mention the fix in the commit body.

---

## Self-Review Checklist

- Spec coverage:
  - Node-only v1 bridge: Tasks 2 through 8.
  - QR binding flow: Tasks 2, 3, 6, 7.
  - iLink polling and message filtering: Task 5.
  - AI Agent reuse through `ai_chat` surface: Tasks 1 and 4.
  - Explicit terminal routing only: Task 4.
  - Authenticated web management UI: Tasks 6 and 7.
  - Storage and docs: Tasks 3 and 8.
- Type consistency:
  - `WeixinSettings` uses `enabled`, `target_session`, `reply_timeout_ms` in server and client.
  - `RemoteSession.sendInput(surfaceId, text)` is used by the router and tested in Task 1.
  - `listSessions()` returns `{ key, connected }`; the poller passes connected sessions into the router as `{ key, session }`.
- Verification:
  - Server tests are added through `npm run test:server`.
  - Client tests remain under `npm run test:client`.
  - Full final check is `npm run test`, `npm run typecheck`, and `npm run build:docker`.
