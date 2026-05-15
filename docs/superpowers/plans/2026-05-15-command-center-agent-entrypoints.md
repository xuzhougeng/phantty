# Command Center Agent Entrypoints Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `New Agent` and `Select Agent History` command-center actions so AI/Agent workflows can be launched or resumed directly from `Ctrl+Shift+P`.

**Architecture:** Extend the command-center overlay with two new actions and a small agent-history picker subview. Reuse the existing AI session launcher for `New Agent`, and reuse the persisted agent-history runtime plus `session_id` reopen helper for `Select Agent History`.

**Tech Stack:** Zig 0.15.2, existing `src/renderer/overlays.zig` command-center state, `AppWindow` AI/history runtime helpers, existing input routing in `src/input.zig`.

---

## File Structure

- Modify: `src/renderer/overlays.zig`
  - Add the two command-center actions, history-picker state, rendering, selection, and execution logic.
- Modify: `src/AppWindow.zig`
  - Add minimal helpers for command-center history row sync and command-center `New Agent` launcher entry if needed.
- Modify: `src/input.zig`
  - Route command-center key handling into the history-picker subview and back.
- Modify: `src/agent_history.zig` only if a small row helper is cleaner than duplicating projection logic.
- Test: `src/renderer/overlays.zig`

### Task 1: Add Command-Center Actions And History Picker State

**Files:**
- Modify: `src/renderer/overlays.zig`
- Test: `src/renderer/overlays.zig`

- [ ] **Step 1: Write the failing tests**

Add tests in `src/renderer/overlays.zig` for:

```zig
test "command center includes New Agent action" {
    try std.testing.expect(findCommandPaletteAction("New Agent") != null);
}

test "command center includes Select Agent History action" {
    try std.testing.expect(findCommandPaletteAction("Select Agent History") != null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`

Expected: FAIL because the new command-center actions do not exist yet.

- [ ] **Step 3: Add the new command-center actions and picker state**

In `src/renderer/overlays.zig`:

- add two new command actions:
  - `new_agent`
  - `select_agent_history`
- add picker-mode state such as:
  - `g_command_palette_agent_history_visible: bool`
  - `g_command_palette_agent_history_selected: usize`
  - optional scroll state if needed
- ensure the normal command list and the history-picker subview are distinct modes

If needed, add a small helper:

```zig
fn findCommandPaletteAction(title: []const u8) ?CommandPaletteAction { ... }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`

