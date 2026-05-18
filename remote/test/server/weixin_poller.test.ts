import test from "node:test";
import assert from "node:assert/strict";

import {
  processWeixinUpdates,
  shouldHandleWeixinMessage,
  WEIXIN_SESSION_EXPIRED_ERRCODE,
  WeixinPoller,
} from "../../src/server/bridge/weixin/poller.js";
import type { WeixinBindingRecord, WeixinMessage, WeixinSettings } from "../../src/server/bridge/weixin/types.js";

const binding: WeixinBindingRecord = {
  token: "s3cr3t",
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

test("processWeixinUpdates isolates per-message route and send failures", async () => {
  const sent: Array<{ to: string; text: string; contextToken: string }> = [];
  const warnings: unknown[][] = [];
  const messages: WeixinMessage[] = [
    {
      from_user_id: "user@im.wechat",
      to_user_id: "bot@im.bot",
      context_token: "ctx1",
      item_list: [{ type: 1, text_item: { text: "route-fails" } }],
    },
    {
      from_user_id: "user@im.wechat",
      to_user_id: "bot@im.bot",
      context_token: "ctx2",
      item_list: [{ type: 1, text_item: { text: "send-fails" } }],
    },
    {
      from_user_id: "user@im.wechat",
      to_user_id: "bot@im.bot",
      context_token: "ctx3",
      item_list: [{ type: 1, text_item: { text: "ok" } }],
    },
  ];

  await processWeixinUpdates({
    binding,
    messages,
    routeText: async (text) => {
      if (text === "route-fails") throw new Error("route failed");
      return { text: `reply:${text}` };
    },
    sendText: async (to, text, contextToken) => {
      if (text === "reply:send-fails") throw new Error("send failed");
      sent.push({ to, text, contextToken });
    },
    logger: { warn: (...args: unknown[]) => warnings.push(args) },
  });

  assert.deepEqual(sent, [{ to: "user@im.wechat", text: "reply:ok", contextToken: "ctx3" }]);
  assert.equal(warnings.length, 2);
  assert.equal(warnings.some((args) => JSON.stringify(args).includes(binding.token)), false);
});

test("WeixinPoller disables settings when the iLink session expires", async () => {
  let savedSettings: WeixinSettings | null = null;
  const poller = new WeixinPoller(
    fakeStore({
      saveSettings: async (settings) => {
        savedSettings = settings;
      },
    }),
    () => [],
    { warn: () => {} },
    {
      createClient: () => ({
        getUpdates: async () => ({ ret: 0, errcode: WEIXIN_SESSION_EXPIRED_ERRCODE }),
        sendTextMessage: async () => {},
      }),
      scheduler: fakeScheduler(),
    },
  );

  await poller.runOnceForTest();

  assert.equal(savedSettings?.enabled, false);
});

test("WeixinPoller discards updates after stop during an in-flight poll", async () => {
  const events: string[] = [];
  let releaseUpdates!: () => void;
  const scheduler = fakeScheduler();
  const poller = new WeixinPoller(
    fakeStore({
      saveSyncBuf: async (value) => {
        events.push(`save:${value}`);
      },
    }),
    () => [{
      key: "alpha",
      session: {
        isPhanttyConnected: () => true,
        findAiChatSurface: () => ({ id: "ai", title: "AI", kind: "ai_chat" }),
        latestAiChatTranscript: () => "Status:\r\nReady",
        sendInput: () => true,
      },
    }] as never,
    { warn: () => {} },
    {
      createClient: () => ({
        getUpdates: async () => {
          await new Promise<void>((resolve) => {
            releaseUpdates = resolve;
          });
          return {
            ret: 0,
            get_updates_buf: "next-cursor",
            longpolling_timeout_ms: 1000,
            msgs: [
              {
                from_user_id: "user@im.wechat",
                to_user_id: "bot@im.bot",
                context_token: "ctx1",
                item_list: [{ type: 1, text_item: { text: "first" } }],
              },
              {
                from_user_id: "user@im.wechat",
                to_user_id: "bot@im.bot",
                context_token: "ctx2",
                item_list: [{ type: 1, text_item: { text: "second" } }],
              },
            ],
          };
        },
        sendTextMessage: async (_to, text) => {
          events.push(`send:${text}`);
          if (text.includes("first")) throw new Error("send failed");
        },
      }),
      scheduler,
    },
  );

  const run = poller.runOnceForTest();
  await new Promise<void>((resolve) => setImmediate(resolve));
  poller.stop();
  releaseUpdates();
  await run;

  assert.deepEqual(events, []);
  assert.equal(scheduler.scheduledCount(), 0);
});

test("WeixinPoller stops message processing before send when stopped during routing", async () => {
  const events: string[] = [];
  let releaseRoute!: () => void;
  let routeStartedResolve!: () => void;
  const routeStarted = new Promise<void>((resolve) => {
    routeStartedResolve = resolve;
  });
  const scheduler = fakeScheduler();
  const poller = new WeixinPoller(
    fakeStore({
      saveSettings: async () => {
        events.push("route:save-target");
        await new Promise<void>((resolve) => {
          releaseRoute = resolve;
          routeStartedResolve();
        });
      },
      saveSyncBuf: async (value) => {
        events.push(`save:${value}`);
      },
    }),
    () => [{
      key: "alpha",
      session: {
        isPhanttyConnected: () => true,
        findAiChatSurface: () => ({ id: "ai", title: "AI", kind: "ai_chat" }),
        latestAiChatTranscript: () => "Status:\r\nReady",
        sendInput: () => true,
      },
    }] as never,
    { warn: () => {} },
    {
      createClient: () => ({
        getUpdates: async () => ({
          ret: 0,
          get_updates_buf: "next-cursor",
          longpolling_timeout_ms: 1000,
          msgs: [{
            from_user_id: "user@im.wechat",
            to_user_id: "bot@im.bot",
            context_token: "ctx1",
            item_list: [{ type: 1, text_item: { text: "/use alpha" } }],
          }],
        }),
        sendTextMessage: async (_to, text) => {
          events.push(`send:${text}`);
        },
      }),
      scheduler,
    },
  );

  const run = poller.runOnceForTest();
  await routeStarted;
  poller.stop();
  releaseRoute();
  await run;

  assert.deepEqual(events, ["route:save-target"]);
  assert.equal(scheduler.scheduledCount(), 0);
});

test("WeixinPoller does not save cursor after stop during an in-flight send", async () => {
  const events: string[] = [];
  let releaseSend!: () => void;
  let sendStartedResolve!: () => void;
  const sendStarted = new Promise<void>((resolve) => {
    sendStartedResolve = resolve;
  });
  const scheduler = fakeScheduler();
  const poller = new WeixinPoller(
    fakeStore({
      saveSyncBuf: async (value) => {
        events.push(`save:${value}`);
      },
    }),
    () => [{
      key: "alpha",
      session: {
        isPhanttyConnected: () => true,
        findAiChatSurface: () => ({ id: "ai", title: "AI", kind: "ai_chat" }),
        latestAiChatTranscript: () => "Status:\r\nReady",
        sendInput: () => true,
      },
    }] as never,
    { warn: () => {} },
    {
      createClient: () => ({
        getUpdates: async () => ({
          ret: 0,
          get_updates_buf: "next-cursor",
          longpolling_timeout_ms: 1000,
          msgs: [{
            from_user_id: "user@im.wechat",
            to_user_id: "bot@im.bot",
            context_token: "ctx1",
            item_list: [{ type: 1, text_item: { text: "hello" } }],
          }],
        }),
        sendTextMessage: async (_to, text) => {
          events.push(`send:${text}`);
          sendStartedResolve();
          await new Promise<void>((resolve) => {
            releaseSend = resolve;
          });
        },
      }),
      scheduler,
    },
  );

  const run = poller.runOnceForTest();
  await sendStarted;
  poller.stop();
  releaseSend();
  await run;

  assert.deepEqual(events, ["send:信息已收到，开始处理。"]);
  assert.equal(scheduler.scheduledCount(), 0);
});

test("WeixinPoller replies pong to /ping without routing to AI chat", async () => {
  const events: string[] = [];
  const poller = new WeixinPoller(
    fakeStore(),
    () => [{
      key: "alpha",
      session: {
        isPhanttyConnected: () => true,
        findAiChatSurface: () => ({ id: "ai", title: "AI", kind: "ai_chat" }),
        latestAiChatTranscript: () => "Status:\r\nReady",
        sendInput: () => {
          events.push("input");
          return true;
        },
      },
    }] as never,
    { warn: () => {} },
    {
      createClient: () => ({
        getUpdates: async () => ({
          ret: 0,
          msgs: [{
            from_user_id: "user@im.wechat",
            to_user_id: "bot@im.bot",
            context_token: "ctx",
            item_list: [{ type: 1, text_item: { text: "/ping" } }],
          }],
        }),
        sendTextMessage: async (_to, text) => {
          events.push(`send:${text}`);
        },
      }),
      scheduler: fakeManualScheduler(),
    },
  );

  await poller.runOnceForTest();

  assert.deepEqual(events, ["send:pong"]);
});

test("WeixinPoller sends AI progress checkpoints at 10, 30, 60, and 120 seconds with legacy timeout settings", async () => {
  const events: string[] = [];
  let transcript = "Model:\r\nDeepSeek\r\n\r\nStatus:\r\nReady\r\n\r\nAI:\r\nready";
  const scheduler = fakeManualScheduler();
  const poller = new WeixinPoller(
    fakeStore({
      loadSettings: async () => ({ enabled: true, target_session: "alpha", reply_timeout_ms: 60000 }),
    }),
    () => [{
      key: "alpha",
      session: {
        isPhanttyConnected: () => true,
        findAiChatSurface: () => ({ id: "ai", title: "AI", kind: "ai_chat" }),
        latestAiChatTranscript: () => transcript,
        sendInput: (_surfaceId: string, text: string) => {
          events.push(`input:${text}`);
          transcript = `${transcript}\r\n\r\nYou:\r\n${text.trim()}`;
          return true;
        },
      },
    }] as never,
    { warn: () => {} },
    {
      createClient: () => ({
        getUpdates: async () => ({
          ret: 0,
          get_updates_buf: "next-cursor",
          longpolling_timeout_ms: 1000,
          msgs: [{
            from_user_id: "user@im.wechat",
            to_user_id: "bot@im.bot",
            context_token: "ctx",
            item_list: [{ type: 1, text_item: { text: "hello" } }],
          }],
        }),
        sendTextMessage: async (_to, text) => {
          events.push(`send:${text}`);
        },
      }),
      scheduler,
    },
  );

  await poller.runOnceForTest();
  assert.deepEqual(events, ["input:hello\r", "send:信息已收到，开始处理。"]);
  assert.deepEqual(scheduler.delays().slice(0, 4), [10000, 30000, 60000, 120000]);

  transcript = `${transcript}\r\n\r\nStatus:\r\nRunning tools...\r\n\r\nTool:\r\nterminal_snapshot`;
  for (const index of [0, 1, 2, 3]) {
    scheduler.fire(index);
    await new Promise<void>((resolve) => setImmediate(resolve));
  }

  assert.equal(events.filter((event) => event === "send:还在处理中，工具调用仍在执行。").length, 4);
});

test("WeixinPoller sends the final AI reply when it completes after all progress checkpoints", async () => {
  const events: string[] = [];
  let transcript = "Model:\r\nDeepSeek\r\n\r\nStatus:\r\nReady\r\n\r\nAI:\r\nready";
  let layoutListener: (() => void) | null = null;
  const scheduler = fakeManualScheduler();
  const poller = new WeixinPoller(
    fakeStore({
      loadSettings: async () => ({ enabled: true, target_session: "alpha", reply_timeout_ms: 30000 }),
    }),
    () => [{
      key: "alpha",
      session: {
        isPhanttyConnected: () => true,
        findAiChatSurface: () => ({ id: "ai", title: "AI", kind: "ai_chat" }),
        latestAiChatTranscript: () => transcript,
        onLayout: (listener: () => void) => {
          layoutListener = listener;
          return () => {
            layoutListener = null;
          };
        },
        sendInput: (_surfaceId: string, text: string) => {
          events.push(`input:${text}`);
          transcript = `${transcript}\r\n\r\nYou:\r\n${text.trim()}`;
          return true;
        },
      },
    }] as never,
    { warn: () => {} },
    {
      aiReplyCheckpointsMs: [10000, 30000],
      createClient: () => ({
        getUpdates: async () => ({
          ret: 0,
          get_updates_buf: "next-cursor",
          longpolling_timeout_ms: 1000,
          msgs: [{
            from_user_id: "user@im.wechat",
            to_user_id: "bot@im.bot",
            context_token: "ctx",
            item_list: [{ type: 1, text_item: { text: "slow task" } }],
          }],
        }),
        sendTextMessage: async (_to, text) => {
          events.push(`send:${text}`);
        },
      }),
      scheduler,
    },
  );

  await poller.runOnceForTest();
  transcript = `${transcript}\r\n\r\nStatus:\r\nRunning tools...\r\n\r\nTool:\r\nterminal_snapshot`;

  scheduler.fire(0);
  await new Promise<void>((resolve) => setImmediate(resolve));
  scheduler.fire(1);
  await new Promise<void>((resolve) => setImmediate(resolve));
  assert.equal(events.at(-1), "send:还在处理中，工具调用仍在执行。");

  transcript = `${transcript}\r\n\r\nStatus:\r\nReady\r\n\r\nAI:\r\nfinal answer after checkpoints`;
  layoutListener?.();
  await new Promise<void>((resolve) => setImmediate(resolve));

  assert.equal(events.at(-1), "send:final answer after checkpoints");
});

test("WeixinPoller sends the final AI reply when completion status is done after tool calls", async () => {
  const events: string[] = [];
  let transcript = "Model:\r\nDeepSeek\r\n\r\nStatus:\r\nReady\r\n\r\nAI:\r\nready";
  let layoutListener: (() => void) | null = null;
  const scheduler = fakeManualScheduler();
  const poller = new WeixinPoller(
    fakeStore({
      loadSettings: async () => ({ enabled: true, target_session: "alpha", reply_timeout_ms: 30000 }),
    }),
    () => [{
      key: "alpha",
      session: {
        isPhanttyConnected: () => true,
        findAiChatSurface: () => ({ id: "ai", title: "AI", kind: "ai_chat" }),
        latestAiChatTranscript: () => transcript,
        onLayout: (listener: () => void) => {
          layoutListener = listener;
          return () => {
            layoutListener = null;
          };
        },
        sendInput: (_surfaceId: string, text: string) => {
          events.push(`input:${text}`);
          transcript = `${transcript}\r\n\r\nYou:\r\n${text.trim()}`;
          return true;
        },
      },
    }] as never,
    { warn: () => {} },
    {
      aiReplyCheckpointsMs: [10000],
      createClient: () => ({
        getUpdates: async () => ({
          ret: 0,
          get_updates_buf: "next-cursor",
          longpolling_timeout_ms: 1000,
          msgs: [{
            from_user_id: "user@im.wechat",
            to_user_id: "bot@im.bot",
            context_token: "ctx",
            item_list: [{ type: 1, text_item: { text: "run a tool" } }],
          }],
        }),
        sendTextMessage: async (_to, text) => {
          events.push(`send:${text}`);
        },
      }),
      scheduler,
    },
  );

  await poller.runOnceForTest();
  transcript = `${transcript}\r\n\r\nStatus:\r\nRunning tools...\r\n\r\nTool:\r\npowershell_exec completed. Output omitted in remote chat.`;
  scheduler.fire(0);
  await new Promise<void>((resolve) => setImmediate(resolve));
  assert.equal(events.at(-1), "send:还在处理中，工具调用仍在执行。");

  transcript = `${transcript}\r\n\r\nStatus:\r\nDone in 3.5s\r\n\r\nAI:\r\nfinal answer after tool`;
  layoutListener?.();
  await new Promise<void>((resolve) => setImmediate(resolve));

  assert.equal(events.at(-1), "send:final answer after tool");
});

test("WeixinPoller sends the final AI reply when the current transcript was compacted", async () => {
  const events: string[] = [];
  const oldMessages = Array.from({ length: 12 }, (_, index) => (
    `You:\r\nold question ${index}\r\n\r\nAI:\r\nold answer ${index}`
  )).join("\r\n\r\n");
  let transcript = `Model:\r\nDeepSeek\r\n\r\nStatus:\r\nReady\r\n\r\n${oldMessages}`;
  let layoutListener: (() => void) | null = null;
  const scheduler = fakeManualScheduler();
  const poller = new WeixinPoller(
    fakeStore({
      loadSettings: async () => ({ enabled: true, target_session: "alpha", reply_timeout_ms: 30000 }),
    }),
    () => [{
      key: "alpha",
      session: {
        isPhanttyConnected: () => true,
        findAiChatSurface: () => ({ id: "ai", title: "AI", kind: "ai_chat" }),
        latestAiChatTranscript: () => transcript,
        onLayout: (listener: () => void) => {
          layoutListener = listener;
          return () => {
            layoutListener = null;
          };
        },
        sendInput: (_surfaceId: string, text: string) => {
          events.push(`input:${text}`);
          transcript = `Model:\r\nDeepSeek\r\n\r\nStatus:\r\nDone\r\n\r\nYou:\r\n${text.trim()}\r\n\r\nTool:\r\npowershell_exec completed. Output omitted in remote chat.\r\n\r\nAI:\r\ncompacted final answer`;
          return true;
        },
      },
    }] as never,
    { warn: () => {} },
    {
      aiReplyCheckpointsMs: [10000],
      createClient: () => ({
        getUpdates: async () => ({
          ret: 0,
          get_updates_buf: "next-cursor",
          longpolling_timeout_ms: 1000,
          msgs: [{
            from_user_id: "user@im.wechat",
            to_user_id: "bot@im.bot",
            context_token: "ctx",
            item_list: [{ type: 1, text_item: { text: "new compacted task" } }],
          }],
        }),
        sendTextMessage: async (_to, text) => {
          events.push(`send:${text}`);
        },
      }),
      scheduler,
    },
  );

  await poller.runOnceForTest();
  layoutListener?.();
  await new Promise<void>((resolve) => setImmediate(resolve));

  assert.equal(events.at(-1), "send:compacted final answer");
});

test("WeixinPoller start is idempotent while getUpdates is in flight", async () => {
  const events: string[] = [];
  let releaseUpdates!: () => void;
  let updatesStartedResolve!: () => void;
  const updatesStarted = new Promise<void>((resolve) => {
    updatesStartedResolve = resolve;
  });
  const scheduler = fakeManualScheduler();
  const poller = new WeixinPoller(
    fakeStore({
      saveSyncBuf: async (value) => {
        events.push(`save:${value}`);
      },
    }),
    () => [],
    { warn: () => {} },
    {
      createClient: () => ({
        getUpdates: async () => {
          updatesStartedResolve();
          await new Promise<void>((resolve) => {
            releaseUpdates = resolve;
          });
          return {
            ret: 0,
            get_updates_buf: "next-cursor",
            longpolling_timeout_ms: 1234,
            msgs: [],
          };
        },
        sendTextMessage: async () => {},
      }),
      scheduler,
    },
  );

  poller.start();
  assert.equal(scheduler.scheduledCount(), 1);
  scheduler.fire(0);
  await updatesStarted;
  poller.start();
  releaseUpdates();
  await new Promise<void>((resolve) => setImmediate(resolve));

  assert.deepEqual(events, ["save:next-cursor"]);
  assert.equal(scheduler.scheduledCount(), 2);
  assert.deepEqual(scheduler.delays(), [0, 1234]);
});

test("WeixinPoller ignores stale getUpdates rejection after restart", async () => {
  const warnings: unknown[][] = [];
  let rejectUpdates!: (err: Error) => void;
  let updatesStartedResolve!: () => void;
  const updatesStarted = new Promise<void>((resolve) => {
    updatesStartedResolve = resolve;
  });
  const scheduler = fakeManualScheduler();
  const poller = new WeixinPoller(
    fakeStore(),
    () => [],
    { warn: (...args: unknown[]) => warnings.push(args) },
    {
      createClient: () => ({
        getUpdates: async () => {
          updatesStartedResolve();
          await new Promise<void>((_resolve, reject) => {
            rejectUpdates = reject;
          });
          return { ret: 0, msgs: [] };
        },
        sendTextMessage: async () => {},
      }),
      scheduler,
    },
  );

  poller.start();
  scheduler.fire(0);
  await updatesStarted;
  poller.stop();
  poller.start();
  rejectUpdates(new Error("old poll failed"));
  await new Promise<void>((resolve) => setImmediate(resolve));

  assert.equal(warnings.length, 0);
  assert.equal(scheduler.scheduledCount(), 2);
  assert.deepEqual(scheduler.delays(), [0, 0]);
});

test("WeixinPoller ignores stale session-expired scheduling after restart", async () => {
  const warnings: unknown[][] = [];
  let releaseSave!: () => void;
  let saveStartedResolve!: () => void;
  const saveStarted = new Promise<void>((resolve) => {
    saveStartedResolve = resolve;
  });
  const scheduler = fakeManualScheduler();
  const poller = new WeixinPoller(
    fakeStore({
      saveSettings: async () => {
        saveStartedResolve();
        await new Promise<void>((resolve) => {
          releaseSave = resolve;
        });
      },
    }),
    () => [],
    { warn: (...args: unknown[]) => warnings.push(args) },
    {
      createClient: () => ({
        getUpdates: async () => ({ ret: 0, errcode: WEIXIN_SESSION_EXPIRED_ERRCODE }),
        sendTextMessage: async () => {},
      }),
      scheduler,
    },
  );

  poller.start();
  scheduler.fire(0);
  await saveStarted;
  poller.stop();
  poller.start();
  releaseSave();
  await new Promise<void>((resolve) => setImmediate(resolve));

  assert.equal(warnings.length, 0);
  assert.equal(scheduler.scheduledCount(), 2);
  assert.deepEqual(scheduler.delays(), [0, 0]);
});

test("WeixinPoller cancels stale session-expired settings save after restart", async () => {
  const savedEnabledValues: boolean[] = [];
  const warnings: unknown[][] = [];
  let releaseSave!: () => void;
  let saveStartedResolve!: () => void;
  const saveStarted = new Promise<void>((resolve) => {
    saveStartedResolve = resolve;
  });
  const scheduler = fakeManualScheduler();
  const poller = new WeixinPoller(
    fakeStore({
      saveSettings: async (settings, shouldContinue) => {
        saveStartedResolve();
        await new Promise<void>((resolve) => {
          releaseSave = resolve;
        });
        if (shouldContinue?.() === false) return false;
        savedEnabledValues.push(settings.enabled);
        return true;
      },
    }),
    () => [],
    { warn: (...args: unknown[]) => warnings.push(args) },
    {
      createClient: () => ({
        getUpdates: async () => ({ ret: 0, errcode: WEIXIN_SESSION_EXPIRED_ERRCODE }),
        sendTextMessage: async () => {},
      }),
      scheduler,
    },
  );

  poller.start();
  scheduler.fire(0);
  await saveStarted;
  poller.stop();
  poller.start();
  releaseSave();
  await new Promise<void>((resolve) => setImmediate(resolve));

  assert.deepEqual(savedEnabledValues, []);
  assert.equal(warnings.length, 0);
  assert.deepEqual(scheduler.delays(), [0, 0]);
});

test("WeixinPoller starts new generation poll while old generation is still running", async () => {
  let getUpdatesCalls = 0;
  let releaseOldUpdates!: () => void;
  let oldUpdatesStartedResolve!: () => void;
  const oldUpdatesStarted = new Promise<void>((resolve) => {
    oldUpdatesStartedResolve = resolve;
  });
  const scheduler = fakeManualScheduler();
  const poller = new WeixinPoller(
    fakeStore(),
    () => [],
    { warn: () => {} },
    {
      createClient: () => ({
        getUpdates: async () => {
          getUpdatesCalls += 1;
          if (getUpdatesCalls === 1) {
            oldUpdatesStartedResolve();
            await new Promise<void>((resolve) => {
              releaseOldUpdates = resolve;
            });
          }
          return { ret: 0, msgs: [] };
        },
        sendTextMessage: async () => {},
      }),
      scheduler,
    },
  );

  try {
    poller.start();
    scheduler.fire(0);
    await oldUpdatesStarted;
    poller.stop();
    poller.start();
    scheduler.fire(1);
    await new Promise<void>((resolve) => setImmediate(resolve));

    assert.equal(getUpdatesCalls, 2);
    assert.deepEqual(scheduler.delays(), [0, 0, 1000]);
  } finally {
    releaseOldUpdates?.();
  }
});

test("WeixinPoller does not save stale route target session after restart", async () => {
  const savedTargets: string[] = [];
  let loadSettingsCalls = 0;
  let releaseStaleLoad!: () => void;
  let staleLoadStartedResolve!: () => void;
  const staleLoadStarted = new Promise<void>((resolve) => {
    staleLoadStartedResolve = resolve;
  });
  const scheduler = fakeManualScheduler();
  const poller = new WeixinPoller(
    fakeStore({
      loadSettings: async () => {
        loadSettingsCalls += 1;
        if (loadSettingsCalls === 2) {
          staleLoadStartedResolve();
          await new Promise<void>((resolve) => {
            releaseStaleLoad = resolve;
          });
        }
        return { enabled: true, target_session: "alpha", reply_timeout_ms: 10000 };
      },
      saveSettings: async (settings) => {
        savedTargets.push(settings.target_session);
      },
    }),
    () => [{
      key: "beta",
      session: {
        isPhanttyConnected: () => true,
        findAiChatSurface: () => ({ id: "ai", title: "AI", kind: "ai_chat" }),
        sendInput: () => true,
      },
    }] as never,
    { warn: () => {} },
    {
      createClient: () => ({
        getUpdates: async () => ({
          ret: 0,
          msgs: [{
            from_user_id: "user@im.wechat",
            to_user_id: "bot@im.bot",
            context_token: "ctx",
            item_list: [{ type: 1, text_item: { text: "/use beta" } }],
          }],
        }),
        sendTextMessage: async () => {},
      }),
      scheduler,
    },
  );

  poller.start();
  scheduler.fire(0);
  await staleLoadStarted;
  poller.stop();
  poller.start();
  releaseStaleLoad();
  await new Promise<void>((resolve) => setImmediate(resolve));

  assert.deepEqual(savedTargets, []);
});

test("WeixinPoller cancels stale route target session save after restart", async () => {
  const savedTargets: string[] = [];
  let saveStartedResolve!: () => void;
  let releaseSave!: () => void;
  const saveStarted = new Promise<void>((resolve) => {
    saveStartedResolve = resolve;
  });
  const scheduler = fakeManualScheduler();
  const poller = new WeixinPoller(
    fakeStore({
      saveSettings: async (settings, shouldContinue) => {
        if (settings.target_session === "beta") {
          saveStartedResolve();
          await new Promise<void>((resolve) => {
            releaseSave = resolve;
          });
        }
        if (shouldContinue?.() === false) return false;
        savedTargets.push(settings.target_session);
        return true;
      },
    }),
    () => [{
      key: "beta",
      session: {
        isPhanttyConnected: () => true,
        findAiChatSurface: () => ({ id: "ai", title: "AI", kind: "ai_chat" }),
        sendInput: () => true,
      },
    }] as never,
    { warn: () => {} },
    {
      createClient: () => ({
        getUpdates: async () => ({
          ret: 0,
          msgs: [{
            from_user_id: "user@im.wechat",
            to_user_id: "bot@im.bot",
            context_token: "ctx",
            item_list: [{ type: 1, text_item: { text: "/use beta" } }],
          }],
        }),
        sendTextMessage: async () => {},
      }),
      scheduler,
    },
  );

  poller.start();
  scheduler.fire(0);
  await saveStarted;
  poller.stop();
  poller.start();
  releaseSave();
  await new Promise<void>((resolve) => setImmediate(resolve));

  assert.deepEqual(savedTargets, []);
});

function fakeStore(overrides: {
  loadSettings?: () => Promise<WeixinSettings>;
  saveSettings?: (settings: WeixinSettings, shouldContinue?: () => boolean) => Promise<boolean | void>;
  saveSyncBuf?: (value: string) => Promise<void>;
} = {}) {
  const settings: WeixinSettings = { enabled: true, target_session: "alpha", reply_timeout_ms: 10000 };
  return {
    loadSettings: overrides.loadSettings ?? (async () => settings),
    loadBinding: async () => binding,
    loadSyncBuf: async () => "current-cursor",
    saveSettings: overrides.saveSettings ?? (async () => true),
    saveSyncBuf: overrides.saveSyncBuf ?? (async () => {}),
  } as never;
}

function fakeScheduler() {
  let scheduled = 0;
  return {
    setTimeout: () => {
      scheduled += 1;
      return scheduled;
    },
    clearTimeout: () => {},
    scheduledCount: () => scheduled,
  };
}

function fakeManualScheduler() {
  const callbacks: Array<() => void> = [];
  const delayValues: number[] = [];
  return {
    setTimeout: (callback: () => void, ms: number) => {
      callbacks.push(callback);
      delayValues.push(ms);
      return callbacks.length;
    },
    clearTimeout: () => {},
    fire: (index: number) => callbacks[index]?.(),
    scheduledCount: () => callbacks.length,
    delays: () => delayValues,
  };
}
