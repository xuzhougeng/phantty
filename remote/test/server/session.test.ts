import test from "node:test";
import assert from "node:assert/strict";

import { RemoteSession } from "../../src/server/session";

class FakeSocket {
  readyState = 1;
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
    if (event === "error" && !this.listeners.has(event)) {
      throw raw instanceof Error ? raw : new Error("Unhandled error event");
    }
    for (const fn of this.listeners.get(event) ?? []) fn(raw);
  }
}

class ThrowingSocket extends FakeSocket {
  send(_payload: string): void {
    throw new Error("send failed");
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

test("RemoteSession prefers writable terminal surfaces in the active tab", () => {
  const session = new RemoteSession("alpha");
  session.applyLayout({
    type: "layout",
    activeTab: 1,
    tabs: [
      {
        index: 0,
        focusedSurfaceId: "inactive-focused",
        surfaces: [
          {
            id: "inactive-focused",
            title: "Inactive Focused",
            focused: true,
            kind: "terminal",
            readOnly: false,
          },
        ],
      },
      {
        index: 1,
        focusedSurfaceId: "active-terminal",
        surfaces: [
          { id: "active-ai", title: "Active AI", focused: true, kind: "ai_chat", readOnly: false },
          { id: "active-terminal", title: "Active Terminal", kind: "terminal", readOnly: false },
        ],
      },
    ],
  });

  assert.deepEqual(session.findDefaultWritableSurface(), {
    id: "active-terminal",
    title: "Active Terminal",
  });
});

test("RemoteSession notifies layout listeners and supports unsubscribe", () => {
  const session = new RemoteSession("alpha");
  let calls = 0;
  const unsubscribe = session.onLayout(() => {
    calls += 1;
  });

  session.applyLayout({ type: "layout", activeTab: 0, tabs: [] });
  unsubscribe();
  session.applyLayout({ type: "layout", activeTab: 0, tabs: [] });

  assert.equal(calls, 1);
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

test("RemoteSession refuses input when Phantty socket is not open or send fails", () => {
  const session = new RemoteSession("alpha");
  const closedPhantty = new FakeSocket();
  closedPhantty.readyState = 3;
  session.attachPhantty(closedPhantty as never);

  assert.equal(session.sendInput("surface1", "pwd\r"), false);

  const throwingPhantty = new ThrowingSocket();
  session.attachPhantty(throwingPhantty as never);

  assert.equal(session.sendInput("surface1", "pwd\r"), false);
});

test("RemoteSession handles Phantty socket errors without throwing", () => {
  const session = new RemoteSession("alpha");
  const phantty = new FakeSocket();
  session.attachPhantty(phantty as never);

  assert.doesNotThrow(() => phantty.emit("error", new Error("invalid websocket frame")));
});

test("RemoteSession handles browser socket errors without throwing", () => {
  const session = new RemoteSession("alpha");
  const browser = new FakeSocket();
  session.attachBrowser(browser as never);

  assert.doesNotThrow(() => browser.emit("error", new Error("invalid websocket frame")));
});

test("RemoteSession reports Phantty peer status to browsers", () => {
  const session = new RemoteSession("alpha");
  const browser = new FakeSocket();
  session.attachBrowser(browser as never);

  assert.deepEqual(JSON.parse(browser.sent.at(-1) ?? "{}"), {
    type: "peer-status",
    phanttyConnected: false,
  });

  const phantty = new FakeSocket();
  session.attachPhantty(phantty as never);

  assert.deepEqual(JSON.parse(browser.sent.at(-1) ?? "{}"), {
    type: "peer-status",
    phanttyConnected: true,
  });

  phantty.emit("close");

  assert.deepEqual(JSON.parse(browser.sent.at(-1) ?? "{}"), {
    type: "peer-status",
    phanttyConnected: false,
  });
});

test("RemoteSession requests AI Agent open and resolves the matching result", async () => {
  const session = new RemoteSession("alpha");
  const phantty = new FakeSocket();
  session.attachPhantty(phantty as never);

  const pending = session.requestAiAgentOpen("req-1", 50);
  assert.deepEqual(JSON.parse(phantty.sent.at(-1) ?? "{}"), {
    type: "open-ai-agent",
    requestId: "req-1",
  });

  phantty.emit(
    "message",
    Buffer.from(
      JSON.stringify({
        type: "open-ai-agent-result",
        requestId: "req-1",
        status: "opened",
      }),
    ),
  );

  assert.equal(await pending, "opened");
});

test("RemoteSession ignores AI Agent open results with unknown statuses", async () => {
  const session = new RemoteSession("alpha");
  const phantty = new FakeSocket();
  session.attachPhantty(phantty as never);

  const pending = session.requestAiAgentOpen("req-invalid", 10);
  phantty.emit(
    "message",
    Buffer.from(
      JSON.stringify({
        type: "open-ai-agent-result",
        requestId: "req-invalid",
        status: "bogus",
      }),
    ),
  );

  assert.equal(await pending, "timeout");
});

test("RemoteSession AI Agent open request times out without a matching result", async () => {
  const session = new RemoteSession("alpha");
  const phantty = new FakeSocket();
  session.attachPhantty(phantty as never);

  assert.equal(await session.requestAiAgentOpen("req-timeout", 5), "timeout");
});

test("RemoteSession AI Agent open request reports offline when Phantty is disconnected", async () => {
  const session = new RemoteSession("alpha");

  assert.equal(await session.requestAiAgentOpen("req-offline", 5), "offline");
});

test("RemoteSession AI Agent open request reports offline when send fails", async () => {
  const session = new RemoteSession("alpha");
  const phantty = new ThrowingSocket();
  session.attachPhantty(phantty as never);

  assert.equal(await session.requestAiAgentOpen("req-send-fails", 50), "offline");
});

test("RemoteSession consumes AI Agent open results without broadcasting them to browsers", () => {
  const session = new RemoteSession("alpha");
  const browser = new FakeSocket();
  const phantty = new FakeSocket();
  session.attachBrowser(browser as never);
  session.attachPhantty(phantty as never);
  const sentBefore = browser.sent.length;

  phantty.emit(
    "message",
    Buffer.from(
      JSON.stringify({
        type: "open-ai-agent-result",
        requestId: "req-unmatched",
        status: "opened",
      }),
    ),
  );

  assert.equal(browser.sent.length, sentBefore);
});

test("RemoteSession resolves pending AI Agent open requests offline when Phantty closes", async () => {
  const session = new RemoteSession("alpha");
  const phantty = new FakeSocket();
  session.attachPhantty(phantty as never);

  const pending = session.requestAiAgentOpen("req-close", 50);
  phantty.emit("close");

  assert.equal(await pending, "offline");
});

test("RemoteSession resolves pending AI Agent open requests offline when Phantty errors", async () => {
  const session = new RemoteSession("alpha");
  const phantty = new FakeSocket();
  session.attachPhantty(phantty as never);

  const pending = session.requestAiAgentOpen("req-error", 50);
  phantty.emit("error", new Error("socket failed"));

  assert.equal(await pending, "offline");
});

test("RemoteSession resolves pending AI Agent open requests offline when Phantty is replaced", async () => {
  const session = new RemoteSession("alpha");
  const firstPhantty = new FakeSocket();
  const nextPhantty = new FakeSocket();
  session.attachPhantty(firstPhantty as never);

  const pending = session.requestAiAgentOpen("req-replaced", 50);
  session.attachPhantty(nextPhantty as never);

  assert.equal(await pending, "offline");
});
