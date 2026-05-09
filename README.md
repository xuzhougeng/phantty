<h1>
  <p align="center">
    <img src="assets/phantty.png" alt="Phantty logo" width="128">
    <br>Phantty
  </p>
</h1>

A Windows terminal written in Zig, powered by [libghostty-vt](https://github.com/ghostty-org/ghostty) for terminal emulation.

> [!NOTE]
> This repository is a fork of [arya-s/phantty](https://github.com/arya-s/phantty),
> with additional features layered on top: an embedded WebView2 browser panel,
> a file explorer with Markdown/text preview, an opt-in remote-access client,
> Kitty Graphics image protocol support, and a configurable background image.

## Features

- **Ghostty's terminal emulation** — uses libghostty-vt for VT parsing and terminal state
- **DirectWrite font discovery** — find system fonts by name, with per-glyph fallback for missing characters
- **FreeType rendering** — high-quality glyph rasterization with Ghostty-style font metrics
- **Sprite rendering** — box drawing, block elements, braille patterns, powerline symbols
- **Theme support** — Ghostty-compatible theme files, 450+ themes built in (default: Poimandres)
- **Background image** — render a wallpaper behind the terminal with per-cell opacity blending and four scaling modes (`fill` / `fit` / `center` / `tile`)
- **Splits and tabs** — vertical/horizontal splits, tab strip, focus-follows-mouse, equalize sizes
- **File Explorer and previews** — browse local, WSL, and SSH files; preview Markdown/text without leaving the terminal
- **Embedded browser panel** — open `http://` / `https://` URLs in a side WebView2 panel; SSH sessions tunnel loopback URLs automatically
- **Kitty Graphics protocol** — display inline images and PDFs from remote shells via `imgcat.py` / `pdfcat.py`
- **Custom post-processing shaders** — Ghostty-compatible GLSL post-processing (CRT, glitch, etc.); the wallpaper is rendered inside the same FBO so effects apply uniformly
- **Opt-in remote access** — share a session key over a Cloudflare-hosted relay (disabled by default)

> [!NOTE]
> Phantty is **Windows-only**. On macOS and Linux, use [Ghostty](https://ghostty.org/) instead.


## Building

```powershell
zig build                         # Debug build for development
zig build -Doptimize=ReleaseFast  # ReleaseFast build for distribution
Remove-Item -Recurse -Force .\zig-out, .\.zig-cache -ErrorAction SilentlyContinue
```

The `Makefile` may still exist as a convenience wrapper, but normal Windows
development should use PowerShell and direct `zig` commands.

## Packaging

Phantty supports two portable Windows packages plus the local installer build:

- `portable` — lightweight portable build, run directly without installation
- `portable-webview2` — portable build with `WebView2Loader.dll` for the embedded browser
- `phantty-setup.exe` — installer build, installs to the current user's profile and creates a Start menu shortcut

Build the artifacts with:

```powershell
powershell -ExecutionPolicy Bypass -File .\packaging\windows\package.ps1
```

This produces:

```text
zig-out\dist\portable\phantty.exe
zig-out\dist\portable-webview2\phantty.exe
zig-out\dist\portable-webview2\WebView2Loader.dll
zig-out\dist\installer\phantty-setup.exe
```

The installer does not require administrator rights. It installs Phantty to
`%LOCALAPPDATA%\Programs\Phantty`, adds a Start menu entry, and registers an
uninstall entry for the current user.

## GitHub Releases

The GitHub Actions workflow at `.github/workflows/windows-release.yml`
publishes Windows release assets whenever a tag matching `vX.Y.Z` is pushed.

Each tagged release uploads:

- `phantty-windows-portable-vX.Y.Z.zip`
- `phantty-windows-portable-webview2-vX.Y.Z.zip`

The unsigned IExpress installer is not published for now because Windows
Defender can quarantine it as a false positive. Use the portable zip release
asset, or the `portable-webview2` zip when using the embedded browser panel.

Release notes are checked in under `release-notes/vX.Y.Z.md` when a release
needs curated notes. If a matching file is present, the workflow prepends it to
the GitHub release body; otherwise GitHub generated notes are used with the
asset summary.

## Usage

```bash
phantty.exe [options]

Options:
  --font, -f <name>            Set font (default: embedded fallback)
  --font-style <style>         Font weight (default: regular)
                                Options: thin, extra-light, light, regular,
                                         medium, semi-bold, bold, extra-bold, black
  --cursor-style <style>       Cursor shape (default: block)
                                Options: block, bar, underline, block_hollow
  --cursor-style-blink <bool>  Enable cursor blinking (default: true)
  --theme <path>               Load a Ghostty theme file
  --background-image <path>    Image file to render behind the terminal
  --background-opacity <0..1>  Opacity of theme/cell backgrounds (default: 1.0)
  --background-image-mode <m>  fill | fit | center | tile (default: fill)
  --window-height <rows>       Initial window height in cells (default: 0=auto, min: 4)
  --window-width <cols>        Initial window width in cells (default: 0=auto, min: 10)
  --list-fonts                 List available system fonts
  --test-font-discovery        Test DirectWrite font discovery
  --help                       Show help
```

## Keyboard shortcuts

Default chords are implemented in [`src/input.zig`](src/input.zig). Some keys are handled first when a modal overlay is open (command center, session launcher, settings, and similar).

| Shortcut | Action |
|----------|--------|
| **Ctrl+Shift+P** | Open command center |
| **Ctrl+Shift+T** | New session (session launcher) |
| **Ctrl+Shift+N** | New window |
| **Ctrl+Shift+B** | Toggle tab sidebar |
| **Ctrl+Shift+O** | Split to the right |
| **Ctrl+Shift+E** | Toggle file explorer sidebar |
| Ctrl-click `.md` / `.txt` in terminal output or File Explorer | Preview local, WSL, or SSH Markdown/text in the right preview panel |
| **Ctrl+Shift+W** | Close focused panel, tab, or window |
| **Alt+Enter** | Maximize or restore window |
| **Ctrl++** / **Ctrl+-** | Increase / decrease font size |
| **Ctrl+Shift+C** | Copy selection |
| Right-click a selection | Copy selection |
| **Ctrl+V** | Paste text |
| **Ctrl+Shift+V** | Paste clipboard image |
| **Ctrl+Shift** + arrow keys | Move focus to adjacent panel (spatial) |
| **Ctrl+Shift+[** | Focus previous panel (cycle) |
| **Ctrl+Shift+]** | Focus next panel (cycle) |
| **Ctrl+Shift+Z** | Equalize split sizes |
| **Ctrl+Tab** | Next tab |
| **Ctrl+Shift+Tab** | Previous tab |
| **Alt+1**–**9** | Switch to tab 1–9 (when that tab exists) |
| **Ctrl+,** | Open config file in the default editor |

## File Explorer and Markdown Preview

Press `Ctrl+Shift+E` to open the right-side File Explorer. It follows the
active environment:

- Windows shells browse local Windows paths.
- WSL sessions browse the default WSL distro through `wsl.exe`.
- Phantty SSH profile sessions browse the remote host through OpenSSH helpers.

Hold `Ctrl` and click a `.md` or `.txt` file in terminal output or in the File
Explorer to open the right-side preview panel. Markdown previews render
headings, lists, blockquotes, code blocks, inline code, links, and horizontal
rules. Text files are shown as plain text.

Open the command center with `Ctrl+Shift+P` and run `Toggle Browser` to open
the embedded WebView2 browser panel. `Ctrl`-clicking an `http://` or `https://`
URL in terminal output opens it in the same right-side WebView2 panel. In SSH
profile sessions, loopback URLs such as `http://127.0.0.1:4232` and
`http://localhost:43455` are opened through an automatic local SSH tunnel;
the tunnel prefers the same local port and only increments when that port is
already occupied.
non-loopback URLs such as `https://10.10.x.x` or public websites open directly.
Click the browser panel's URL bar to type a new address; press `Enter` to
navigate. Drag the browser panel's left edge to resize it.

The preview panel can be resized by dragging its left edge and scrolled with the
mouse wheel. `Ctrl+Shift+W` closes the preview panel before closing a split.

SSH previews require Phantty's SSH profile metadata, so sessions launched from
the built-in SSH launcher are supported. Manually typing `ssh user@host` inside
a local shell is still treated as that local shell and cannot use remote file
preview yet.

## Background Image

Set `background-image` in the config (or pass `--background-image`) to render a
wallpaper behind the terminal. PNG, JPG, BMP, GIF, and TGA are supported.

`background-opacity` controls how strongly the theme background tints the
wallpaper:

| Value | Effect |
|------:|--------|
| `1.0` (default) | Theme background is fully opaque — image is hidden, terminal looks the same as without one |
| `0.85` | Faint watermark (image shows through ~15%) |
| `0.5` | Equal blend |
| `0.15` | Image dominates with a light theme tint |
| `0.0` | Theme tint is skipped — image at full strength |

The opacity also applies to per-cell backgrounds (selections, ANSI-colored
backgrounds), so the wallpaper shows through them at the same ratio.

`background-image-mode` selects how the image is sized to the window:

| Mode | Behavior |
|------|----------|
| `fill` (default) | Cover the window, cropping the longer axis |
| `fit` | Letterbox so the whole image is visible (edges may stretch) |
| `center` | 1:1 pixel scale, centered |
| `tile` | Repeat at native size with `GL_REPEAT` |

The wallpaper is drawn inside the post-process framebuffer, so a custom shader
set with `--custom-shader` distorts it together with the terminal content.

```text
background-image = C:\Users\me\Pictures\wallpaper.png
background-opacity = 0.85
background-image-mode = fill
```

Save the config (or hot-reload via `Ctrl+,`) to apply changes without
restarting. Clearing the value removes the wallpaper.

## Remote Image Viewing

Phantty now accepts Kitty Graphics protocol image output, so remote shells can
display inline images if they emit `imgcat`/`pdfcat` style escape sequences.

This repository includes two helper scripts for server-side use:

- `tools/imgcat.py` — send an image file to the terminal
- `tools/pdfcat.py` — rasterize one or more PDF pages and send them to the terminal

Examples:

```bash
python3 tools/imgcat.py screenshot.png
python3 tools/imgcat.py diagram.jpg --cols 100
python3 tools/pdfcat.py paper.pdf --page 1
python3 tools/pdfcat.py slides.pdf --page 2 --page 3 --cols 120
```

Notes:

- `imgcat.py` sends PNG directly. Non-PNG inputs require Pillow or ImageMagick.
- `pdfcat.py` requires one of `pdftoppm`, `mutool`, or ImageMagick on the server.
- The scripts are meant to run on the remote machine inside Phantty, not on Windows host side.

## Configuration

Phantty uses a Ghostty-compatible config file format (`key = value` pairs). The config file is loaded from `%APPDATA%\phantty\config`.

Press `Ctrl+,` to open the config file in your default editor, or run `phantty.exe --show-config-path` to print the resolved path.

CLI flags override config file values (last wins).

### Example config

```
font-family = Cascadia Code
font-style = regular
font-size = 14
cursor-style = bar
cursor-style-blink = true
theme = Poimandres
window-height = 32
window-width = 120
scrollback-limit = 10000000
custom-shader = path/to/shader.glsl
background-image = C:\Users\me\Pictures\wallpaper.png
background-opacity = 0.85
background-image-mode = fill
config-file = extra.conf
remote-enabled = false
remote-server-url = https://remote.example.com
remote-server-fingerprint = sha256:...
remote-device-name = Workstation
```

### Available keys

| Key | Default | Description |
|-----|---------|-------------|
| `font-family` | *(none)* | Font family name (falls back to embedded font if unset) |
| `font-style` | `regular` | Font weight: `thin`, `extra-light`, `light`, `regular`, `medium`, `semi-bold`, `bold`, `extra-bold`, `black` |
| `font-size` | `12` | Font size in points |
| `cursor-style` | `block` | Cursor shape: `block`, `bar`, `underline`, `block_hollow` |
| `cursor-style-blink` | `true` | Enable cursor blinking |
| `theme` | *(none)* | Theme name or absolute path (453 Ghostty themes built-in) |
| `custom-shader` | *(none)* | Path to a GLSL post-processing shader |
| `background-image` | *(none)* | Path to an image (PNG/JPG/BMP/GIF/TGA) rendered behind the terminal |
| `background-opacity` | `1.0` | Opacity of the theme tint over the wallpaper (0.0 = image only, 1.0 = image hidden) |
| `background-image-mode` | `fill` | Image scaling: `fill`, `fit`, `center`, or `tile` |
| `window-height` | `0` (auto) | Initial height in cells (min: 4, 0 = auto 80×24) |
| `window-width` | `0` (auto) | Initial width in cells (min: 10, 0 = auto 80×24) |
| `scrollback-limit` | `10000000` | Scrollback buffer limit in bytes |
| `config-file` | *(none)* | Include another config file (prefix with `?` to make optional) |
| `remote-enabled` | `false` | Start the shared outbound RemoteClient for this Phantty instance |
| `remote-server-url` | *(none)* | Cloudflare relay URL, for example `https://remote.example.com` |
| `remote-server-fingerprint` | *(none)* | Expected relay fingerprint for server identity pinning |
| `remote-device-name` | *(none)* | Friendly device name sent with the Phantty WebSocket pairing |

When `remote-enabled = true`, Phantty creates one RemoteClient for the running
instance. All tabs and splits publish PTY output through that shared client, and
the generated session key is printed in the debug console and shown in the
in-window remote status pill. Click the remote status pill to copy the active
session key, or use `Copy Remote Key` from the command center.

## Credits

- Original project: [arya-s/phantty](https://github.com/arya-s/phantty) — the
  Zig + libghostty-vt foundation and the Windows terminal core.
- Terminal emulation: [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty)
  via `libghostty-vt`.
- Image decoding: [stb_image](https://github.com/nothings/stb) (vendored
  through the ghostty dependency).

## License

MIT
