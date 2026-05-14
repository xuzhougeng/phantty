# Remote Web Viewport Development Notes

This document records the viewport and panning rules learned while stabilizing
Phantty Remote web rendering across mobile browsers, desktop browsers, IME
input, zoomed desktop layouts, and xterm's DOM renderer.

The important rule is simple: mobile and desktop do not share the same viewport
constraints. Keep their render strategies explicit.

## Scope

This applies only to `remote/`, especially:

- `src/client/surfaces.ts`
- `src/client/mobile_canvas.ts`
- `src/client/mobile_layout.ts`
- `src/client/mobile_text_input.ts`
- `src/client/styles/console.css`
- `src/client/styles/responsive.css`
- `test/client/mobile_canvas.test.ts`
- `test/client/mobile_layout.test.ts`
- `test/client/mobile_text_input.test.ts`

The desktop Zig terminal and Ghostty compatibility rules do not apply to this
web remote viewport work. The remote client is a browser-specific UI and should
be developed from browser behavior, xterm DOM constraints, and the invariants
below.

## DOM Layer Model

Keep these layers mentally separate:

- `.terminal-mount`
  - The visible panel viewport.
  - Owns pointer, wheel, and virtual scrollbar event interception.
  - Should remain the fixed frame of reference for geometry checks.

- `.terminal-host`
  - Our controlled host layer around xterm.
  - On desktop, this is the programmatic scroll container.
  - On mobile, this is the transform target for touch canvas panning.

- `.xterm`
  - xterm's root element.
  - Do not depend on this as the high-level panning API.

- `.xterm-viewport`
  - xterm's internal viewport.
  - In our CSS, it often has `scrollHeight == clientHeight` and hidden
    overflow, so it may not be the effective scroll container.

- `.xterm-scrollable-element` / `.xterm-screen` / `.xterm-rows`
  - xterm's rendered content layers.
  - These are content surfaces, not the object our virtual scrollbar should
    directly manipulate.

If browser DevTools highlights `.xterm-scrollable-element`, that only proves it
is the content being clipped or revealed. It does not mean our code should set
`scrollTop` on it.

## Mobile Strategy

Mobile must use canvas transform panning:

```text
touch drag -> canvasPan -> terminal-host transform: translate3d(...)
```

Do not replace mobile touch panning with `host.scrollTop` or `host.scrollLeft`.
The mobile path has extra constraints:

- The software keyboard changes the visual viewport.
- Browser address bars and IME panels can shrink or offset the viewport.
- The terminal grid can be larger than the visible panel in both axes.
- Users expect direct touch dragging of the canvas.
- A bottom gutter may be required so the prompt line is not clipped by mobile
  viewport edges or keyboard overlays.

Mobile invariants:

- Touch drag changes `terminal-host.style.transform`.
- Touch drag should keep `host.scrollTop == 0` and `host.scrollLeft == 0`.
- The prompt/input row must remain reachable after the keyboard opens.
- `visualViewport.height` and `visualViewport.offsetTop` should be reflected in
  CSS variables through `applyVisualViewportSizing`.
- The hidden mobile text input must not participate in desktop keyboard input.

Regression test targets:

- `canvasPanRenderState(pan, "transform")`
- `resizeCanvasPan(...)` with mobile bottom gutter
- `focusMobileTextInput(...)`
- `toggleMobileTextInput(...)`
- Composition input handling

Manual mobile smoke test:

1. Open the remote page on a phone or mobile viewport.
2. Select a remote terminal panel.
3. Drag the terminal content horizontally and vertically.
4. Tap `IME`, open the software keyboard, and check that the prompt/input row is
   reachable.
5. Inspect DOM if needed:
   - `terminal-host.style.transform` should become `translate3d(...)`.
   - `terminal-host.scrollTop` should stay `0`.

## Mobile Drawer And Tabs

The mobile drawer is not just a settings sidebar. On phones it is also the
primary way to switch remote workspace tabs, so tab access must survive short
screens, browser toolbar shrinkage, and extra panels such as relay status or
Weixin bridge controls.

Design target:

- The current tab title remains visible in the mobile top bar.
- Opening the drawer makes the `Tabs` section reachable without depending on a
  full-height phone.
- A long tab list scrolls inside the tab list, not by shrinking each tab chip or
  clipping the section.
- Secondary controls can move below tabs or into compact/collapsible sections.
- Connection setup and bridge settings should not be able to collapse or hide
  tab navigation.

Recommended layout rules:

- Keep `.sidebar` as the outer scroll container for the whole drawer.
- Keep `.remote-tabs-panel` out of flex shrink on mobile, for example
  `flex: 0 0 auto`.
- Give `.remote-tabs` a viewport-relative maximum height and `overflow-y: auto`
  so many tabs remain reachable on short screens.
- Use `overflow-x: hidden` only to prevent horizontal label spill; avoid
  `overflow: hidden` on the whole tabs section because it hides the controls
  users need to recover.
- Prefer moving rarely used panels below tabs before making tab chips smaller.

Anti-patterns:

- Adding new mobile drawer panels above `Tabs` without rechecking a short phone
  viewport.
- Treating the drawer as a static desktop sidebar and relying on vertical space
  that does not exist on phones.
- Making the tab list visually fit by clipping it instead of making it
  independently scrollable.
- Nesting several full card-like sections above the primary navigation.

Regression checks:

- In a `390x520` mobile viewport with at least 8 tabs, the first tab chip should
  be visible when the drawer opens.
- The last tab chip should be reachable by scrolling `.remote-tabs`.
- `.remote-tabs-panel` should not shrink below its label plus usable list area.
- `test/client/responsive_css.test.ts` should assert the mobile CSS contract:
  tabs panel does not shrink, tab list has a max height, and tab list scrolls
  vertically.

## Desktop Strategy

Desktop must keep `.terminal-host` fixed in `.terminal-mount` and use host
scroll offsets:

```text
wheel / middle-drag / canvas-scrollbar -> canvasPan -> host.scrollLeft/scrollTop
```

This avoids moving the whole host out of the panel, which caused clipping and
blank striped areas at high browser zoom levels.

Desktop invariants:

- `terminal-host.style.transform` should be empty.
- `getComputedStyle(terminal-host).transform` should be `none`.
- Wheel or virtual scrollbar movement should update `host.scrollTop`.
- Horizontal panning should update `host.scrollLeft`.
- The host top should stay aligned under `.terminal-mount` padding.
- The virtual scrollbar thumb bottom should correspond to the last reachable
  terminal content row.

Regression test targets:

- `canvasPanRenderState(pan, "scroll")`
- `canvasPanToScrollOffset(...)`
- `panCanvasByWheel(...)`
- `verticalScrollbarMetrics(...)`
- `panYFromVerticalScrollbarThumb(...)`
- `shouldConsumeCanvasWheel(...)`

Manual desktop smoke test:

1. Open the remote page in a desktop browser.
2. Test normal desktop size and a narrow/zoomed view, such as browser zoom
   around 175 percent.
3. Use the mouse wheel over a remote-grid panel.
4. Drag the right-side `.canvas-scrollbar`.
5. Middle-drag the terminal canvas.
6. Inspect DOM if needed:
   - `terminal-host.style.transform` should stay empty.
   - `host.scrollTop` should change when moving vertically.
   - `host.scrollTop` should reach `host.scrollHeight - host.clientHeight`.

## Common Failure Modes

### One Pan Implementation For Both Platforms

Avoid this. A single pan calculation can be shared, but the render application
must be mode-specific:

- mobile: transform
- desktop: scroll offsets

The regression that broke mobile touch drag came from applying the desktop
scroll-offset strategy globally.

### Moving `terminal-host` On Desktop

Using `translate3d(...)` on desktop can make the whole xterm tree move above or
below `.terminal-mount`. At high zoom, this presents as content being clipped,
large blank striped areas, or an input line that cannot be reached.

Desktop should move the visible content through `scrollTop` and `scrollLeft`,
not by translating the host itself.

### Treating `.xterm-scrollable-element` As The Scroll API

In our layout, `.xterm-scrollable-element` is the content layer. It may have the
height of the rendered terminal content, but it is not necessarily scrollable.

