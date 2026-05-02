<h1>
  <p align="center">
    <img src="assets/phantty.png" alt="Phantty logo" width="128">
    <br>Phantty
  </p>
</h1>

A Windows terminal written in Zig, powered by [libghostty-vt](https://github.com/ghostty-org/ghostty) for terminal emulation.

## Features

- **Ghostty's terminal emulation** - Uses libghostty-vt for VT parsing and terminal state
- **DirectWrite font discovery** - Find system fonts by name
- **FreeType rendering** - High-quality glyph rasterization
- **Per-glyph font fallback** - Automatic fallback for missing characters
- **Sprite rendering** - Box drawing, block elements, braille patterns, powerline symbols
- **Ghostty-style font metrics** - Proper ascent/descent/line_gap from hhea/OS2 tables
- **Theme support** - Ghostty-compatible theme files (default: Poimandres)

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

Phantty now supports two Windows distribution formats:

- `phantty.exe` — portable build, run directly without installation
- `phantty-setup.exe` — installer build, installs to the current user's profile and creates a Start menu shortcut

Build both artifacts with:

```powershell
powershell -ExecutionPolicy Bypass -File .\packaging\windows\package.ps1
```

This produces:

```text
zig-out\dist\portable\phantty.exe
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
- `phantty-windows-setup-vX.Y.Z.exe`

GitHub generates the release notes automatically, and the workflow prepends a
short asset summary for the portable and installer builds.

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
  --window-height <rows>       Initial window height in cells (default: 0=auto, min: 4)
  --window-width <cols>        Initial window width in cells (default: 0=auto, min: 10)
  --list-fonts                 List available system fonts
  --test-font-discovery        Test DirectWrite font discovery
  --help                       Show help
```

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
config-file = extra.conf
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
| `window-height` | `0` (auto) | Initial height in cells (min: 4, 0 = auto 80×24) |
| `window-width` | `0` (auto) | Initial width in cells (min: 10, 0 = auto 80×24) |
| `scrollback-limit` | `10000000` | Scrollback buffer limit in bytes |
| `config-file` | *(none)* | Include another config file (prefix with `?` to make optional) |

## License

MIT
