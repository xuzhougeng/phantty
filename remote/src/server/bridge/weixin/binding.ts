import { randomUUID } from "node:crypto";
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";

import type { WeixinBindingRecord, WeixinSettings } from "./types.js";

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
    return readOptional(this.syncBufPath);
  }

  async saveSyncBuf(value: string): Promise<void> {
    await writeAtomicText(this.syncBufPath, value, 0o600);
  }
}

export function normalizeSettings(input: Partial<WeixinSettings>): WeixinSettings {
  const timeout = Number(input.reply_timeout_ms ?? DEFAULT_WEIXIN_SETTINGS.reply_timeout_ms);
  return {
    enabled: input.enabled === true,
    target_session: String(input.target_session ?? "").trim(),
    reply_timeout_ms: Number.isFinite(timeout) && timeout >= 5000 && timeout <= 180000
      ? timeout
      : DEFAULT_WEIXIN_SETTINGS.reply_timeout_ms,
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
  const tmp = `${path}.${process.pid}.${randomUUID()}.tmp`;
  try {
    await writeFile(tmp, value, { mode });
    await rename(tmp, path);
  } catch (err) {
    await rm(tmp, { force: true });
    throw err;
  }
}
