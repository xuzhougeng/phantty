# Command Center Agent Entrypoints Design

## Goal

Add two command-center actions that make AI/Agent workflows faster without
changing existing keyboard shortcuts:

- `New Agent`
- `Select Agent History`

`New Agent` should open the existing AI profile/session launcher and default the
focus to the Agent-oriented path.

`Select Agent History` should open a command-center-native history picker that
lists persisted AI/Agent conversations and, on selection, either switches to
the already-open matching tab or reopens that saved conversation by
`session_id`.

## Why This Shape

This keeps the product consistent with the current architecture:

- `Ctrl+Shift+P` remains the universal command-entry surface.
- `Ctrl+Shift+E` remains the left-sidebar surface.
- The new history picker uses the command center because the user explicitly
  wants a direct command-center flow instead of routing through the sidebar.
- The existing session launcher stays the only place that knows how to open
  configured AI profiles, which avoids creating a second AI-launch UI.

Ghostty comparison:

- Ghostty does not have an AI command center, profile launcher, or agent
  history. This is Phantty-specific functionality and should follow existing
  Phantty command center patterns rather than a Ghostty reference.

## User Experience

## New Agent

When the user opens the command center and chooses `New Agent`:

1. The command center closes.
2. The existing AI profile/session launcher opens.
3. The launcher defaults to the Agent-related action rather than the generic
   chat path.

This is intentionally a faster command-center entry into the existing AI
launcher, not a new direct-spawn path.

## Select Agent History

When the user opens the command center and chooses `Select Agent History`:

1. The command center switches from its normal command list to a history-picker
   subview.
2. The picker shows persisted AI/Agent conversations ordered by newest
   `updated_at` first.
3. The user can move through the list with keyboard navigation.
4. Pressing `Enter` activates the selected history record.
5. Pressing `Esc` returns to the normal command-center command list.

Activation behavior:

- If the selected `session_id` is already open in an AI tab, switch to that tab.
- Otherwise reopen that persisted AI/Agent conversation.

This picker is not a preview-only flow and does not require a second
confirmation step.

## Non-Goals

- No new global keyboard shortcut for `New Agent`
- No new global keyboard shortcut for history selection
- No sidebar involvement for `Select Agent History`
- No deletion, renaming, pinning, or searching of history in this iteration
- No separate command-center flow for non-Agent AI Chat profiles

## Architecture

## Command Center Surface

The command center currently exposes a flat command list. This feature adds a
small second view state for the agent-history picker.

Recommended model:

- normal command list mode
- agent-history picker mode

The history picker should be owned by the command-center overlay state in
`src/renderer/overlays.zig`, because that is already where command-center item
definitions, focus state, and execution logic live.

## Data Source

The history picker should not invent a second history cache.

It should reuse the existing persisted global AI/Agent history from
`src/agent_history.zig` through the already-wired runtime store in
`src/AppWindow.zig`.

This means the command center and the left sidebar share the same persisted
session source of truth, but keep independent selection and scroll state.

## Activation Path

The history picker should reuse the existing runtime reopen helper rather than
duplicating tab/session logic.

Expected path:

- command center picker item -> `AppWindow.reopenAiChatTabFromHistorySessionId`

That keeps `session_id` deduplication in one place.

## New Agent Path

`New Agent` should reuse the existing AI profile/session launcher, not spawn a
conversation directly from command center.

That means command-center execution should call into the launcher-opening path
already used elsewhere, then set launcher focus/state so the Agent-oriented
entry is selected by default.

This preserves one AI session launch workflow instead of creating multiple
partially-overlapping ones.

## State And Input Model

## Command Center History Picker State

Add command-center-local state for:

- whether history picker mode is active
- current selected history index
- cached visible history rows for rendering
- optional scroll offset if needed for long lists

Do not reuse file-explorer selection state for this.

## Keyboard Behavior

While the command center history picker is open:

- `Up` moves selection up
- `Down` moves selection down
- `Enter` activates selected history
- `Esc` returns to the normal command-center command list

The normal command-center command list behavior should remain unchanged outside
this subview.

## Rendering

The command center history picker should visually match the command center,
not the file explorer.

It should present:

- a clear title such as `Agent History`
- one row per persisted conversation
- primary text: conversation title
- secondary text: model name and/or relative updated time if space allows

The list should feel like a command picker, not a filesystem panel.

## Files Expected To Change

Primary write scope:

- `src/renderer/overlays.zig`
- `src/AppWindow.zig`
- possibly `src/input.zig` only if command-center key routing needs a small
  companion change

Possible supporting file:

- `src/agent_history.zig` only if a small row-projection helper for the command
  center is cleaner than repurposing sidebar-specific helpers

## Testing Strategy

### Unit / Integration Tests

- command-center action list includes `New Agent`
- command-center action list includes `Select Agent History`
- history picker rows are ordered newest first
- selecting a history row uses `session_id` reopen behavior
- `Esc` from history picker returns to the normal command-center list

### Manual Validation

1. Open command center with `Ctrl+Shift+P`
2. Select `New Agent`
3. Confirm the AI launcher opens and defaults to the Agent-oriented entry
4. Open command center again
5. Select `Select Agent History`
6. Confirm the command center shows a history list, not the sidebar
7. Select a session already open in another AI tab
8. Confirm focus switches to that existing tab
9. Select a saved session that is not open
10. Confirm it reopens directly into that conversation

## Scope Check

This is a focused command-center workflow improvement layered on top of the new
agent history system. It does not broaden the history feature set or add new
global shortcuts.
