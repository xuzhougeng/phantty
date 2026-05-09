# Remote Mobile Console Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the approved iPhone/mobile remote console layout with a terminal-first viewport, reliable selected-surface input, and a compact terminal utility keyboard.

**Architecture:** Keep all behavior in `remote/src/client`; do not change the relay protocol, server routes, or Zig remote client. Add small testable helper modules for mobile layout decisions and input sequences, then wire them into `surfaces.ts`, `vkbd.ts`, and `views/console.ts`. Use CSS media queries for the mobile shell while keeping desktop layout behavior intact.

**Tech Stack:** TypeScript, Vite, xterm.js, `@xterm/addon-fit`, Node test runner through `tsx`, CSS media queries, existing WebSocket relay client.

---

## Scope Notes

The approved spec is `docs/superpowers/specs/2026-05-09-remote-mobile-console-design.md`.

`AGENTS.md` now states that `remote/` does not need Ghostty comparison. This plan follows the existing `remote/` architecture and browser/mobile constraints.

## File Structure

- Create `remote/src/client/mobile_layout.ts`: pure layout decisions plus the browser media-query helper.
- Create `remote/src/client/input_sequences.ts`: pure terminal key/text sequence helpers used by the virtual keyboard.
- Create `remote/src/client/mobile_text_input.ts`: hidden mobile text input bridge for iOS/native keyboard text entry.
- Create `remote/test/client/mobile_layout.test.ts`: Node test coverage for mobile fit decisions.
- Create `remote/test/client/input_sequences.test.ts`: Node test coverage for terminal key sequence helpers.
- Modify `remote/package.json`: add a client test script.
- Modify `remote/src/client/main.ts`: register the text input sender.
- Modify `remote/src/client/views/console.ts`: render and bind the hidden text input, bind viewport refits, keep drawer/keyboard state source of truth.
- Modify `remote/src/client/surfaces.ts`: use viewport fitting on mobile, keep remote-grid geometry on desktop, focus the text bridge on mobile terminal taps.
- Modify `remote/src/client/vkbd.ts`: use shared sequence helpers and route Type through the text bridge.
- Modify `remote/src/client/styles/responsive.css`: implement the terminal-first mobile shell and selected-surface chrome.
- Modify `remote/src/client/styles/vkbd.css`: make the utility keyboard compact and touch-stable.

## Tasks

### Task 1: Add Mobile Layout Helper And Test Script

**Files:**
- Modify: `remote/package.json`
- Create: `remote/src/client/mobile_layout.ts`
- Create: `remote/test/client/mobile_layout.test.ts`

- [ ] **Step 1: Add the failing mobile layout test and test script**

In `remote/package.json`, add this script after `preview`:

```json
"test:client": "node --import tsx --test test/client/*.test.ts",
```

The `scripts` section should include:

```json
"preview": "vite preview --host 127.0.0.1",
"test:client": "node --import tsx --test test/client/*.test.ts",
"deploy": "npm run build && wrangler deploy",
```

Create `remote/test/client/mobile_layout.test.ts`:

```ts
import test from "node:test";
import assert from "node:assert/strict";

import {
  MOBILE_REMOTE_MEDIA_QUERY,
  fitModeForSurface,
  shouldUseViewportFit,
} from "../../src/client/mobile_layout";

test("mobile media query matches the responsive CSS breakpoint", () => {
  assert.equal(
    MOBILE_REMOTE_MEDIA_QUERY,
    "(max-width: 860px), (pointer: coarse) and (max-width: 1024px)",
  );
});

test("fitModeForSurface uses viewport fitting on mobile", () => {
  assert.equal(fitModeForSurface(true), "viewport");
});

test("fitModeForSurface preserves remote-grid sizing on desktop", () => {
  assert.equal(fitModeForSurface(false), "remote-grid");
});

test("shouldUseViewportFit is true only for mobile surfaces", () => {
  assert.equal(shouldUseViewportFit(true), true);
  assert.equal(shouldUseViewportFit(false), false);
});
```

- [ ] **Step 2: Run the new test and verify it fails**

Run:

```bash
cd remote
npm run test:client
```

Expected: FAIL with an import error for `../../src/client/mobile_layout`.

