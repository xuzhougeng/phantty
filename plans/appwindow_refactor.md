# Refactor AppWindow.zig into Sub-Modules

## Context

`AppWindow.zig` is 7,348 lines — a monolith handling font loading, glyph caching, cell rendering, titlebar/tab UI, input, overlays, post-processing shaders, tab/split management, and config reload. Following Ghostty's pattern of responsibility-based file splitting, we'll extract logical subsystems into an `src/appwindow/` directory. The slimmed-down `AppWindow.zig` becomes a coordinator (~1,300 lines).

## New File Structure

```
src/
  AppWindow.zig          (~1,300 lines — coordinator, init, render loop, GL setup, shared primitives)
  appwindow/
    font.zig             (~1,350 lines — FreeType/HarfBuzz/DirectWrite, glyph caching, atlas management)
    titlebar.zig         (~850 lines — tab bar rendering, caption buttons, bell emoji)
    cell_renderer.zig    (~1,200 lines — snapshot/rebuild/draw cell pipeline, renderChar)
    input.zig            (~900 lines — keyboard, mouse, clipboard, scrollbar/divider drag)
    overlays.zig         (~500 lines — scrollbar, resize overlay, debug overlay, split dividers, unfocused overlay)
    post_process.zig     (~250 lines — custom shader system)
    tab.zig              (~400 lines — TabState, spawn/close/switch, split ops, tab rename)
```

## What Stays in AppWindow.zig (Coordinator)

- `AppWindow` struct, `init`, `run`, `deinit`, `getHwnd`
- `runMainLoop` — the main render loop orchestrating all sub-modules
- Core globals: `g_app`, `g_window`, `g_allocator`, `g_theme`, `g_should_close`, `gl`
- GL initialization: `initShaders`, `initBuffers`, `initInstancedBuffers`, `compileShader`, `linkProgram`, `initSolidTexture`
- Shared rendering primitives: `renderQuad`, `renderQuadAlpha`, `setProjection` (used by all rendering modules)
- `computeSplitLayout`, `surfaceAtPoint`, `hitTestDivider`, `SplitRect` (orchestrates surface sizing)
- Window state: `loadWindowState`, `saveWindowState`, `resizeWindowToGrid`, `toggleFullscreen`
- `onWin32Resize` callback
- Config reload orchestration: `checkConfigReload`
- Utilities: `unixPathToWindows`, `getWslDistroName`, `f26dot6ToF64`

## Cross-Module Communication

Modules access shared state by importing `AppWindow.zig` directly for its `pub threadlocal` globals and `pub fn` rendering primitives. No `SharedState` struct needed — just make the necessary globals and functions `pub`.

Key shared globals (made `pub` in AppWindow.zig):
- `g_allocator`, `g_window`, `g_theme`, `gl` — read by all modules
- `shader_program`, `vao`, `vbo`, `solid_texture` — used by rendering modules via `renderQuad`
- `cell_width`, `cell_height`, `cell_baseline` — set by font module, read by cell_renderer
- `g_split_rects`, `g_split_rect_count` — set by coordinator, read by input/overlays

## Import Graph (no circular dependencies)

```
AppWindow.zig ── imports ──> font, titlebar, cell_renderer, input, overlays, post_process, tab

tab.zig           → Surface, SplitTree, win32_backend (NO rendering deps)
font.zig          → freetype, harfbuzz, directwrite, font/Atlas, font/sprite
cell_renderer.zig → AppWindow (renderQuad, gl), font (loadGlyph, atlas textures)
titlebar.zig      → AppWindow (renderQuad, gl), font (loadTitlebarGlyph), tab (tab state)
overlays.zig      → AppWindow (renderQuad, gl), font (for debug overlay), tab (activeTab)
post_process.zig  → AppWindow (gl), cell_renderer (drawCells)
input.zig         → AppWindow (g_split_rects), tab (spawn/close/split ops), overlays (scrollbar)
```

## Extraction Order (each step compiles independently)

### Step 1: Create `src/appwindow/tab.zig` ✅
**Why first**: Lowest coupling — zero GL/rendering dependencies. Clean boundary.

Extract:
- `TabState` struct and constants (`MAX_TABS`)
- Tab globals: `g_tabs`, `g_tab_count`, `g_active_tab`, `g_shell_cmd_buf`, `g_shell_cmd_len`, `g_scrollback_limit`
- Tab operations: `spawnTab`, `spawnTabWithCwd`, `closeTab`, `switchTab`, `activeTab`, `activeSurface`, `activeSelection`, `isActiveTabTerminal`, `getShellCmd`
- Split operations: `splitFocused`, `closeFocusedSplit`, `gotoSplit`, `equalizeSplits`, `updateFocusFromMouse`
- Tab rename: `g_tab_rename_*` globals, `startTabRename`, `commitTabRename`, `cancelTabRename`, `handleRenameKey`, `handleRenameChar`

In AppWindow.zig: `pub const tab = @import("appwindow/tab.zig");` — replace all direct calls.

