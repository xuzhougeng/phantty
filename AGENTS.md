# AGENTS.md

## Overview

Phantty is a Windows terminal emulator written in Zig. It uses [libghostty-vt](https://github.com/ghostty-org/ghostty) (Ghostty's VT parser and terminal state machine) for terminal emulation, with its own rendering pipeline (OpenGL + FreeType + DirectWrite on Windows).

This is a **Windows-only** project. Development is expected to happen on Windows in PowerShell, targeting `x86_64-windows-gnu`.

## Hard Rules

When working on implementing a plan from the plans directory:
 * never deviate from the plan without asking for clear consent
 * never deem something too big and choosing not to do it in the name of pragmatism
 * always ask if you have trouble because something is too big, we will break it down together and work on it step by step

## Planning

When planning, always compare what we are planning to do with https://github.com/ghostty-org/ghostty.
This is the gold standard, we want to be as close to their implementation as possible.

Use the github cli gh to browse https://github.com/ghostty-org/ghostty and always add descriptions on how ghostty does things. 

## Build Commands

```powershell
zig build                         # Default Debug build; use this for development.
zig build -Doptimize=ReleaseFast  # Optimized ReleaseFast build with Windows GUI subsystem (no console window).
Remove-Item -Recurse -Force .\zig-out, .\.zig-cache -ErrorAction SilentlyContinue
```

**Always use `zig build`** for builds during PowerShell development. Only use `zig build -Doptimize=ReleaseFast` for final/shipping builds.

The Makefile may exist as a convenience wrapper, but normal development instructions must use PowerShell plus direct `zig` commands. Do not assume non-PowerShell shell tooling.

### Zig Toolchain

Use Zig 0.15.2 on Windows and make sure `zig.exe` is available on `PATH`.

Check the active Zig version from PowerShell:

```powershell
zig version
```

`build.zig` already defaults to `x86_64-windows-gnu`, so a normal development build should not need an explicit `-Dtarget`.

After a successful debug build, the expected artifact is:

```powershell
Test-Path .\zig-out\bin\phantty.exe
Get-Item .\zig-out\bin\phantty.exe
```

`Remove-Item -Recurse -Force .\zig-out, .\.zig-cache -ErrorAction SilentlyContinue` removes build outputs and Zig caches.

## Windows Development Compatibility

This repository must remain safe to check out and develop on Windows.

Before finishing changes that add, remove, rename, or move files, check for Windows-incompatible paths:

```powershell
$paths = git ls-files
$reserved = @('CON', 'PRN', 'AUX', 'NUL') + (1..9 | ForEach-Object { "COM$_"; "LPT$_" })
$violations = [System.Collections.Generic.List[object]]::new()
$collisions = [System.Collections.Generic.List[object]]::new()
$seen = @{}

foreach ($path in $paths) {
    foreach ($part in ($path -split '/')) {
        $stem = ($part -split '\.')[0].ToUpperInvariant()
        $reasons = @()
        if ($part.IndexOfAny([char[]]'<>:"\|?*') -ge 0) { $reasons += 'illegal_char' }
        if ($part.EndsWith(' ') -or $part.EndsWith('.')) { $reasons += 'trailing_space_or_dot' }
        if ($reserved -contains $stem) { $reasons += 'reserved_name' }
        if ($reasons.Count -gt 0) {
            $violations.Add([pscustomobject]@{ Path = $path; Part = $part; Reasons = ($reasons -join ',') })
        }
    }

    $key = $path.ToLowerInvariant()
    if ($seen.ContainsKey($key) -and $seen[$key] -ne $path) {
        $collisions.Add([pscustomobject]@{ A = $seen[$key]; B = $path })
    } else {
        $seen[$key] = $path
    }
}

"tracked_files=$($paths.Count)"
"windows_name_violations=$($violations.Count)"
$violations | ForEach-Object { "violation`t$($_.Path)`t$($_.Part)`t$($_.Reasons)" }
"casefold_collisions=$($collisions.Count)"
$collisions | ForEach-Object { "collision`t$($_.A)`t$($_.B)" }
$longest = $paths | Sort-Object Length -Descending | Select-Object -First 1
"max_path_length=$($longest.Length) $longest"
```

Also check for symlinks, which are often painful on Windows checkouts:

```powershell
git ls-files -s | Select-String '^120000'
```

Rules of thumb:
- Do not introduce files whose names differ only by case. Windows checkout is case-insensitive by default.
- Avoid Windows-reserved names (`CON`, `PRN`, `AUX`, `NUL`, `COM1`-`COM9`, `LPT1`-`LPT9`) in any path segment, even with extensions.
- Avoid characters illegal on Windows: `< > : " \ | ? *`.
- Avoid trailing spaces or trailing dots in any path segment.
- Keep paths reasonably short. Current longest tracked path is expected to be well below Windows path limits.

## Project Structure

```
src/
├── main.zig            # Entry point, GLFW window, OpenGL rendering, input handling, main loop
├── config.zig          # Config loading (file + CLI), theme resolution, key=value parser
├── config_watcher.zig  # Hot-reload via ReadDirectoryChangesW (watches config directory)
├── pty.zig             # Windows ConPTY pseudo-terminal
├── directwrite.zig     # DirectWrite FFI for Windows font discovery
├── themes.zig          # Embedded theme data (453 Ghostty-compatible themes)
├── renderer.zig        # Renderer module entry point / re-exports
├── renderer/
│   ├── Renderer.zig    # Per-surface renderer implementation
│   ├── State.zig       # Shared renderer state
│   ├── cell_renderer.zig
│   ├── fbo.zig
│   ├── gl_init.zig
│   └── post_process.zig
└── font/
    ├── embedded.zig    # Embedded fallback font (Cozette bitmap font)
    ├── sprite.zig      # Sprite font for box drawing, block elements, braille, powerline
    └── sprite/
        ├── canvas.zig          # 2D canvas for sprite rasterization
        └── draw/
            ├── common.zig      # Shared sprite drawing utilities
            ├── box.zig         # Box drawing characters (U+2500–U+257F)
            └── braille.zig     # Braille patterns (U+2800–U+28FF)

debug/                  # Test scripts (run inside phantty terminal)
pkg/                    # Vendored build dependencies (freetype, zlib, libpng, opengl)
vendor/                 # Vendored source code
```

## Ghostty Reference

Phantty intentionally follows Ghostty's design and behavior. When implementing or modifying features, **cross-reference the Ghostty source** at https://github.com/ghostty-org/ghostty.

Key mapping of Phantty files to Ghostty counterparts:

| Phantty | Ghostty Reference | Notes |
|---------|-------------------|-------|
| `src/config.zig` | [`src/config/Config.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/config/Config.zig) | Same `key = value` format, same key names where applicable |
| `src/config_watcher.zig` | Ghostty's config reload mechanism | Hot-reload on file change |
| `src/pty.zig` | [`src/os/ConPty.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/os/ConPty.zig) | Windows ConPTY, Ghostty also has this for Windows |
| `src/themes.zig` | [`src/config/theme.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/config/theme.zig) | Same theme file format, same built-in theme collection |
| `src/font/sprite/` | [`src/font/sprite/`](https://github.com/ghostty-org/ghostty/tree/main/src/font/sprite) | Box drawing, braille — follows Ghostty's sprite approach |
| `src/font/embedded.zig` | Ghostty's embedded Cozette font | Same fallback font |
| `src/main.zig` (rendering) | [`src/renderer/OpenGL.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/renderer/OpenGL.zig) | OpenGL rendering, cell grid, shaders |
| `src/main.zig` (input) | [`src/apprt/glfw.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/apprt/glfw.zig) | GLFW key/mouse handling |
| `src/directwrite.zig` | [`src/font/discovery.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/font/discovery.zig) | Font discovery (Phantty uses DirectWrite directly) |

When adding features:
- Check how Ghostty implements it first
- Match Ghostty's config key names and value formats
- Follow Ghostty's conventions for theme files, color handling, cursor behavior, etc.
- The VT parsing itself comes from Ghostty as a Zig dependency — don't reimplement terminal emulation

## Config System

Config file location: `%APPDATA%\phantty\config` (on Windows). The config directory and a default config file are created automatically at startup.

Config is loaded in order (last wins): defaults → config file → CLI flags.

Press `Ctrl+,` at runtime to open the config in notepad — changes are hot-reloaded via the file watcher.

## Dependencies

Defined in `build.zig.zon`:
- **ghostty** — libghostty-vt (VT parser + terminal state) from a pinned Ghostty main-branch snapshot. Prefer pinning an exact commit tarball and matching hash over `main.tar.gz`, so builds are reproducible.
- **glfw** — Window management and input
- **z2d** — 2D graphics library
- **freetype** / **zlib** / **libpng** / **opengl** — vendored in `pkg/`

When updating Ghostty, expect API drift. The current main-branch API returns `void` from terminal operations such as `Terminal.vt`, `Stream.nextSlice`, and `Terminal.scrollViewport`; do not add `try` or `catch {}` around those calls unless the dependency version actually returns an error union.