- [ ] **Step 3: Add the mobile layout helper**

Create `remote/src/client/mobile_layout.ts`:

```ts
export const MOBILE_REMOTE_MEDIA_QUERY =
  "(max-width: 860px), (pointer: coarse) and (max-width: 1024px)";

export type SurfaceFitMode = "remote-grid" | "viewport";

export function fitModeForSurface(isMobile: boolean): SurfaceFitMode {
  return isMobile ? "viewport" : "remote-grid";
}

export function shouldUseViewportFit(isMobile: boolean): boolean {
  return fitModeForSurface(isMobile) === "viewport";
}

export function isMobileRemoteShell(win: Pick<Window, "matchMedia"> = window): boolean {
  return win.matchMedia(MOBILE_REMOTE_MEDIA_QUERY).matches;
}
```

- [ ] **Step 4: Run the test and verify it passes**

Run:

```bash
cd remote
npm run test:client
```

Expected: PASS with 4 passing subtests.

- [ ] **Step 5: Commit Task 1**

```bash
git add remote/package.json remote/src/client/mobile_layout.ts remote/test/client/mobile_layout.test.ts
git commit -m "test remote mobile layout helpers"
```

### Task 2: Fit The Selected Surface To The Mobile Viewport

**Files:**
- Modify: `remote/src/client/surfaces.ts`
- Modify: `remote/src/client/views/console.ts`
- Test: `remote/test/client/mobile_layout.test.ts`

- [ ] **Step 1: Add a test for mobile viewport fitting behavior**

Append to `remote/test/client/mobile_layout.test.ts`:

```ts
test("mobile viewport fitting ignores remote grid dimensions", () => {
  assert.equal(shouldUseViewportFit(true), true);
});

test("desktop rendering keeps remote grid dimensions", () => {
  assert.equal(shouldUseViewportFit(false), false);
});
```

- [ ] **Step 2: Run the test**

Run:

```bash
cd remote
npm run test:client
```

Expected: PASS. The test documents the behavior before wiring it into xterm fitting.

- [ ] **Step 3: Update `surfaces.ts` imports**

In `remote/src/client/surfaces.ts`, add:

```ts
import { isMobileRemoteShell, shouldUseViewportFit } from "./mobile_layout";
```

- [ ] **Step 4: Replace duplicated fit logic with `fitOrResize`**

In `remote/src/client/surfaces.ts`, add this helper above `scheduleFit`:

```ts
function fitOrResize(view: SurfaceView): void {
  const useViewportFit = shouldUseViewportFit(isMobileRemoteShell());
  if (!useViewportFit && view.remoteCols && view.remoteRows) {
    if (view.term.cols !== view.remoteCols || view.term.rows !== view.remoteRows) {
      view.term.resize(view.remoteCols, view.remoteRows);
    }
    return;
  }

  view.fit.fit();
}
```

Then replace the body of the `try` block inside `scheduleFit` with:

```ts
fitOrResize(view);
view.term.refresh(0, Math.max(0, view.term.rows - 1));
```

Then replace the fit/resize `try` block inside `applyInitialSnapshot` with:

```ts
try {
  fitOrResize(view);
} catch {
  // xterm can briefly report zero-sized panels while layout is settling.
}
```

- [ ] **Step 5: Bind viewport refits in `console.ts`**

In `remote/src/client/views/console.ts`, add this module-level flag near the imports:

```ts
let viewportRefitBound = false;
```

Add this function near `bindMobileChrome`:

```ts
function bindViewportRefit(): void {
  if (viewportRefitBound) return;
  viewportRefitBound = true;

  const refit = (): void => {
    refitAllSurfaces();
  };

  window.addEventListener("resize", refit, { passive: true });
  window.visualViewport?.addEventListener("resize", refit);
  window.visualViewport?.addEventListener("scroll", refit);
}
```

Call it in `renderConsole` after `bindMobileChrome();`:

```ts
bindMobileChrome();
bindViewportRefit();
bindVirtualKeyboard(() => setKbdVisible(false));
```

Update `setKbdVisible` so fitting runs after the grid row changes:

