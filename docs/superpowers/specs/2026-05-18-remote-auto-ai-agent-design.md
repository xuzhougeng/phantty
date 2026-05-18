# Remote Auto AI Agent Creation - Design

## Context

Phantty Remote's Weixin bridge routes plain text and `/ai <content>` to the
selected Remote session's AI Chat surface. Today, if the selected session has no
AI Chat tab, `remote/src/server/bridge/weixin/agent.ts` returns:

`当前 Remote session 没有 AI Chat tab。请先在 Phantty 打开 AI Chat，或使用 /term <命令> 显式发送到终端。`

The desired behavior is to create an AI Agent tab automatically instead. Remote
is Phantty-specific and has no Ghostty equivalent, so this design follows the
existing Remote relay architecture rather than comparing to Ghostty.

## Goal

When a Weixin user sends plain text or `/ai <content>` to a connected Remote
session that has no AI Chat tab, Phantty should automatically open a new AI
Agent tab using the same behavior as the desktop command center's `New Agent`
entry:

- If an AI profile exists, use the default profile and force agent mode on.
- If no AI profile exists, do not create a tab; return a clear setup message.
- Once the tab appears in the Remote layout, send the original text to that new
  AI Chat surface and start the normal AI follow-up tracking.

Direct terminal input remains explicit through `/term <command>` and `/keys
<text>`.

## Architecture

### Relay Server

`RemoteSession` gains a small control-message method, `requestAiAgent()`, that
sends a JSON message to the connected Phantty websocket:

```json
{"type":"open-ai-agent","requestId":"remote-ai-1"}
```

The request id lets the desktop reply with an explicit result:

```json
{"type":"open-ai-agent-result","requestId":"remote-ai-1","status":"opened"}
```

Supported result statuses are:

- `opened` when the desktop created, or already has, a usable Agent tab.
- `no-profile` when no AI Chat profile is configured.
- `failed` when tab creation fails for another reason.

The method returns `false` if Phantty is offline or the websocket send fails.

`routeWeixinText()` keeps resolving the target session exactly as it does today.
`sendAi()` changes from a synchronous "find or reject" helper into an async
flow:

1. Look for an existing AI Chat surface.
2. If found, send input exactly as today.
3. If missing, call `requestAiAgent()`.
4. Wait for the matching `open-ai-agent-result`.
5. If the result is `opened`, wait for a later layout update containing an AI
   Chat surface.
6. Send the original text to that surface.
7. Return the usual `信息已收到，开始处理。` reply and AI follow-up metadata.

The result and layout waits are both bounded. The timeout should be short enough
to give immediate Weixin feedback but long enough for the desktop UI thread to
create the tab and publish layout; 2 seconds is the intended default.

### Desktop Remote Client

`src/remote_client.zig` already receives server messages and handles
`input-bytes`. It will also recognize `open-ai-agent`, extract `requestId`, and
dispatch a control callback.

The callback should not mutate UI state on the network thread. It should post a
Win32 message to the AppWindow UI thread, matching the existing pattern used for
Remote AI input and agent tool tab creation.

After the UI thread handles the request, the remote client sends
`open-ai-agent-result` back to the relay with the same `requestId`.

### AppWindow

AppWindow handles the new UI-thread request by opening the default agent session:

- Load AI profiles.
- If no profile exists, report failure to the caller.
- If a profile exists, create an AI Chat tab from profile index `0` with
  `agent=true`, matching the command center `New Agent` behavior.
- Mark UI state dirty so the next Remote layout includes the new AI Chat
  surface.

The request result must distinguish at least:

- Created or already usable.
- No AI profile configured.
- Tab creation failed, including tab limit or invalid profile.

The desktop does not need to echo the new surface id directly. The result tells
the relay whether creation was accepted; the subsequent layout remains the
source of truth for the actual AI Chat surface id.

## Error Handling

If Phantty is offline or the control message cannot be sent, Weixin receives:

`Phantty 当前离线，无法打开 AI Agent。`

If no AI profile is configured, Weixin receives:

`Phantty 尚未配置 AI Chat profile。请先在桌面端创建 AI Chat profile。`

If the tab request fails for a reason other than missing profile, Weixin
receives:

`Phantty 无法打开 AI Agent。请检查桌面端配置后重试。`

If the tab request is accepted but no AI Chat surface appears before the layout
timeout, Weixin receives:

`已请求 Phantty 打开 AI Agent，但未等到 AI Chat tab。请检查桌面端配置后重试。`

If the tab appears but input send fails, Weixin keeps the existing offline-style
send failure message:

`Phantty 当前离线，无法发送给 AI Agent。`

Unknown slash commands, `/term`, `/keys`, `/sessions`, `/status`, `/use`, and
`/ping` behavior remains unchanged.

## Testing

Server tests should cover:

- Plain text uses an existing AI Chat surface without sending an open request.
- Plain text with no AI Chat surface sends `open-ai-agent`, waits for a layout
  update, then sends the original text to the new AI Chat surface.
- `/ai <content>` follows the same auto-create path.
- Auto-create returns the offline message if Phantty is disconnected.
- Auto-create returns the setup message when Phantty replies `no-profile`.
- Auto-create returns the timeout message when no result or no AI Chat layout
  arrives before the bounded wait expires.
- `/term` still targets a writable terminal and never opens AI Agent.

Zig tests should cover:

- `remote_client.zig` recognizes `open-ai-agent`, extracts `requestId`, and
  does not affect `input-bytes` parsing.
- `remote_client.zig` builds `open-ai-agent-result` messages with escaped
  request ids and valid statuses.
- The AppWindow request path maps "default profile exists" to forced agent mode
  and "no profile" to a distinct failure result, where testable without launching
  the full Windows UI.

Manual Windows validation should cover:

1. Start Phantty with Remote enabled and no AI Chat tab.
2. Send plain Weixin text.
3. Confirm a new Agent tab opens automatically.
4. Confirm the message appears in that new AI Chat input/conversation.
5. Repeat with no configured AI profile and confirm the setup message.
