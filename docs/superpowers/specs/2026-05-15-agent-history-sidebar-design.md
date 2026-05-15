# Agent History Sidebar Design

## Goal

Add persistent global AI/Agent conversation history to Phantty and expose it through the existing left sidebar entry point (`Ctrl+Shift+E`).

The left sidebar should behave by active tab type:

- Terminal tab: show the existing file explorer
- AI/Agent tab: show a global agent history list

Selecting a history item should reopen or focus that exact persisted conversation and continue writing future messages back into the same session record.

## Why This Shape

This follows the current product structure more closely than adding a second sidebar:

- Reuses the existing left-panel container, width, focus, scroll, keyboard, and mouse interactions
- Keeps `Ctrl+Shift+E` as the single mental model for "left utility panel"
- Avoids mixing two incompatible list models into one view: hierarchical files vs time-ordered chat sessions

Ghostty comparison:

- Ghostty has no equivalent AI sidebar or chat-history subsystem, so this work is Phantty-specific and should follow the existing Phantty sidebar/input architecture rather than a Ghostty reference implementation.

## User Experience

### Entry

- `Ctrl+Shift+E` remains the only shortcut
- If the active tab is a terminal tab, the left panel behaves exactly as today
- If the active tab is an AI/Agent tab, the left panel opens an agent history list instead of a file tree

### History List

- The header label changes from `LOCAL Explorer` / `REMOTE Explorer` / `WSL Explorer` to `AGENT History`
- Rows show persisted conversations ordered by `updated_at` descending
- The selected row is navigable with existing up/down handling
- `Enter` activates the selected conversation
- Mouse click selects, double-click also activates
- `Esc` removes focus from the sidebar but does not forcibly close it, matching current explorer behavior

### Activation Behavior

When the user activates a history row:

1. If that persisted conversation is already open in an AI tab, switch to that tab
2. Otherwise open a new AI tab bound to that stored conversation
3. The reopened conversation continues on the same persistent record
4. New user/assistant messages update that record in place

### Non-Goals For V1

- No full-text search
- No rename/delete/archive UI
- No mixed file + history view in the same list
- No terminal-tab access to the history list
- No requirement to restore AI tabs automatically on next launch

## Data Model

Introduce a dedicated persistent store for AI/Agent history rather than extending terminal session restore.

### New Store

Add a separate JSON file, for example under the same app-data area as other Phantty state:

- `agent-history.json`

This store is global across AI/Agent tabs.

### Session Record

Each persisted session record contains:

- `session_id`: stable unique identifier
- `title`
- `base_url`
- `api_key`: persisted because AI chat sessions already need it to continue; if this becomes a security concern later, move to profile indirection instead
- `model`
- `system_prompt`
- `thinking_enabled`
- `reasoning_effort`
- `stream`
- `agent_enabled`
- `messages`
- `created_at`
- `updated_at`

Each persisted message contains:

- `role`
- `content`
- `reasoning` if present
- `usage_footer` if present
- collapsed/auto-expand UI flags only if they are needed to preserve current UX state; otherwise omit them from disk and rebuild defaults on load

### Record Lifecycle

- New AI/Agent tab created from profile defaults creates a new persisted session record immediately
- Opening an old history item reuses its existing `session_id`
- Closing a tab does not delete the record
- History ordering is based on most recent `updated_at`

## Runtime Architecture

### AI Session Ownership

Today `ai_chat.Session` is an in-memory conversation object owned by an AI tab.

After this change:

- `ai_chat.Session` gains a `session_id`
- It must be constructible both from fresh defaults and from a persisted history record
- It must be serializable back into the persistent store

The persistent store remains global application state; the tab remains a live view/editor over one stored session.

### Sidebar Ownership

The current `file_explorer` module owns left-panel state for files only. For V1, do not create a second panel system.

Instead, extend the existing left-panel model with a content mode:

- `files`
- `agent_history`

Important constraint:

- This is a container-level mode switch, not a shared row schema that tries to make files and history items look identical internally

