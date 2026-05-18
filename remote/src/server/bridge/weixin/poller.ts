import { routeWeixinText, type RoutedSession, type WeixinAiFollowup, type WeixinRouteReply } from "./agent.js";
import type { WeixinBindingStore } from "./binding.js";
import { WeixinClient } from "./client.js";
import type { WeixinBindingRecord, WeixinGetUpdatesResponse, WeixinMessage } from "./types.js";

export const WEIXIN_SESSION_EXPIRED_ERRCODE = -14;

export type HandleDecision = { ok: boolean; reason: string };

export type ProcessUpdatesInput = {
  binding: WeixinBindingRecord;
  messages: WeixinMessage[];
  routeText: (text: string) => Promise<WeixinRouteReply>;
  sendText: (toUserId: string, text: string, contextToken: string) => Promise<void>;
  startAiFollowup?: (reply: WeixinRouteReply, message: WeixinMessage) => void;
  shouldContinue?: () => boolean;
  logger?: Logger;
};

export type Logger = Pick<Console, "warn">;

export type WeixinPollerClient = {
  getUpdates: (buf: string) => Promise<WeixinGetUpdatesResponse>;
  sendTextMessage: (toUserId: string, text: string, contextToken: string) => Promise<void>;
};

export type WeixinPollerScheduler = {
  setTimeout: (callback: () => void, ms: number) => unknown;
  clearTimeout: (timer: unknown) => void;
};

export type WeixinPollerOptions = {
  createClient?: (binding: WeixinBindingRecord) => WeixinPollerClient;
  scheduler?: WeixinPollerScheduler;
  aiReplyCheckpointsMs?: number[];
};

const DEFAULT_AI_REPLY_CHECKPOINTS_MS = [10000, 30000, 60000, 120000];

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
  const shouldStop = () => input.shouldContinue ? !input.shouldContinue() : false;
  for (const message of input.messages) {
    if (shouldStop()) return;
    if (!shouldHandleWeixinMessage(input.binding, message).ok) continue;
    const text = extractWeixinText(message);
    if (!text) continue;
    try {
      const reply = await input.routeText(text);
      if (shouldStop()) return;
      if (reply.text.trim()) {
        await input.sendText(message.from_user_id ?? "", reply.text.trim(), message.context_token ?? "");
        if (shouldStop()) return;
      }
      if (reply.ai) input.startAiFollowup?.(reply, message);
    } catch (err) {
      if (shouldStop()) return;
      input.logger?.warn("weixin message processing failed", {
        from_user_id: message.from_user_id ?? "",
        to_user_id: message.to_user_id ?? "",
        has_context_token: Boolean(message.context_token),
      }, err);
    }
  }
}

export class WeixinPoller {
  private timer: unknown = null;
  private readonly aiReplyTimers = new Set<unknown>();
  private readonly aiReplyCleanups = new Set<() => void>();
  private runningGeneration: number | null = null;
  private active = false;
  private generation = 0;
  private readonly createClient: (binding: WeixinBindingRecord) => WeixinPollerClient;
  private readonly scheduler: WeixinPollerScheduler;
  private readonly aiReplyCheckpointsMs: number[];

  constructor(
    private readonly store: WeixinBindingStore,
    private readonly sessions: () => RoutedSession[],
    private readonly logger: Logger = console,
    options: WeixinPollerOptions = {},
  ) {
    this.createClient = options.createClient ?? ((binding) => new WeixinClient({ baseUrl: binding.base_url, token: binding.token }));
    this.aiReplyCheckpointsMs = options.aiReplyCheckpointsMs ?? DEFAULT_AI_REPLY_CHECKPOINTS_MS;
    this.scheduler = options.scheduler ?? {
      setTimeout: (callback, ms) => setTimeout(callback, ms),
      clearTimeout: (timer) => clearTimeout(timer as NodeJS.Timeout),
    };
  }

  start(): void {
    if (this.active) return;
    this.active = true;
    this.generation += 1;
    if (this.timer) return;
    this.timer = this.scheduler.setTimeout(() => {
      this.timer = null;
      void this.tick();
    }, 0);
  }

  stop(): void {
    this.active = false;
    this.generation += 1;
    if (this.timer) this.scheduler.clearTimeout(this.timer);
    this.timer = null;
    for (const timer of this.aiReplyTimers) this.scheduler.clearTimeout(timer);
    this.aiReplyTimers.clear();
    for (const cleanup of [...this.aiReplyCleanups]) cleanup();
    this.aiReplyCleanups.clear();
  }

  async runOnceForTest(): Promise<void> {
    this.active = true;
    this.generation += 1;
    await this.tick();
  }

  private schedule(ms: number): void {
    if (!this.active) return;
    if (this.timer) this.scheduler.clearTimeout(this.timer);
    this.timer = this.scheduler.setTimeout(() => {
      this.timer = null;
      void this.tick();
    }, ms);
  }