```ts
function setKbdVisible(visible: boolean): void {
  state.kbdVisible = visible;
  saveKbdVisible(visible);
  const shell = document.querySelector<HTMLElement>(".console-shell");
  if (shell) shell.dataset.kbdVisible = String(visible);
  requestAnimationFrame(() => refitAllSurfaces());
}
```

- [ ] **Step 6: Verify Task 2**

Run:

```bash
cd remote
npm run test:client
npm run typecheck
```

Expected: both commands pass.

- [ ] **Step 7: Commit Task 2**

```bash
git add remote/src/client/surfaces.ts remote/src/client/views/console.ts remote/test/client/mobile_layout.test.ts
git commit -m "fit remote surfaces to mobile viewport"
```

### Task 3: Extract Terminal Input Sequence Helpers

**Files:**
- Create: `remote/src/client/input_sequences.ts`
- Create: `remote/test/client/input_sequences.test.ts`
- Modify: `remote/src/client/vkbd.ts`

- [ ] **Step 1: Add the failing input sequence tests**

Create `remote/test/client/input_sequences.test.ts`:

```ts
import test from "node:test";
import assert from "node:assert/strict";

import {
  applyStickyMods,
  ctrlLetter,
  keyToSequence,
} from "../../src/client/input_sequences";

test("keyToSequence returns terminal escape sequences for special keys", () => {
  assert.equal(keyToSequence("esc"), "\x1b");
  assert.equal(keyToSequence("tab"), "\t");
  assert.equal(keyToSequence("up"), "\x1b[A");
  assert.equal(keyToSequence("down"), "\x1b[B");
  assert.equal(keyToSequence("right"), "\x1b[C");
  assert.equal(keyToSequence("left"), "\x1b[D");
  assert.equal(keyToSequence("bksp"), "\x7f");
  assert.equal(keyToSequence("enter"), "\r");
  assert.equal(keyToSequence("unknown"), null);
});

test("ctrlLetter maps letters to C0 control characters", () => {
  assert.equal(ctrlLetter("a"), "\x01");
  assert.equal(ctrlLetter("c"), "\x03");
  assert.equal(ctrlLetter("z"), "\x1a");
  assert.equal(ctrlLetter("1"), null);
});

test("applyStickyMods applies ctrl and alt to single characters", () => {
  assert.equal(applyStickyMods("c", { ctrl: true, alt: false }), "\x03");
  assert.equal(applyStickyMods("x", { ctrl: false, alt: true }), "\x1bx");
  assert.equal(applyStickyMods("/", { ctrl: true, alt: false }), "/");
  assert.equal(applyStickyMods("long", { ctrl: true, alt: true }), "long");
});
```

- [ ] **Step 2: Run the test and verify it fails**

Run:

```bash
cd remote
npm run test:client
```

Expected: FAIL with an import error for `../../src/client/input_sequences`.

- [ ] **Step 3: Add `input_sequences.ts`**

Create `remote/src/client/input_sequences.ts`:

```ts
export type StickyMods = { ctrl: boolean; alt: boolean };

export function ctrlLetter(letter: string): string | null {
  const lower = letter.toLowerCase();
  if (lower.length !== 1 || lower < "a" || lower > "z") return null;
  return String.fromCharCode(lower.charCodeAt(0) - 96);
}

export function applyStickyMods(text: string, mods: StickyMods): string {
  if (mods.ctrl && text.length === 1) {
    return ctrlLetter(text) ?? text;
  }
  if (mods.alt && text.length === 1) {
    return `\x1b${text}`;
  }
  return text;
}

export function keyToSequence(key: string): string | null {
  switch (key) {
    case "esc":
      return "\x1b";
    case "tab":
      return "\t";
    case "up":
      return "\x1b[A";
    case "down":
      return "\x1b[B";
    case "right":
      return "\x1b[C";
    case "left":
      return "\x1b[D";
    case "bksp":
      return "\x7f";
    case "enter":
      return "\r";
    default:
      return null;
  }
}
```

- [ ] **Step 4: Refactor `vkbd.ts` to use the helper**

In `remote/src/client/vkbd.ts`, add:

```ts
import { applyStickyMods, ctrlLetter, keyToSequence } from "./input_sequences";
```

Replace the `vkCtrl` block with:

```ts
if (button.dataset.vkCtrl) {
  const seq = ctrlLetter(button.dataset.vkCtrl);
  if (seq) sender(surfaceId, seq);
  clearStickyMods();
  return;
}
```

Replace the `vkText` block with:

```ts
if (button.dataset.vkText !== undefined) {
  const text = applyStickyMods(button.dataset.vkText, kbdMods);
  sender(surfaceId, text);
  clearStickyMods();
  return;
}
```

Remove the local `keyToSequence` function from `vkbd.ts`.

- [ ] **Step 5: Verify Task 3**

Run:

```bash
cd remote
npm run test:client
npm run typecheck
```

Expected: both commands pass.

- [ ] **Step 6: Commit Task 3**

```bash
git add remote/src/client/input_sequences.ts remote/test/client/input_sequences.test.ts remote/src/client/vkbd.ts
git commit -m "share remote terminal input sequences"
```

### Task 4: Add The Mobile Text Input Bridge

**Files:**
- Create: `remote/src/client/mobile_text_input.ts`
- Modify: `remote/src/client/main.ts`
- Modify: `remote/src/client/views/console.ts`
- Modify: `remote/src/client/surfaces.ts`
- Modify: `remote/src/client/vkbd.ts`
- Modify: `remote/src/client/styles/vkbd.css`

- [ ] **Step 1: Create the mobile text input bridge**

Create `remote/src/client/mobile_text_input.ts`:

```ts
import { activeSurfaceIdForInput } from "./state";

type Sender = (surfaceId: string, data: string) => void;

let sender: Sender = () => {
  // no-op until transport registers
};

let inputEl: HTMLTextAreaElement | null = null;

export function setMobileTextInputSender(send: Sender): void {
  sender = send;
}

export function renderMobileTextInputMarkup(): string {
  return `
    <textarea
      id="mobile-text-input"
      class="mobile-text-input"
      aria-label="Terminal text input"
      autocomplete="off"
      autocapitalize="off"
      autocorrect="off"
      spellcheck="false"
      rows="1"
    ></textarea>
  `;
}

export function bindMobileTextInput(): void {
  inputEl = document.querySelector<HTMLTextAreaElement>("#mobile-text-input");
  if (!inputEl) return;

  inputEl.addEventListener("beforeinput", (event) => {
    const inputEvent = event as InputEvent;
    if (inputEvent.inputType === "insertLineBreak") {
      event.preventDefault();
      dispatchText("\r");
      clearInputValue();
      return;
    }
    if (inputEvent.inputType === "deleteContentBackward") {
      event.preventDefault();
      dispatchText("\x7f");
      clearInputValue();
    }
  });

  inputEl.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      dispatchText("\r");
      clearInputValue();
      return;
    }
    if (event.key === "Backspace" && !inputEl?.value) {
      event.preventDefault();
      dispatchText("\x7f");
    }
  });

  inputEl.addEventListener("input", () => {
    if (!inputEl?.value) return;
    dispatchText(inputEl.value);
    clearInputValue();
  });

  inputEl.addEventListener("compositionend", () => {
    if (!inputEl?.value) return;
    dispatchText(inputEl.value);
    clearInputValue();
  });
}

export function focusMobileTextInput(): boolean {
  const input = inputEl ?? document.querySelector<HTMLTextAreaElement>("#mobile-text-input");
  if (!input) return false;
  inputEl = input;
  input.focus({ preventScroll: true });
  return document.activeElement === input;
}

function dispatchText(text: string): void {
  const surfaceId = activeSurfaceIdForInput();
  if (!surfaceId || !text) return;
  sender(surfaceId, text);
}

function clearInputValue(): void {
  if (inputEl) inputEl.value = "";
}
```

- [ ] **Step 2: Register the bridge sender in `main.ts`**

In `remote/src/client/main.ts`, add:

```ts
import { setMobileTextInputSender } from "./mobile_text_input";
```

Then add this next to the existing sender setup:

```ts
setMobileTextInputSender(sendInputBytes);
```

- [ ] **Step 3: Render and bind the bridge in `console.ts`**

In `remote/src/client/views/console.ts`, add:

```ts
import { bindMobileTextInput, renderMobileTextInputMarkup } from "../mobile_text_input";
```