The file-entry structures remain file-specific. History rows get their own lightweight row model.

### Tab Coordination

The tab layer needs lookup by persisted AI session id:

- Find whether a `session_id` is already open
- Switch to that tab if found
- Otherwise spawn a new AI tab from persisted data

This logic belongs with the existing tab management paths in `src/appwindow/tab.zig` and `src/AppWindow.zig`, not in the renderer.

### Storage Architecture

Create a dedicated module for persisted agent history rather than hiding JSON IO inside `ai_chat.zig`.

Recommended module:

- `src/agent_history.zig`

Responsibilities:

- Load store from disk
- Normalize malformed or partial JSON
- Allocate/deallocate session records
- Save store back to disk atomically
- Create new records
- Update existing records from a live `ai_chat.Session`
- Produce sorted history rows for sidebar rendering

This keeps chat runtime code separate from persistence code.

## Input And Rendering Changes

### Input

`src/input.zig` currently routes left-sidebar interactions directly to file-explorer operations.

This should be split at the panel-content level:

- If sidebar content is `files`, preserve existing behavior
- If sidebar content is `agent_history`, route keys and clicks to history navigation/activation helpers

Needed V1 interactions:

- Up/down selection
- Enter activate
- Mouse click select
- Double-click activate
- Scroll wheel scroll list
- Escape unfocus

### Renderer

`src/renderer/file_explorer_renderer.zig` remains the left-panel renderer, but it needs a content-mode branch:

- File mode renders current file explorer exactly as today
- Agent history mode renders:
  - `AGENT History` header
  - rows with session title
  - secondary metadata line if space allows, preferably model or last-updated text

The visual style should stay consistent with the existing explorer:

- Same row height system
- Same hover/selected backgrounds
- Same width and resize behavior

## Persistence Timing

To reduce data loss without introducing excessive churn:

- Create/save the record when a new AI session is opened
- Save after user submit appends a new user message
- Save after request completion appends or updates the assistant message
- Save when clearing messages
- Save on tab/window shutdown as a final sync

The writes can be synchronous in V1 if the data size remains modest, but the code should be structured so async/debounced saves are possible later.

## Failure Handling

If history load fails:

- Start with an empty history list
- Log the parse/load failure to stderr
- Do not block AI chat from opening

If saving fails:

- Keep the in-memory session alive
- Log the error
- Optionally surface a short sidebar/status message later, but not required for V1

If a persisted session references malformed message data:

- Skip malformed fields when possible
- Preserve the rest of the session
- Never crash startup over a single bad history row

## Files To Change

Expected primary write scope:

- `src/ai_chat.zig`
- `src/agent_history.zig` (new)
- `src/appwindow/tab.zig`
- `src/AppWindow.zig`
- `src/file_explorer.zig`
- `src/renderer/file_explorer_renderer.zig`
- `src/input.zig`
- `src/test_main.zig`

Possible tests:

- `src/agent_history.zig` unit tests for load/save/normalize/sort
- `src/ai_chat.zig` tests for serializing/deserializing session content
- input-level tests only if existing patterns support them cleanly

## Testing Strategy

### Unit Tests

- Persist a session with multiple messages and load it back
- Verify newest `updated_at` sorts first
- Verify reopening an existing `session_id` does not duplicate it
- Verify malformed JSON falls back safely
- Verify clear-messages updates the stored session rather than leaving stale content

### Manual Validation

1. Open an AI/Agent tab
2. Send several turns
3. Close the AI tab
4. Open another AI tab and toggle the left sidebar
5. Confirm the old conversation appears in history
6. Activate it and confirm the full transcript is restored
7. Send another turn and confirm the same history record updates
8. Quit Phantty and relaunch
9. Open an AI/Agent tab and toggle the left sidebar
10. Confirm the prior history still exists

## Scope Check

This spec is intentionally limited to persistent global AI/Agent history and left-sidebar access. It does not include session search, deletion, pinning, or automatic AI-tab restore on app startup.