  private async tick(): Promise<void> {
    if (!this.active) return;
    const generation = this.generation;
    if (this.runningGeneration === generation) return this.schedule(1000);
    this.runningGeneration = generation;
    try {
      const settings = await this.store.loadSettings();
      if (this.isStale(generation)) return;
      const binding = await this.store.loadBinding();
      if (this.isStale(generation)) return;
      if (!settings.enabled || !binding?.token) return this.schedule(5000);

      const client = this.createClient(binding);
      const buf = await this.store.loadSyncBuf();
      if (this.isStale(generation)) return;
      const updates = await client.getUpdates(buf);
      if (this.isStale(generation)) return;
      const shouldContinue = () => !this.isStale(generation);
      if (updates.errcode === WEIXIN_SESSION_EXPIRED_ERRCODE) {
        await this.store.saveSettings({ ...settings, enabled: false }, shouldContinue);
        if (this.isStale(generation)) return;
        this.logger.warn("weixin session expired; bridge disabled");
        return this.schedule(30000);
      }
      await processWeixinUpdates({
        binding,
        messages: updates.msgs ?? [],
        logger: this.logger,
        shouldContinue,
        routeText: async (text) => routeWeixinText({
          text,
          settings,
          sessions: this.sessions(),
          saveTargetSession: async (key) => {
            if (!shouldContinue()) return;
            const currentSettings = await this.store.loadSettings();
            if (!shouldContinue()) return;
            await this.store.saveSettings({ ...currentSettings, target_session: key }, shouldContinue);
          },
        }),
        sendText: (to, text, contextToken) => client.sendTextMessage(to, text, contextToken),
        startAiFollowup: (reply, message) => {
          if (!reply.ai) return;
          this.startAiFollowup(reply.ai, {
            client,
            contextToken: message.context_token ?? "",
            generation,
            replyTimeoutMs: settings.reply_timeout_ms,
            toUserId: message.from_user_id ?? "",
          });
        },
      });
      if (!shouldContinue()) return;
      if (typeof updates.get_updates_buf === "string") await this.store.saveSyncBuf(updates.get_updates_buf);
      if (!shouldContinue()) return;
      return this.schedule(Math.max(1000, updates.longpolling_timeout_ms ?? 1000));
    } catch (err) {
      if (this.isStale(generation)) return;
      this.logger.warn("weixin poll failed", err);
      return this.schedule(5000);
    } finally {
      if (this.runningGeneration === generation) this.runningGeneration = null;
    }
  }

  private isStale(generation: number): boolean {
    return !this.active || this.generation !== generation;
  }

  private startAiFollowup(
    ai: WeixinAiFollowup,
    options: {
      client: WeixinPollerClient;
      contextToken: string;
      generation: number;
      replyTimeoutMs: number;
      toUserId: string;
    },
  ): void {
    if (!options.toUserId || this.isStale(options.generation)) return;
    const maxCheckpointMs = Math.max(0, ...this.aiReplyCheckpointsMs);
    const effectiveReplyTimeoutMs = Math.max(options.replyTimeoutMs, maxCheckpointMs);
    const checkpoints = this.aiReplyCheckpointsMs
      .filter((ms) => ms > 0 && ms <= effectiveReplyTimeoutMs)
      .sort((a, b) => a - b);
    if (checkpoints.length === 0) return;

    const timers = new Set<unknown>();
    const observableSession = ai.session as WeixinAiFollowup["session"] & {
      onLayout?: (listener: () => void) => () => void;
    };
    let unsubscribeLayout: (() => void) | null = null;
    let cleanup: (() => void) | null = null;
    let finished = false;
    const finish = () => {
      if (finished) return;
      finished = true;
      for (const timer of timers) {
        this.scheduler.clearTimeout(timer);
        this.aiReplyTimers.delete(timer);
      }
      timers.clear();
      unsubscribeLayout?.();
      unsubscribeLayout = null;
      if (cleanup) this.aiReplyCleanups.delete(cleanup);
    };
    const checkProgress = (sendPendingProgress: boolean) => {
      if (finished || this.isStale(options.generation)) return;
      void (async () => {
        const progress = aiReplyProgress(ai.baselineTranscript, ai.session.latestAiChatTranscript());
        if (!progress.text) return;
        if (!progress.done && !sendPendingProgress) return;
        if (progress.done) finish();
        try {
          if (this.isStale(options.generation)) return;
          await options.client.sendTextMessage(options.toUserId, progress.text, options.contextToken);
        } catch (err) {
          if (!this.isStale(options.generation)) this.logger.warn("weixin ai followup send failed", err);
        } finally {
          if (!unsubscribeLayout && timers.size === 0 && !finished) finish();
        }
      })();
    };

    cleanup = finish;
    this.aiReplyCleanups.add(cleanup);
    if (typeof observableSession.onLayout === "function") {
      unsubscribeLayout = observableSession.onLayout(() => checkProgress(false));
    }

    for (const delay of checkpoints) {
      let timer: unknown = null;
      timer = this.scheduler.setTimeout(() => {
        if (timer !== null) {
          timers.delete(timer);
          this.aiReplyTimers.delete(timer);
        }
        if (finished || this.isStale(options.generation)) return;
        checkProgress(true);
      }, delay);
      timers.add(timer);
      this.aiReplyTimers.add(timer);
    }
  }
}