Render it after the virtual keyboard:

```ts
${renderVirtualKeyboardMarkup()}
${renderMobileTextInputMarkup()}
```

Call the binder after `bindVirtualKeyboard(...)`:

```ts
bindVirtualKeyboard(() => setKbdVisible(false));
bindMobileTextInput();
```

- [ ] **Step 4: Route terminal taps and Type through the bridge**

In `remote/src/client/surfaces.ts`, add:

```ts
import { focusMobileTextInput } from "./mobile_text_input";
```

Replace the terminal click handler body with:

```ts
panel.addEventListener("click", () => {
  selectThis();
  if (!focusMobileTextInput()) ensureSurfaceView(surfaceId).term.focus();
});
```

Replace `focusAndFitSelectedSurface` with:

```ts
export function focusAndFitSelectedSurface(): void {
  const id = state.selectedSurfaceId;
  if (!id) return;
  const view = state.surfaceViews.get(id);
  if (!view) return;
  if (!focusMobileTextInput()) view.term.focus();
  scheduleFit(view);
}
```

In `remote/src/client/vkbd.ts`, add:

```ts
import { focusMobileTextInput } from "./mobile_text_input";
```

Replace the Type key block with:

```ts
if (button.dataset.vkKey === "type") {
  if (!focusMobileTextInput()) state.surfaceViews.get(surfaceId)?.term.focus();
  return;
}
```

- [ ] **Step 5: Style the hidden mobile text input**

Append to `remote/src/client/styles/vkbd.css`:

```css
.mobile-text-input {
  position: fixed;
  left: 0;
  bottom: 0;
  width: 1px;
  height: 1px;
  min-width: 1px;
  min-height: 1px;
  padding: 0;
  border: 0;
  opacity: 0.01;
  color: transparent;
  background: transparent;
  caret-color: transparent;
  resize: none;
  pointer-events: none;
  z-index: -1;
}
```

- [ ] **Step 6: Verify Task 4**

Run:

```bash
cd remote
npm run test:client
npm run typecheck
npm run build
```

Expected: all commands pass.

- [ ] **Step 7: Commit Task 4**

```bash
git add remote/src/client/mobile_text_input.ts remote/src/client/main.ts remote/src/client/views/console.ts remote/src/client/surfaces.ts remote/src/client/vkbd.ts remote/src/client/styles/vkbd.css
git commit -m "add remote mobile text input bridge"
```

### Task 5: Apply The Terminal-First Mobile CSS

**Files:**
- Modify: `remote/src/client/styles/responsive.css`
- Modify: `remote/src/client/styles/vkbd.css`

- [ ] **Step 1: Replace the phone/tablet mobile block**

In `remote/src/client/styles/responsive.css`, replace the first mobile block from:

```css
/* ─── Phone / tablet portrait ────────────────────────────────── */

@media (max-width: 860px), (pointer: coarse) and (max-width: 1024px) {
```

through the closing brace immediately before:

```css
/* ─── Foldable: dual-fold horizontal crease (top/bottom) ─────── */
```

with:

```css
/* ─── Phone / tablet portrait ────────────────────────────────── */

@media (max-width: 860px), (pointer: coarse) and (max-width: 1024px) {
  html,
  body,
  #app {
    overflow: hidden;
  }

  .console-shell {
    grid-template-columns: 1fr;
    grid-template-rows: minmax(0, 1fr);
    height: 100dvh;
  }

  .sidebar-backdrop {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.55);
    backdrop-filter: blur(2px);
    z-index: 80;
    animation: fade-in 200ms ease both;
  }

  .sidebar {
    position: fixed;
    top: 0;
    left: 0;
    bottom: 0;
    width: min(340px, 86vw);
    z-index: 90;
    transform: translateX(-102%);
    transition: transform 220ms cubic-bezier(0.2, 0.7, 0.2, 1);
    border-right: 1px solid var(--line);
    border-bottom: 0;
    box-shadow: var(--shadow-drawer);
  }

  .console-shell[data-drawer-open="true"] .sidebar {
    transform: translateX(0);
  }

  .sidebar-head .icon-button {
    display: grid;
  }

  .workspace {
    grid-column: 1;
    grid-row: 1;
    grid-template-rows: auto auto minmax(0, 1fr);
    min-height: 0;
  }

  .mobile-bar {
    display: flex;
    align-items: center;
    gap: 10px;
    min-height: 52px;
    padding: 6px max(12px, var(--safe-right)) 6px max(12px, var(--safe-left));
    padding-top: max(6px, var(--safe-top));
    border-bottom: 1px solid var(--line);
    background: var(--surface-overlay-strong);
    backdrop-filter: blur(20px);
  }

  .mobile-bar-title {
    flex: 1 1 auto;
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
    font-weight: 800;
    font-size: 14px;
  }

  .terminal-toolbar {
    display: none;
  }

  .terminal-panel {
    grid-row: 3;
    grid-template-rows: minmax(0, 1fr);
    min-height: 0;
    padding: 6px;
    padding-right: max(6px, var(--safe-right));
    padding-left: max(6px, var(--safe-left));
  }

  .panels-stage {
    min-height: 0;
    height: 100%;
    border-radius: 14px;
  }

  .surface-strip {
    grid-row: 2;
    display: flex;
    min-height: 42px;
    gap: 6px;
    padding: 6px max(10px, var(--safe-right)) 6px max(10px, var(--safe-left));
    overflow-x: auto;
    scrollbar-width: none;
    border-bottom: 1px solid var(--line);
    background: var(--surface-overlay);
  }

  .surface-strip::-webkit-scrollbar {
    display: none;
  }

  .surface-strip:empty {
    display: none;
  }

  .surface-chip {
    flex: 0 0 auto;
    max-width: 62vw;
    min-height: 30px;
    padding: 7px 11px;
    border: 1px solid var(--line);
    border-radius: 999px;
    background: var(--surface-overlay);
    color: var(--muted);
    font-size: 12px;
    font-weight: 700;
    cursor: pointer;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    font-family: "JetBrains Mono", ui-monospace, monospace;
  }

  .surface-chip.active {
    color: var(--accent);
    border-color: var(--selected-ring);
    background: var(--accent-soft);
  }

  .panels-stage[data-mobile-mode="single"] .remote-panel {
    inset: 0 !important;
    left: 0 !important;
    top: 0 !important;
    width: 100% !important;
    height: 100% !important;
    min-width: 0;
    min-height: 0;
    display: none;
    padding: 4px;
  }

  .panels-stage[data-mobile-mode="single"] .remote-panel.selected {
    display: grid;
  }

  .panels-stage[data-mobile-mode="single"] .remote-panel::before {
    inset: 3px;
    border-radius: 12px;
  }

  .panels-stage[data-mobile-mode="single"] .panel-header {
    min-height: 28px;
    padding: 6px 10px;
    border-radius: 10px 10px 0 0;
  }

  .panels-stage[data-mobile-mode="single"] .panel-header small {
    display: none;
  }

  .panels-stage[data-mobile-mode="single"] .terminal-mount {
    padding: 4px;
    border-radius: 0 0 10px 10px;
  }

  .panels-stage[data-mobile-mode="single"] .terminal-mount::after {
    display: none;
  }

  .panels-stage[data-mobile-mode="single"] .terminal-host {
    touch-action: manipulation;
  }

  .console-shell[data-kbd-visible="true"] {
    grid-template-rows: minmax(0, 1fr) auto;
  }

  .console-shell[data-kbd-visible="true"] .vkbd {
    display: block;
    grid-row: 2;
  }

  .console-shell[data-kbd-visible="true"] .panels-stage[data-mobile-mode="single"] .panel-header {
    display: none;
  }

  .console-shell[data-kbd-visible="true"] .panels-stage[data-mobile-mode="single"] .terminal-mount {
    border-radius: 10px;
  }
}
```

- [ ] **Step 2: Compact the virtual keyboard on mobile**

Append to `remote/src/client/styles/vkbd.css`:

