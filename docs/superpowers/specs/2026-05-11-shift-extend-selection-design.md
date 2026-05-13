# Shift+Click Extends Selection — Design

## Context

Phantty's mouse selection supports plain click, drag, 1-to-4 multi-click (char/word/sentence/paragraph), and Shift+click range extension. The mouse-event struct carries Shift/Ctrl/Alt modifier flags, and the terminal left-button path in `src/input.zig` uses a Shift-only gate to distinguish range extension from the normal click-count path.

The original gap was that a user who selected "Hello", realized they wanted "Hello world", and Shift+clicked on "d" lost the original anchor: the click was treated as a fresh selection at "d". The current implementation keeps a click anchor even when there is no visible selection yet, so click A then Shift+click B selects A..B.

This spec documents the implemented standard "Shift+click extends current selection" behavior, plus the same for Shift+drag.

## Goals

- `Shift+left-click` extends from the **last click position** (already stored as `selection.start_col/row` because every click writes it, even a plain single click that hasn't dragged yet) to the cell of this click. The user's primary use case is: click character A, hold Shift, click character B → highlight A..B.
- `Shift+left-drag` extends continuously while the mouse moves with Shift held (auto-falls-out of the click case — no extra wiring).
- Be a strict superset of current behavior: no scenario without Shift behaves differently.
- Use one explicit `Selection.has_anchor` bit so anchor-only clicks are distinct from active selections. No extra click-tracking globals.

## Non-Goals

- **Multi-click mode preservation.** Shift+click after a double-click word selection extends by character, not by word. Adding word/sentence/paragraph-aware extension is deferred to v2 and would require a new `Selection.mode` field plus boundary helpers.
- **Keyboard selection extension** (Shift+arrow keys). Out of scope; deferred to v2.
- **Shift+click before any Phantty anchor exists** using the terminal cursor as an implicit anchor. The terminal cursor is a moving target driven by the PTY; if `has_anchor=false`, Shift+click falls back to the normal single-click selection start.
- **Ctrl+Shift+click** range extension. The implemented range extension is Shift-only (`ev.shift and !ev.ctrl and !ev.alt`). Ctrl+click URL/preview opening remains Ctrl-only, and Ctrl+Shift+click falls through to the normal click-count selection path.

## Surveyed Facts (load-bearing)

| Fact | Location |
|---|---|
| `Selection { has_anchor, start_col, start_row, end_col, end_row, active }` per-Surface | `src/Surface.zig:36-44` |
| Mouse button down handler dispatches on click count 1-4 | `src/input.zig:2166+` (`handleMouseButton`) |
| Shift-only range selection bypasses `nextLeftClickCount` and uses synthetic count 1 | `src/input.zig:2491-2495` |
| Drag extends `selection.end_*` while `g_selecting=true` | `src/input.zig:3030-3056` (`updateDragSelection`) |
| Click count tracked via `g_left_click_count` + 500 ms / one-cell-distance gate | `src/input.zig:336`, `1596-1612` |
| Mouse event carries `ctrl/shift/alt: bool` populated via `GetKeyState` | `src/apprt/win32.zig:724-731`, `1283-1299` |
| `markSelectionChanged()` invalidates render cache | `src/input.zig:1591-1594` |
| Ctrl+left-click is taken (URL/preview); Shift-only left-click is range selection | `src/input.zig:2484-2501` |

## Behavior Contract

The full matrix of input → behavior. Rows in **bold** are new; everything else is unchanged.

| Input | Shift held | Behavior |
|---|---|---|
| Left-click | no | Unchanged: `start=end=clicked`, `active=false`, `g_selecting=true`, increment click count |
| Left-drag | no | Unchanged: `end` follows mouse; `active=true` once movement exceeds threshold |
| Double / triple / quad-click | no | Unchanged: select word / sentence / paragraph |
| **Shift+left-click with an anchor** | **yes, Ctrl/Alt not held** | **`end=clicked`, `start` unchanged (the anchor), `active=!same_cell`, `g_selecting=true`, drag origin updated to this click, left-click tracker reset to 0. The active selection is now `start..clicked` unless the click is on the anchor cell.** |
| **Shift+left-click without an anchor** | **yes, Ctrl/Alt not held** | **Falls back to normal single-click selection start: `start=end=clicked`, `has_anchor=true`, `active=false`, `g_selecting=true`.** |
| **Shift+left-drag** | **yes, Ctrl/Alt not held** | **Automatic: Shift+click sets `g_selecting=true`, then existing drag handling carries `end` to mouse position even after Shift is released mid-drag. Without an existing anchor it behaves like a normal drag starting at the mouse-down cell.** |
| Shift+double/triple-click | yes, Ctrl/Alt not held | Shift-only range selection never calls `nextLeftClickCount`; repeated Shift+clicks keep extending by character instead of entering word/sentence/paragraph modes |
| Ctrl+Shift+click | yes | Falls through to the normal click-count selection path; it does not extend selection and does not trigger Ctrl-only URL/preview opening |

**The pure user flow this enables**: plain click on `H`, then plain Shift+click on `d`. Step 1 writes `start=H, end=H, active=false`. Step 2 sets `end=d, active=true` while leaving `start=H` alone. Highlight is `Hello world`. No drag needed at any step.

### Edge case: Shift+click before any anchor exists

A fresh `Selection` initializes `has_anchor=false`. If the user's first ever interaction is Shift+click, `extendSelectionAtCell` returns `false` and the click falls back to `startSelectionAtCell`. The result is a normal anchor-only click at the clicked cell (`active=false`), not a visually surprising selection from cell (0, 0).

### Why multi-click counter resets to 0 on Shift+click

If the count is left intact, a plain click in the same vicinity within 500 ms after Shift+click would be treated as the second click of a sequence and trigger word selection — destroying the just-extended range. The implementation calls `resetLeftClickCount()` and uses a synthetic `click_count = 1` for the Shift-click dispatch. The next plain click computes both gates as false (because they require `g_left_click_count > 0`), resets cleanly, and behaves as a fresh first click of a new sequence.

### Reverse selection (anchor right of click)

Not special-cased. The renderer already normalizes min/max for highlight extent (otherwise reverse drag would not work today). We only mutate `end_col` / `end_row`; the renderer handles the rest.

## Implementation

Current implementation in `src/input.zig` `handleMouseButton`, folded into the existing left-down dispatch on click count:

```zig
const shift_range_select = ev.shift and !ev.ctrl and !ev.alt;
const click_count: u8 = if (shift_range_select) blk: {
    resetLeftClickCount();
    break :blk 1;
} else nextLeftClickCount(xpos, ypos);
switch (click_count) {
    1 => {
        // Shift-click extends from the last click anchor, matching
        // document editor style range selection.
        if (!(shift_range_select and extendSelectionAtCell(clicked_surface, cell_pos, xpos, ypos))) {
            startSelectionAtCell(clicked_surface, cell_pos, xpos, ypos);
        }
    },
    // existing multi-click cases follow
}
```

Why `resetLeftClickCount()` (not `g_left_click_count = 1`): `nextLeftClickCount` checks `g_left_click_count > 0` for both the time and distance gates. Resetting to 0 makes both gates false on the next click, so the next plain click — even within 500 ms and within one cell — increments to 1 and behaves as a fresh first-click. This guarantees a plain click after Shift+click never accidentally triggers double-click word-selection.

`extendSelectionAtCell` is intentionally guarded by `selection.has_anchor`. When it returns `false`, the same click falls back to `startSelectionAtCell`, which creates an anchor-only click and preserves normal recovery behavior.

`cell_pos` is derived from `xpos` / `ypos` and the current clicked surface before the Shift-only branch.

Placement constraint: the Shift-only branch must sit **after** any PTY-mouse-passthrough check (so vim/tmux mouse mode still gets the event when their app is active) and **before** the multi-click dispatch.

`handleMouseMove` delegates drag updates to `updateDragSelection`. Once `g_selecting=true`, the existing drag path moves `end_col` / `end_row` with the mouse — Shift+drag is therefore automatic. Shift may even be released mid-drag and the drag continues, matching VSCode behavior.

The `Selection` struct has one anchor bit: `has_anchor`. No new click-tracking globals are needed.

## Invariants

| # | Invariant | Enforcement |
|---|---|---|
| I1 | A non-Shift mouse interaction behaves identically to before this change | Only the Shift-only path bypasses `nextLeftClickCount`; non-Shift input still uses the normal click-count dispatch |
| I2 | A Shift+click before any prior Phantty anchor never crashes or creates a bogus 0,0 selection | `extendSelectionAtCell` returns false when `has_anchor=false`; the click falls back to `startSelectionAtCell` |
| I3 | After Shift+click, a follow-up plain click in the same area is not misread as a double-click | `resetLeftClickCount()` clears count/time/position before the Shift-click dispatch |
| I4 | Reverse selections (`end` before `start`) keep working | We only write `end_*`; renderer already handles min/max |
| I5 | PTY mouse passthrough (vim/tmux) keeps working | Shift branch is inserted after the existing passthrough check |

## Test Strategy

### No unit tests

`handleMouseButton` is tightly coupled to `Surface`, PTY state, and module-level globals. Extracting a pure function for the small routing branch would be over-engineering; the test would mock everything that matters and verify essentially the literal source. The manual checklist below is the acceptance test.

### Manual verification (`acceptance test`)

Tester: user, on Windows. Failing any step blocks merge.

1. Launch `phantty.exe`, shell prompts, run `echo "Hello world"`.
2. **Baseline.** Plain drag from `H` to `d` → highlights `Hello world`. (Confirms existing drag still works.)
3. **Shift+click extends from a plain click (the headline use case).** Plain click on `H` (no drag). Hold Shift and click on `d` → highlight is `Hello world`.
4. **Shift+click extends from a drag.** Plain drag from `H` to `o`, release. Hold Shift and click on `d` → highlight is `Hello world`.
5. **Shift+drag extends.** Plain click on `H`, then hold Shift and drag from anywhere to `d` → highlight is `Hello world`. Release Shift mid-drag and continue moving → highlight keeps following the mouse.
6. **No-prior-anchor edge case.** Open a fresh tab, no prior terminal click. Hold Shift and click on `H` → no crash and no visible 0,0-based selection; this creates an anchor-only click at `H`. Shift+click `d` next → highlight is `Hello world`.
7. **Multi-click not poisoned.** Do a Shift+click anywhere, immediately do a plain double-click on a word elsewhere → that word is selected (not misinterpreted as the second click of a sequence).
8. **Shift multi-click suppression.** Plain click `H`, then rapidly Shift+double-click near `d` → selection extends by character; it does not enter word/sentence selection mode while Shift-only range select is active.
9. **Ctrl+Shift does not extend.** Plain click `H`, then Ctrl+Shift+click `d` → behaves like the normal click-count selection path, not range extension.
10. **Reverse selection extends.** Drag from `d` backward to `o` (end is left of start). Release. Shift+click on `H` → highlight is `Hello world` (renderer normalizes min/max).
11. **Clipboard sanity.** After any of steps 3, 4, 5, 10, press `Ctrl+Shift+C` → clipboard contents exactly equal the highlighted text.

### Out of scope for verification

- WSL surfaces (selection is a Phantty concern, not a remote shell concern).
- Cross-platform drag behavior (Phantty is Windows-only).
- Performance — the added routing and helper calls are trivial compared with rendering and PTY IO.

## Risks

- **PTY passthrough placement.** If the Shift branch is accidentally moved before the mouse-passthrough check, vim/tmux users would lose Shift+click in their apps. Keep the Shift-only branch after passthrough handling.
- **Anchor state drift.** Selection helpers that establish a valid anchor must keep setting `selection.has_anchor=true`; otherwise Shift+click will fall back to plain click.
- **Reverse selection assumption.** This spec assumes the cell renderer normalizes min/max for highlight extent. If it does not, reverse Shift+click could draw an empty or inverted highlight. Behavior is the same as today's reverse drag, so if reverse drag works, this works.

## Future Work

- v2: `Selection.mode = { char, word, sentence, paragraph }` + boundary helpers, so Shift+click after a double-click word extends by word.
- v2: `Shift+arrow` keyboard extension. Currently `Alt+arrow` is split focus; `Shift+arrow` is unbound for terminal input only at modifier=2 (`\x1b[1;2A` etc.) which most apps interpret as cursor-with-shift, but a Phantty-level "extend selection" pre-empt would require care to not break those apps.
- v2: Drag-and-extend across multi-click selections (e.g., double-click a word to enter word mode, then Shift+click extends to the word at the cursor).