type AiSection = {
  role: "metadata" | "user" | "assistant" | "tool" | "reasoning";
  label: string;
  content: string;
};

function aiReplyProgress(baselineTranscript: string, currentTranscript: string): { done: boolean; text: string } {
  const baselineMessages = aiMessages(parseAiSections(baselineTranscript));
  const currentSections = parseAiSections(currentTranscript);
  const currentMessages = aiMessages(currentSections);
  const newMessages = messagesAfterBaseline(baselineMessages, currentMessages);
  const status = latestStatus(currentSections).toLowerCase();
  const lastAssistant = [...newMessages].reverse().find((message) => message.role === "assistant" && message.content.trim());

  if (lastAssistant && !isAiActiveStatus(status)) {
    return { done: true, text: lastAssistant.content.trim() };
  }
  if (status.includes("running tools") || newMessages.some((message) => message.role === "tool")) {
    return { done: false, text: "还在处理中，工具调用仍在执行。" };
  }
  return { done: false, text: "还在处理中，等待 AI 回复。" };
}

function messagesAfterBaseline(baselineMessages: AiSection[], currentMessages: AiSection[]): AiSection[] {
  if (baselineMessages.length === 0) return currentMessages;
  if (currentMessages.length === 0) return [];

  const maxOverlap = Math.min(baselineMessages.length, currentMessages.length);
  for (let overlap = maxOverlap; overlap > 0; overlap -= 1) {
    const baselineStart = baselineMessages.length - overlap;
    let matched = true;
    for (let i = 0; i < overlap; i += 1) {
      if (!sameAiMessage(baselineMessages[baselineStart + i], currentMessages[i])) {
        matched = false;
        break;
      }
    }
    if (matched) return currentMessages.slice(overlap);
  }
  return currentMessages;
}

function sameAiMessage(a: AiSection, b: AiSection): boolean {
  return a.role === b.role && a.content === b.content;
}

function isAiActiveStatus(status: string): boolean {
  return (
    status.includes("running tools") ||
    status.includes("thinking") ||
    status.includes("streaming") ||
    status.includes("stopping")
  );
}

function aiMessages(sections: AiSection[]): AiSection[] {
  return sections.filter((section) => section.role === "user" || section.role === "assistant" || section.role === "tool");
}

function latestStatus(sections: AiSection[]): string {
  for (let i = sections.length - 1; i >= 0; i -= 1) {
    if (sections[i].label.toLowerCase() === "status") return sections[i].content.trim();
  }
  return "";
}

function parseAiSections(transcript: string): AiSection[] {
  const sections: AiSection[] = [];
  const lines = transcript.replace(/\r\n/g, "\n").split("\n");
  let current: { label: string; role: AiSection["role"] } | null = null;
  let contentLines: string[] = [];

  for (const line of lines) {
    const match = /^(Model|Status|You|User|AI|Assistant|Tool|Reasoning):\s*$/i.exec(line.trim());
    if (match) {
      flushCurrent();
      current = { label: normalizedLabel(match[1]), role: roleForLabel(match[1]) };
      contentLines = [];
      continue;
    }
    if (current) contentLines.push(line);
  }
  flushCurrent();
  return sections;

  function flushCurrent(): void {
    if (!current) return;
    sections.push({
      ...current,
      content: trimBlankLines(contentLines).join("\n"),
    });
  }
}

function roleForLabel(label: string): AiSection["role"] {
  const lower = label.toLowerCase();
  if (lower === "you" || lower === "user") return "user";
  if (lower === "ai" || lower === "assistant") return "assistant";
  if (lower === "tool") return "tool";
  if (lower === "reasoning") return "reasoning";
  return "metadata";
}

function normalizedLabel(label: string): string {
  const lower = label.toLowerCase();
  if (lower === "you" || lower === "user") return "You";
  if (lower === "ai" || lower === "assistant") return "AI";
  if (lower === "tool") return "Tool";
  if (lower === "reasoning") return "Reasoning";
  if (lower === "status") return "Status";
  return "Model";
}

function trimBlankLines(lines: string[]): string[] {
  let start = 0;
  let end = lines.length;
  while (start < end && lines[start].trim() === "") start += 1;
  while (end > start && lines[end - 1].trim() === "") end -= 1;
  return lines.slice(start, end);
}