```css
@media (max-width: 860px), (pointer: coarse) and (max-width: 1024px) {
  .vkbd {
    padding: 8px max(8px, var(--safe-right)) max(8px, var(--safe-bottom)) max(8px, var(--safe-left));
  }

  .vkbd-rows {
    gap: 5px;
  }

  .vkbd-row {
    gap: 4px;
  }

  .vkbd-key {
    height: 38px;
    min-width: 0;
    border-radius: 9px;
    padding: 0 4px;
    font-size: 13px;
  }

  .vkbd-key.vkbd-wide {
    font-size: 11px;
    letter-spacing: 0.08em;
  }
}
```

- [ ] **Step 3: Verify Task 5**

Run:

```bash
cd remote
npm run typecheck
npm run build
```

Expected: both commands pass.

- [ ] **Step 4: Commit Task 5**

```bash
git add remote/src/client/styles/responsive.css remote/src/client/styles/vkbd.css
git commit -m "polish remote mobile console layout"
```

### Task 6: Mobile Smoke Verification And Windows Path Check

**Files:**
- No code files required unless verification reveals a concrete defect.

- [ ] **Step 1: Run all remote checks**

Run:

```bash
cd remote
npm run test:client
npm run typecheck
npm run build
```

Expected: all commands pass.

- [ ] **Step 2: Start the local remote server for visual verification**

Run:

```bash
cd remote
npm run build:server
ADMIN_USERNAME=admin ADMIN_PASSWORD_HASH=sha256:5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8 SESSION_SIGNING_SECRET=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef REMOTE_COOKIE_SECURE=false HOST=127.0.0.1 PORT=8787 npm run start:server
```

Expected: server prints `listening on http://127.0.0.1:8787`.

- [ ] **Step 3: Use Playwright at iPhone 14 size**

In Playwright, set viewport to `390 x 844`, navigate to `http://127.0.0.1:8787/`, login with `admin` / `password`, connect to session key `iphone`, then inject a mock Phantty websocket layout with two surfaces:

```js
const ws = new WebSocket("ws://127.0.0.1:8787/ws/phantty?session=iphone");
const snapshot = [
  "Phantty remote mock on iPhone 14",
  "",
  "$ git status --short",
  " M remote/src/client/styles/responsive.css",
  "$ npm run build",
  "vite building...",
  "",
  "The selected terminal should own the mobile viewport.",
].join("\r\n");
ws.addEventListener("open", () => {
  ws.send(JSON.stringify({
    type: "layout",
    activeTab: 0,
    tabs: [{
      index: 0,
      title: "dev server",
      focusedSurfaceId: "surf-a",
      surfaces: [
        { id: "surf-a", title: "PowerShell", focused: true, cols: 120, rows: 34, cursorX: 0, cursorY: 8, x: 0, y: 0, w: 0.55, h: 1, snapshot },
        { id: "surf-b", title: "logs", focused: false, cols: 80, rows: 34, cursorX: 0, cursorY: 2, x: 0.55, y: 0, w: 0.45, h: 1, snapshot: "log stream\r\ninfo remote connected" },
      ],
    }],
  }));
});
```

Expected visual result:

- Top bar, surface strip, terminal stage, and bottom utility keyboard match the approved four-part layout.
- With keyboard visible, panel header is hidden and terminal area remains readable.
- With keyboard hidden, selected terminal gets extra height.
- Tapping `logs` switches selected surface.
- Tapping `Type` focuses the hidden text input/native keyboard path without stealing selected surface state.

- [ ] **Step 4: Run the Windows path checks because this plan adds files**

From PowerShell, run the Windows path and symlink checks from `AGENTS.md`.

Expected:

```text
windows_name_violations=0
casefold_collisions=0
```

And:

```powershell
git ls-files -s | Select-String '^120000'
```

Expected: no output.

- [ ] **Step 5: Commit verification-only fixes if any were needed**

If Step 3 or Step 4 required code changes, commit those exact fixes:

```bash
git add remote/src/client remote/test/client remote/package.json remote/package-lock.json
git commit -m "fix remote mobile verification issues"
```

If no changes were required, do not create an empty commit.

## Plan Self-Review

- Spec coverage: layout, input, navigation, state flow, fitting, and verification requirements are covered by Tasks 1-6.
- No relay/server/Zig protocol changes are included.
- Desktop behavior is preserved by keeping remote-grid sizing outside the mobile media query path.
- New files use Windows-safe lowercase names and no symlinks.
