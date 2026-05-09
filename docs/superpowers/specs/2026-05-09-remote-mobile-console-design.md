# Remote Mobile Console Design

## Context

Phantty Remote already mirrors tabs and split surfaces into the browser and routes browser input back to the selected surface. The desktop web console is usable, but the iPhone 14 viewport is too cramped: the mobile header, surface chips, panel header, terminal frame, and fixed virtual keyboard compete with the terminal itself.

The approved direction is a mobile-first, terminal-first layout using the visual wireframe reviewed during brainstorming:

1. Compact top bar for menu, current tab title, connection status, and keyboard toggle.
2. Horizontal surface switcher directly below the top bar.
3. Selected terminal surface as the primary content.
4. Bottom utility keyboard for terminal-specific keys.

The implementation should stay within `remote/src/client` and must not change the relay protocol, server routes, or Zig remote client behavior.

## Ghostty Comparison

Ghostty does not implement a web remote console, so there is no one-to-one source file to copy. The relevant Ghostty model is its separation of app, surface, renderer, and input concerns.

Using `gh` against `ghostty-org/ghostty`:

- `src/App.zig` keeps a `focused_surface` and routes app key handling separately from surface-scoped key handling. The mobile Remote UI should follow that model by keeping one selected browser surface for input and not broadcasting mobile controls across all panels.
- `src/apprt/surface.zig` defines surface messages such as `present_surface`, clipboard read/write, and mouse shape changes. Remote mobile controls should remain browser-side presentation/input helpers and should not be treated as terminal emulation state.
- `src/renderer/OpenGL.zig` derives render surface size from the current viewport and presents a render target. The browser should similarly fit xterm to the actual selected terminal viewport after chrome/keyboard changes, not to the whole page.

## Goals

- Make the iPhone 14 portrait experience feel like a terminal first, not a dashboard squeezed onto a phone.
- Preserve the existing Remote session model: saved session key, drawer menu, tabs, surfaces, WebSocket reconnect, and xterm rendering.
- Make touch targets reliable for thumb use.
- Keep normal command typing and terminal utility keys easy to access.
- Ensure selected-surface input remains explicit and predictable.

## Non-Goals

- No changes to the relay server, Worker, Docker server, or WebSocket message schema.
- No changes to Phantty's Zig remote client.
- No new authentication or pairing flow.
- No desktop redesign beyond avoiding regressions from shared CSS.
- No terminal emulator reimplementation; xterm remains the browser terminal renderer.

## Recommended Approach

Use a full mobile shell redesign scoped to the existing client modules.

Other options considered:

- Only reduce chrome and padding. This would improve visible terminal space but leave typing and control placement awkward.
- Only improve the virtual keyboard. This would help command entry but leave navigation and viewport pressure unresolved.
- Full mobile shell redesign. This solves the layout, switching, and input ergonomics together while still avoiding protocol or server changes.

The recommended approach is the third option because the current pain is systemic: space, input, and controls all affect each other on iPhone.

## Layout Design

On mobile, `.console-shell` remains a single-column grid with the workspace above the virtual keyboard when the keyboard is visible.

The workspace is:

1. `.mobile-bar`: fixed-height compact bar with drawer button, tab title, status pip, and keyboard toggle.
2. `.surface-strip`: horizontal scroll list of surfaces for the current tab. It appears only when more than one surface exists.
3. `.terminal-panel`: full remaining height, containing `.panels-stage`.

The selected surface fills the panels stage in mobile single-surface mode. Non-selected surfaces remain mounted only as needed for state, but are hidden visually.

The mobile selected panel should reduce decorative chrome:

- Keep enough selected-surface affordance to show focus.
- Remove or compress the panel title/header on narrow screens.
- Remove the "outside terminal grid" label on mobile.
- Reduce terminal frame padding.
- Preserve xterm background, foreground, cursor, and selection theme.

## Input Design

The bottom utility keyboard remains available because terminal users need Esc, Tab, Ctrl, Alt, arrows, Enter, Backspace, and common shell symbols.

Improve the input model by making the "Type" action explicit:

- Tapping the terminal or Type focuses the selected xterm instance.
- Tapping utility keys should not steal terminal focus.
- Ctrl and Alt stay sticky for one following text/special key, then clear.
- Direct control shortcuts such as `^C`, `^D`, `^L`, `^R`, and `^Z` remain one-tap actions.

If iOS still fails to show the native keyboard reliably through xterm focus, add a hidden mobile text input bridge in the client. The bridge should forward inserted text to the selected surface through the existing `sendInputBytes` path, while utility keys continue to use `vkbd.ts`.

## Navigation Design

The drawer remains the place for session connection, tab list, relay notices, theme toggle, and logout.

The main mobile workspace should not require opening the drawer for common operation:

- Current tab title is visible in the top bar.
- Connection state is visible as a status pip.
- Surface switching is available in the strip.
- Keyboard visibility is one tap.

Remote tabs stay in the drawer for now. If tab switching becomes a repeated mobile task, a later change can add a compact tab switcher to the top bar, but that is out of scope for this pass.

## State And Data Flow

Existing data flow remains:

1. `transport.ts` receives layout/output/notice messages.
2. `layout.ts` normalizes relay layout messages.
3. `state.ts` stores selected tab, selected surface, drawer state, keyboard state, and surface views.
4. `views/console.ts` renders shell chrome, drawer, surface strip, and virtual keyboard visibility.
5. `surfaces.ts` owns xterm instances, selected surface rendering, focus, fit, and output writes.
6. `vkbd.ts` sends terminal input sequences through the existing virtual keyboard sender.

The redesign should avoid introducing a second source of truth for selected surface or keyboard visibility.

## Error Handling

- If no layout exists, keep the current empty state.
- If a selected surface disappears, preserve current fallback behavior: choose the focused surface or first surface in the active tab.
- If xterm fit fails during transient zero-size layout states, keep the existing guarded behavior.
- If the hidden text input bridge is added and unsupported on a browser, fall back to xterm focus plus utility keyboard.

## Testing

Automated checks:

- `npm run build` in `remote`.
- `npm run typecheck` in `remote`.
- Playwright mobile viewport check at iPhone 14 size, with a mocked Phantty WebSocket layout containing at least two surfaces.

Manual checks:

- iPhone 14 portrait: terminal occupies the majority of available height and selected surface is readable.
- iPhone 14 with utility keyboard visible and hidden.
- Surface switching by thumb.
- Drawer open/close and connect form still work.
- Type/focus path sends ordinary text to the selected surface.
- Utility keys send expected terminal sequences.

## Acceptance Criteria

- On a 390 x 844 viewport, the approved four-part mobile structure is visible and stable.
- The selected terminal surface fills the available terminal area without desktop-oriented decorative labels.
- The bottom utility keyboard does not overlap terminal content.
- Surface switching and keyboard toggling do not break xterm fitting.
- Browser input continues to route only to the selected surface.
- Desktop layout remains visually equivalent to the current console.
