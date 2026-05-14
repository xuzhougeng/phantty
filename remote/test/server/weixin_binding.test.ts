import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { WeixinBindingStore } from "../../src/server/bridge/weixin/binding.js";

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

test("WeixinBindingStore handles concurrent same-path sync buffer writes", async () => {
  const dir = await mkdtemp(join(tmpdir(), "phantty-weixin-"));
  const store = new WeixinBindingStore(dir);
  const originalDateNow = Date.now;
  Date.now = () => 1234567890;
  try {
    await Promise.all(["cursor-1", "cursor-2", "cursor-3", "cursor-4"].map((value) => store.saveSyncBuf(value)));
  } finally {
    Date.now = originalDateNow;
  }

  assert.match(await store.loadSyncBuf(), /^cursor-[1-4]$/);
});

test("WeixinBindingStore preserves sync buffer bytes exactly", async () => {
  const dir = await mkdtemp(join(tmpdir(), "phantty-weixin-"));
  const store = new WeixinBindingStore(dir);
  const cursor = "  \nopaque cursor\nwith trailing whitespace\t \n";

  await store.saveSyncBuf(cursor);

  assert.equal(await store.loadSyncBuf(), cursor);
  assert.equal(await readFile(join(dir, "weixin", "sync_buf"), "utf8"), cursor);
});

test("WeixinBindingStore writes sensitive files with owner-only mode on POSIX", async () => {
  if (process.platform === "win32") return;

  const dir = await mkdtemp(join(tmpdir(), "phantty-weixin-"));
  const store = new WeixinBindingStore(dir);
  await store.saveBinding({
    token: "secret-token",
    base_url: "https://ilink.example",
    user_id: "user@im.wechat",
    account_id: "bot@im.bot",
    bound_at: "2026-05-14T00:00:00Z",
  });
  await store.saveSettings({ enabled: true, target_session: "alpha", reply_timeout_ms: 45000 });
  await store.saveSyncBuf("cursor");

  assert.equal((await stat(join(dir, "weixin", "binding.json"))).mode & 0o777, 0o600);
  assert.equal((await stat(join(dir, "weixin", "settings.json"))).mode & 0o777, 0o600);
  assert.equal((await stat(join(dir, "weixin", "sync_buf"))).mode & 0o777, 0o600);
});