Expected: PASS for the new command-action presence tests.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/overlays.zig
git commit -m "feat: add command center agent entrypoints"
```

### Task 2: Wire New Agent To The Existing AI Launcher

**Files:**
- Modify: `src/renderer/overlays.zig`
- Possibly modify: `src/AppWindow.zig`
- Test: `src/renderer/overlays.zig`

- [ ] **Step 1: Write the failing test**

Add a focused test in `src/renderer/overlays.zig`:

```zig
test "command center New Agent opens the AI launcher in agent-oriented mode" {
    resetOverlayStateForTest();
    executeCommandPaletteActionForTest(.new_agent);
    try std.testing.expect(sessionLauncherVisible());
    try std.testing.expect(sessionLauncherDefaultsToAgentForTest());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`

Expected: FAIL because the action does not yet open the launcher in Agent mode.

- [ ] **Step 3: Implement the New Agent execution path**

In `src/renderer/overlays.zig`, route `.new_agent` to the existing AI profile/session launcher path.

If the current launcher lacks a direct way to default to Agent mode, add the minimal focused state necessary, for example:

```zig
pub fn sessionLauncherOpenAgentDefault() void { ... }
```

The result must be:

- command center closes
- existing AI launcher opens
- launcher focus defaults to the Agent-oriented entry

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`

Expected: PASS for the new launcher-default test.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/overlays.zig src/AppWindow.zig
git commit -m "feat: add New Agent command center shortcut"
```

### Task 3: Add Command-Center Agent History Picker And Reopen Flow

**Files:**
- Modify: `src/renderer/overlays.zig`
- Modify: `src/AppWindow.zig`
- Possibly modify: `src/agent_history.zig`
- Test: `src/renderer/overlays.zig`

- [ ] **Step 1: Write the failing tests**

Add tests in `src/renderer/overlays.zig` for:

```zig
test "Select Agent History enters command-center history picker mode" {
    resetOverlayStateForTest();
    executeCommandPaletteActionForTest(.select_agent_history);
    try std.testing.expect(commandPaletteAgentHistoryVisibleForTest());
}

test "agent history picker selects newest history row first" {
    resetOverlayStateForTest();
    seedCommandPaletteAgentHistoryForTest(&.{
        .{ .session_id = "older", .title = "Older", .updated_at = 10 },
        .{ .session_id = "newer", .title = "Newer", .updated_at = 20 },
    });
    openCommandPaletteAgentHistoryForTest();
    try std.testing.expectEqualStrings("newer", commandPaletteSelectedAgentHistorySessionIdForTest().?);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`

Expected: FAIL because the picker mode and row ordering do not exist yet.

- [ ] **Step 3: Implement the command-center history picker**

In `src/renderer/overlays.zig`:

- add a command-center subview for agent history
- source rows from the runtime history store via an `AppWindow` helper
- sort newest first
- default selection to the first row
- render command-center-native rows, not file-explorer rows

In `src/AppWindow.zig`, add the minimal helper needed to project the current runtime history rows for the command center, for example:

```zig
pub fn snapshotAgentHistoryRowsForCommandPalette(allocator: std.mem.Allocator) ![]agent_history.Row { ... }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`

Expected: PASS for picker-mode and newest-first selection tests.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/overlays.zig src/AppWindow.zig src/agent_history.zig
git commit -m "feat: add command center agent history picker"
```

### Task 4: Route Keyboard Interaction Inside The History Picker

**Files:**
- Modify: `src/renderer/overlays.zig`
- Modify: `src/input.zig`
- Test: `src/renderer/overlays.zig`

- [ ] **Step 1: Write the failing tests**

Add tests in `src/renderer/overlays.zig` for:

```zig
test "agent history picker keyboard moves selection" {
    resetOverlayStateForTest();
    seedCommandPaletteAgentHistoryForTest(&.{
        .{ .session_id = "a", .title = "A", .updated_at = 30 },
        .{ .session_id = "b", .title = "B", .updated_at = 20 },
    });
    openCommandPaletteAgentHistoryForTest();
    commandPaletteAgentHistoryMoveForTest(1);
    try std.testing.expectEqualStrings("b", commandPaletteSelectedAgentHistorySessionIdForTest().?);
}

test "agent history picker escape returns to command list mode" {
    resetOverlayStateForTest();
    openCommandPaletteAgentHistoryForTest();
    closeCommandPaletteAgentHistoryForTest();
    try std.testing.expect(!commandPaletteAgentHistoryVisibleForTest());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`

Expected: FAIL because the picker navigation helpers do not yet exist.

- [ ] **Step 3: Implement key routing**

In `src/input.zig`, while the command center is visible:

- if agent-history picker mode is active:
  - `Up` -> move selection up
  - `Down` -> move selection down
  - `Enter` -> activate selected history
  - `Esc` -> return to normal command-center mode
- otherwise preserve normal command-center behavior

Keep the picker state transitions inside `src/renderer/overlays.zig` helpers.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`

Expected: PASS for picker navigation and escape-return tests.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/overlays.zig src/input.zig
git commit -m "feat: add command center history picker navigation"
```

### Task 5: Activate History Rows Through Existing Runtime Reopen Logic

**Files:**
- Modify: `src/renderer/overlays.zig`
- Modify: `src/AppWindow.zig`
- Test: `src/renderer/overlays.zig`

- [ ] **Step 1: Write the failing test**

Add a focused activation test in `src/renderer/overlays.zig`:

```zig
test "agent history picker activation uses session_id reopen helper" {
    resetOverlayStateForTest();
    seedCommandPaletteAgentHistoryForTest(&.{
        .{ .session_id = "session-1", .title = "Saved", .updated_at = 20 },
    });
    openCommandPaletteAgentHistoryForTest();
    triggerCommandPaletteAgentHistoryActivateForTest();
    try std.testing.expectEqualStrings("session-1", lastReopenedAgentHistorySessionIdForTest().?);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`

Expected: FAIL because activation is not yet wired through the reopen helper.

- [ ] **Step 3: Implement activation**

In `src/renderer/overlays.zig`, activation of the selected history row should call:

```zig
AppWindow.reopenAiChatTabFromHistorySessionId(session_id)
```

Behavior:

- if already open, switch to that tab
- otherwise reopen the persisted conversation
- command center closes after successful activation

If a small test hook is needed in `src/AppWindow.zig`, keep it narrow and local
to existing patterns.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`

Expected: PASS for the activation/reopen test.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/overlays.zig src/AppWindow.zig
git commit -m "feat: reopen agent history from command center"
```

### Task 6: Final Verification

**Files:**
- No code changes expected unless verification finds bugs

- [ ] **Step 1: Run desktop unit tests**

Run: `zig build test`

Expected: PASS.

- [ ] **Step 2: Run desktop build**

Run: `zig build`

Expected: PASS.

- [ ] **Step 3: Run remote client tests to verify release/version surfaces remain healthy**

Run: `npm run test`

Working directory: `remote/`

Expected: PASS.

- [ ] **Step 4: Manual validation checklist**

1. Open command center with `Ctrl+Shift+P`
2. Select `New Agent`
3. Confirm the existing AI launcher opens and defaults to Agent-oriented flow
4. Open command center again
5. Select `Select Agent History`
6. Confirm a command-center-native history list appears, not the sidebar
7. Press `Esc` and confirm the normal command list returns
8. Reopen `Select Agent History`
9. Select a currently open saved session and confirm the app switches to that tab
10. Select a saved session that is not open and confirm the session reopens

- [ ] **Step 5: Final commit if verification required fixes**

```bash
git add src/renderer/overlays.zig src/input.zig src/AppWindow.zig src/agent_history.zig
git commit -m "test: verify command center agent entrypoints"
```