Prefer:

```text
canvas-scrollbar / wheel -> canvasPan -> terminal-host.scrollTop
```

Not:

```text
canvas-scrollbar / wheel -> .xterm-scrollable-element.scrollTop
```

### Trusting Visual Screenshots Without DOM Geometry

Screenshots show the symptom, but these bugs need DOM measurements:

- mount rect
- host rect
- host scroll dimensions
- host scroll offsets
- host transform
- xterm screen height
- bottom gap between host and rendered content

Use Playwright or DevTools console to inspect these values before deciding where
the bug lives.

## Verification Checklist

Before shipping remote viewport changes, run:

```bash
cd remote
npm run test:client
npm run typecheck
npm run build
```

For changes that add, remove, or rename files, also run the repository's Windows
path compatibility checks from `AGENTS.md`.

For browser behavior, verify at least:

- Mobile viewport, around `390x844`
  - Touch drag changes `transform`.
  - `scrollTop` remains `0` during touch canvas panning.
  - IME opens without hiding the final input row.

- Desktop viewport, around `1180x850`
  - Wheel changes `host.scrollTop`.
  - `transform` remains `none`.
  - The virtual scrollbar can reach the last content row.

- Zoomed/narrow desktop
  - Simulate the user's reported 175 percent zoom condition.
  - The host stays mounted at the top.
  - The final prompt row is reachable.

When deployed, confirm the version and asset hash:

- Sidebar label should show `Web YYYY MM DD HH:mm`.
- HTML should reference the expected `/assets/index-*.js`.
- The running pod should use the digest pushed by the latest Docker build.

## Useful Runtime Probes

Desktop scroll probe:

```js
const panel = document.querySelector(".remote-panel.selected") || document.querySelector(".remote-panel");
const mount = panel.querySelector(".terminal-mount");
const host = panel.querySelector(".terminal-host");
host.scrollTop = 0;
host.style.transform = "";
mount.dispatchEvent(new WheelEvent("wheel", {
  deltaY: 180,
  bubbles: true,
  cancelable: true,
}));
({
  transform: host.style.transform,
  computedTransform: getComputedStyle(host).transform,
  scrollTop: host.scrollTop,
  maxScrollTop: host.scrollHeight - host.clientHeight,
});
```

Expected desktop result:

```js
{
  transform: "",
  computedTransform: "none",
  scrollTop: /* greater than 0 when content overflows */,
  maxScrollTop: /* reachable */
}
```

Mobile touch probe:

```js
const panel = document.querySelector(".remote-panel.selected") || document.querySelector(".remote-panel");
const mount = panel.querySelector(".terminal-mount");
const host = panel.querySelector(".terminal-host");
const rect = mount.getBoundingClientRect();
const pointer = (type, x, y, buttons = 1) => new PointerEvent(type, {
  bubbles: true,
  cancelable: true,
  pointerId: 1,
  pointerType: "touch",
  isPrimary: true,
  button: 0,
  buttons,
  clientX: x,
  clientY: y,
});
mount.dispatchEvent(pointer("pointerdown", rect.right - 40, rect.bottom - 40));
mount.dispatchEvent(pointer("pointermove", rect.right - 180, rect.bottom - 180));
mount.dispatchEvent(pointer("pointerup", rect.right - 180, rect.bottom - 180, 0));
({
  transform: host.style.transform,
  scrollLeft: host.scrollLeft,
  scrollTop: host.scrollTop,
});
```

Expected mobile result:

```js
{
  transform: "translate3d(...)",
  scrollLeft: 0,
  scrollTop: 0,
}
```

## Development Rules

- Keep pan math pure and tested in `mobile_canvas.ts`.
- Keep platform mode selection explicit at the DOM application boundary.
- Do not couple virtual keyboard changes with desktop scroll behavior unless a
  test proves the shared behavior.
- Do not rely on xterm internal class names as public APIs unless there is no
  alternative and the assumption is covered by a browser smoke test.
- Add a regression test whenever a screenshot points to a new invariant.
- After deployment, verify the live page, not only the local build.