### Step 2: Extract `src/appwindow/font.zig` ✅
**Why second**: Largest self-contained chunk (~1,350 lines). Uses "copy file, delete lines" approach.

Extract:
- All font globals: `glyph_face`, `glyph_cache`, `grapheme_cache`, `g_atlas*`, `g_color_atlas*`, `g_titlebar_*`, `g_icon_*`, `g_ft_lib`, `g_font_discovery`, `g_fallback_faces`, `g_hb_*`, `g_bell_*`, `g_font_size`
- `Character` struct, glyph loading: `loadGlyph`, `loadGraphemeGlyph`, `loadSpriteGlyph`, `loadTitlebarGlyph`, `loadIconGlyph`
- Atlas management: `packBitmapIntoAtlas`, `packColorBitmapIntoAtlas`, `syncAtlasTexture`
- Font init/cleanup: `preloadCharacters`, `clearGlyphCache`, `clearFallbackFaces`, `loadFontFromConfig`, `findOrLoadFallbackFace`
- Helpers: `isRegionalIndicator`, `graphemeHash`, `glyphUV`, `indexToRgb`
- Cell metrics: expose `cell_width`, `cell_height`, `cell_baseline` via public accessors

Implementation approach: Copy `AppWindow.zig` → `font.zig`, delete everything except font code, add `pub` accessors.

### Step 3: Extract `src/appwindow/cell_renderer.zig`
**Why third**: Depends on font module being extracted first.

Extract:
- Cell pipeline: `snapshotCells`, `rebuildCells`, `updateTerminalCells`, `updateTerminalCellsForSurface`, `drawCells`
- `renderChar` (immediate-mode single character rendering)
- `isCellSelected`, `currentRenderSelection`
- Cell-related globals: `g_current_render_surface`, cached cursor state

### Step 4: Extract `src/appwindow/titlebar.zig`
**Why fourth**: Depends on font (glyph rendering) and tab (tab state).

Extract:
- `renderTitlebar`, `renderCaptionButton`, `renderTitlebarChar`, `renderBellEmoji`, `renderIconGlyph`, `titlebarGlyphAdvance`, `renderPlaceholderTab`
- Titlebar globals: `g_tab_close_opacity`, `g_tab_close_pressed`, `g_last_frame_time_ms`, `g_tab_text_x_start`, `g_tab_text_x_end`

### Step 5: Extract `src/appwindow/overlays.zig`
**Why fifth**: Depends on font (debug overlay text) and tab (active tab).

Extract:
- Scrollbar: `scrollbarGeometry`, `scrollbarShow`, `scrollbarUpdateFade`, `renderScrollbar`, `renderScrollbarForSurface`, `scrollbarHitTest`, `scrollbarThumbHitTest`, `scrollbarDrag`
- Resize overlay: `resizeOverlayShow`, `resizeOverlayUpdate`, `renderResizeOverlay`, `renderResizeOverlayWithOffset`, `renderResizeOverlayForSurface`
- Debug: `renderDebugOverlay`, `renderDebugLine`
- Split rendering: `renderUnfocusedOverlay`, `renderUnfocusedOverlaySimple`, `renderSplitDividers`
- `renderRoundedQuadAlpha`
- All overlay-related globals

### Step 6: Extract `src/appwindow/post_process.zig`
**Why sixth**: Most isolated subsystem.

Extract:
- `buildPostFragmentSource`, `initPostShader`, `ensurePostFBO`, `renderPostProcess`, `renderFrameWithPostFromCells`
- Post-process globals: `g_post_fbo`, `g_post_texture`, `g_post_program`, `g_post_vao`, `g_post_vbo`, `g_post_enabled`, etc.
- Shader source strings

### Step 7: Extract `src/appwindow/input.zig`
**Why last**: Calls into nearly every other module (tab, overlays, cell_renderer).

Extract:
- The entire `win32_input` namespace/struct
- Input globals: `g_selecting`, `g_click_x/y`, `g_scrollbar_hover/dragging`, `g_divider_hover/dragging`
- `mouseToCell`, `viewportOffset`
- Clipboard operations: `copySelectionToClipboard`, `pasteFromClipboard`

### Step 8: Clean up coordinator
- Review remaining `AppWindow.zig` (~1,300 lines)
- Ensure `runMainLoop` reads as clear high-level orchestration
- Add module doc comments
- Verify all `pub` visibility is correct

## Verification Plan

After each step, verify:
1. `zig build` succeeds
2. Launch app — basic typing works
3. Create/close tabs (Ctrl+Shift+T, Ctrl+W)
4. Create/navigate/close splits (Ctrl+Shift+O/E, Ctrl+Alt+arrows)
5. Mouse selection works
6. Scrollback works
7. Config reload works (save config file, verify hot-reload)

Full regression after all steps:
- Tab rename (double-click tab title)
- Scrollbar drag
- Split divider drag
- Resize overlay during window resize
- Post-processing shader (if configured)
- Font fallback (type emoji)
- Fullscreen toggle (Alt+Enter)
