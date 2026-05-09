# AGENTS.md

## Overview

Phantty is a Windows terminal emulator written in Zig. It uses [libghostty-vt](https://github.com/ghostty-org/ghostty) (Ghostty's VT parser and terminal state machine) for terminal emulation, with its own rendering pipeline (OpenGL + FreeType + DirectWrite on Windows).

This is a **Windows-only** project. Development is expected to happen on Windows in PowerShell, targeting `x86_64-windows-gnu`.

## Hard Rules

When changing application **keyboard shortcuts** (bindings in `src/input.zig` and related input paths), **update `README.md`** so the [Keyboard shortcuts](README.md#keyboard-shortcuts) section stays accurate. Also update user-visible shortcut text in `src/renderer/overlays.zig` (startup overlay, command palette entries) when those strings describe the same bindings.

When working on implementing a plan from the plans directory:
 * never deviate from the plan without asking for clear consent
 * never deem something too big and choosing not to do it in the name of pragmatism
 * always ask if you have trouble because something is too big, we will break it down together and work on it step by step

## Planning

When planning, always compare what we are planning to do with https://github.com/ghostty-org/ghostty.
This is the gold standard, we want to be as close to their implementation as possible.

Use the github cli gh to browse https://github.com/ghostty-org/ghostty and always add descriptions on how ghostty does things. 

Exception: work under `remote/` is Phantty's own web remote console and relay implementation. Ghostty does not have an equivalent feature, so `remote/` planning and implementation **does not need to compare against or reference Ghostty**. For `remote/`, follow the existing `remote/` architecture, browser platform constraints, and the user-approved design/plan for that feature.

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

## Windows UI Automation

When debugging UI behavior, automate Phantty as a real visible Windows app from PowerShell. Prefer Win32-driven automation over shell-only assumptions.

Use the checked-in automation script for File Explorer regressions:

```powershell
zig build
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-file-explorer-ui.ps1
```

The script launches a real Phantty window, sets DPI awareness, fixes the window position and size, captures before/after screenshots, crops the right panel, sends `Ctrl+Shift+E`, performs a region-based pixel check, and writes screenshots plus JSON metrics under `zig-out\ui-test\`.

When adding more UI automation, follow the same pattern:
- Wait until `MainWindowHandle` is non-zero, call `ShowWindow` and `SetForegroundWindow`, then click inside the client area before sending keys.
- Prefer Win32 `keybd_event` or `SendInput` for shortcuts; `System.Windows.Forms.SendKeys` can silently miss GLFW/terminal windows when focus is not exactly right.
- Capture both full-window and cropped target-region screenshots, and inspect the crop when a pixel check fails.
- Always clean up test windows with `CloseMainWindow()`, then `Stop-Process -Force` if the process remains.

## Windows SSH/SCP Compatibility

When changing SSH/SCP code paths (`src/scp.zig`, SSH clipboard image paste, remote file explorer listing/upload/download, or SSH session metadata), test against the existing real SSH profile in `%APPDATA%\phantty\ssh_hosts` whenever it is available. The profile fields are hex encoded as `name, host, user, password, port`; decode them locally for the test, but never print or commit the password. At minimum, verify:

```powershell
ssh.exe ... user@host pwd
scp.exe ... local-file user@host:/tmp/test-file
ssh.exe -T ... user@host "cat > '/tmp/test-file'"  # only if testing the stream fallback
```

Do **not** add OpenSSH connection sharing (`ControlMaster`, `ControlPersist`, `ControlPath`) to helper `ssh.exe` or `scp.exe` commands on Windows. Windows OpenSSH does not provide the Unix-domain socket behavior those options expect here; it reproduces as `getsockname failed: Not a socket`, `Read from remote host ...: Unknown error`, `scp.exe: Connection closed`, or `lost connection`. This broke SCP uploads even though the same profile and remote service worked without those options.

Keep stderr visible for helper `ssh.exe`/`scp.exe` failures. Do not reduce failures to a generic "SSH image upload failed"; preserve the underlying OpenSSH error so regressions can be diagnosed without guessing.

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
src/                         # Windows desktop terminal application
├── main.zig                 # Entry point, GLFW window, OpenGL setup, main loop
├── App.zig                  # Application-level state, config reload, remote client lifecycle
├── AppWindow.zig            # Window-level tabs, splits, rendering and input routing
├── Surface.zig              # Per-terminal surface state and PTY integration
├── input.zig                # Keyboard/mouse shortcuts and command dispatch
├── config.zig               # Config loading (file + CLI), theme resolution, key=value parser
├── config_watcher.zig       # Hot-reload via ReadDirectoryChangesW
├── pty.zig                  # Windows ConPTY pseudo-terminal
├── remote_client.zig        # Outbound Phantty Remote relay client
├── file_explorer.zig        # Local/SSH file explorer state and operations
├── browser_panel.zig        # Embedded browser panel and SSH tunnel handling
├── directwrite.zig          # DirectWrite FFI for Windows font discovery
├── themes.zig              # Embedded Ghostty-compatible themes
├── appwindow/               # Tab and split-tree helpers for AppWindow
├── apprt/                   # Win32/windowing support code
├── font/                    # Font manager, atlas, embedded fallback, sprite glyphs
├── renderer/                # OpenGL renderer, cell renderer, overlays, titlebar, panels
└── termio/                  # PTY read/write threads and terminal IO mailbox

remote/                      # Phantty-specific web remote console and relay
├── src/client/              # Browser app: xterm surfaces, layout, virtual keyboard, styles
│   ├── views/               # Login and remote console views
│   └── styles/              # Base, console, responsive, token, and virtual keyboard CSS
├── src/server/              # Node.js relay server for Docker/local hosting
├── src/worker.ts            # Cloudflare Worker + Durable Object relay
├── index.html               # Vite browser entry
├── package.json             # Remote build/dev/typecheck scripts
├── Dockerfile               # Container build for the Node relay
├── docker-compose.yml       # Local/VPS Docker deployment helper
├── nginx.conf.example       # Reverse proxy example for Docker deployment
└── wrangler.toml.example    # Cloudflare deployment template

docs/                        # Static website and generated/project documentation
├── index.html
├── zh.html
├── style.css
├── assets/
└── superpowers/             # Approved design specs and implementation plans

plans/                       # Project planning notes and historical implementation plans
release-notes/               # Versioned release notes
debug/                       # Test/debug scripts, including Windows UI automation
packaging/windows/           # Windows installer and packaging scripts
assets/                      # Application icon and source art
shaders/                     # GLSL shader files
tools/                       # Terminal helper scripts such as imgcat/pdfcat
pkg/                         # Vendored build dependencies (freetype, zlib, libpng, opengl, etc.)
vendor/                      # Vendored source code
```

## Ghostty Reference

Phantty intentionally follows Ghostty's design and behavior for terminal emulator functionality. When implementing or modifying features in the main Zig terminal app, **cross-reference the Ghostty source** at https://github.com/ghostty-org/ghostty.

This Ghostty reference requirement does **not** apply to `remote/`. The `remote/` directory contains Phantty-specific web remote console and relay code; develop it from the existing remote codebase, web/mobile UX requirements, and local plans rather than trying to match Ghostty.

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
