/// Config is the main configuration struct for Phantty.
///
/// Follows Ghostty's configuration format: a simple `key = value` text file.
/// Config is loaded from the following locations (in order, later overrides earlier):
///
///   1. %APPDATA%\phantty\config
///   2. CLI flags (--key value)
///
/// The syntax uses Ghostty's format:
///   - `key = value` pairs (whitespace around `=` is optional)
///   - Lines starting with `#` are comments
///   - Blank lines are ignored
///   - Values can be quoted or unquoted
///   - `config-file` key loads additional config files
///
/// Every config key is also a valid CLI flag: `--key value` or `--key=value`.
const Config = @This();

const std = @import("std");
const directwrite = @import("directwrite.zig");
const themes = @import("themes.zig");

const log = std.log.scoped(.config);

// ============================================================================
// Theme
// ============================================================================

/// RGB color as floats (0.0-1.0)
pub const Color = [3]f32;

pub const Theme = struct {
    palette: [16]Color,
    background: Color,
    foreground: Color,
    cursor_color: Color,
    cursor_text: ?Color,
    selection_background: Color,
    selection_foreground: ?Color,

    /// Default colors matching Ghostty's built-in defaults.
    pub fn default() Theme {
        return .{
            .palette = .{
                hexToColor(0x1d1f21), // 0: black
                hexToColor(0xcc6666), // 1: red
                hexToColor(0xb5bd68), // 2: green
                hexToColor(0xf0c674), // 3: yellow
                hexToColor(0x81a2be), // 4: blue
                hexToColor(0xb294bb), // 5: magenta
                hexToColor(0x8abeb7), // 6: cyan
                hexToColor(0xc5c8c6), // 7: white
                hexToColor(0x666666), // 8: bright black
                hexToColor(0xd54e53), // 9: bright red
                hexToColor(0xb9ca4a), // 10: bright green
                hexToColor(0xe7c547), // 11: bright yellow
                hexToColor(0x7aa6da), // 12: bright blue
                hexToColor(0xc397d8), // 13: bright magenta
                hexToColor(0x70c0b1), // 14: bright cyan
                hexToColor(0xeaeaea), // 15: bright white
            },
            .background = hexToColor(0x282c34),
            .foreground = hexToColor(0xffffff),
            .cursor_color = hexToColor(0xffffff),
            .cursor_text = null,
            .selection_background = hexToColor(0xffffff),
            .selection_foreground = hexToColor(0x282c34),
        };
    }

    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Theme {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        return parseThemeContent(content);
    }

    pub fn parseThemeContent(content: []const u8) Theme {
        var theme = Theme.default();

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

                if (std.mem.eql(u8, key, "palette")) {
                    if (std.mem.indexOf(u8, value, "=")) |idx_eq| {
                        const idx_str = value[0..idx_eq];
                        const color_str = value[idx_eq + 1 ..];
                        const idx = std.fmt.parseInt(u8, idx_str, 10) catch continue;
                        if (idx < 16) {
                            if (parseColor(color_str)) |color| {
                                theme.palette[idx] = color;
                            }
                        }
                    }
                } else if (std.mem.eql(u8, key, "background")) {
                    if (parseColor(value)) |color| theme.background = color;
                } else if (std.mem.eql(u8, key, "foreground")) {
                    if (parseColor(value)) |color| theme.foreground = color;
                } else if (std.mem.eql(u8, key, "cursor-color")) {
                    if (parseColor(value)) |color| theme.cursor_color = color;
                } else if (std.mem.eql(u8, key, "cursor-text")) {
                    if (parseColor(value)) |color| theme.cursor_text = color;
                } else if (std.mem.eql(u8, key, "selection-background")) {
                    if (parseColor(value)) |color| theme.selection_background = color;
                } else if (std.mem.eql(u8, key, "selection-foreground")) {
                    if (parseColor(value)) |color| theme.selection_foreground = color;
                }
            }
        }

        return theme;
    }
};

// ============================================================================
// Cursor
// ============================================================================

pub const CursorStyle = enum {
    block,
    bar,
    underline,
    block_hollow,
};

// ============================================================================
// Font Weight
// ============================================================================

pub const FontWeight = enum {
    thin,
    extra_light,
    light,
    regular,
    medium,
    semi_bold,
    bold,
    extra_bold,
    black,

    pub fn toDwriteWeight(self: FontWeight) directwrite.DWRITE_FONT_WEIGHT {
        return switch (self) {
            .thin => .THIN,
            .extra_light => .EXTRA_LIGHT,
            .light => .LIGHT,
            .regular => .NORMAL,
            .medium => .MEDIUM,
            .semi_bold => .SEMI_BOLD,
            .bold => .BOLD,
            .extra_bold => .EXTRA_BOLD,
            .black => .BLACK,
        };
    }

    pub fn parse(s: []const u8) ?FontWeight {
        if (std.mem.eql(u8, s, "thin")) return .thin;
        if (std.mem.eql(u8, s, "extra-light") or std.mem.eql(u8, s, "extralight")) return .extra_light;
        if (std.mem.eql(u8, s, "light")) return .light;
        if (std.mem.eql(u8, s, "regular") or std.mem.eql(u8, s, "normal")) return .regular;
        if (std.mem.eql(u8, s, "medium")) return .medium;
        if (std.mem.eql(u8, s, "semi-bold") or std.mem.eql(u8, s, "semibold")) return .semi_bold;
        if (std.mem.eql(u8, s, "bold")) return .bold;
        if (std.mem.eql(u8, s, "extra-bold") or std.mem.eql(u8, s, "extrabold")) return .extra_bold;
        if (std.mem.eql(u8, s, "black") or std.mem.eql(u8, s, "heavy")) return .black;
        return null;
    }
};

// ============================================================================
// Config Fields
// ============================================================================

/// Font family name. Ghostty default: unset (system default).
/// We default to an empty string meaning "use system default".
@"font-family": []const u8 = "",

/// Font weight/style. Ghostty default: regular (default).
@"font-style": FontWeight = .regular,

/// Font size in points. Ghostty default: 13 (macOS), 12 (other).
@"font-size": u32 = 12,

/// Cursor shape: block, bar, underline, block_hollow.
@"cursor-style": CursorStyle = .block,

/// Whether the cursor should blink.
@"cursor-style-blink": bool = true,

/// Theme name (looked up in themes/ directory) or file path.
theme: ?[]const u8 = null,

/// Path to a Ghostty-compatible custom GLSL shader for post-processing.
@"custom-shader": ?[]const u8 = null,

/// Initial terminal height in cells (min: 4, 0 = auto).
@"window-height": u16 = 0,

/// Initial terminal width in cells (min: 10, 0 = auto).
@"window-width": u16 = 0,

/// Scrollback buffer limit in bytes.
@"scrollback-limit": u32 = 10_000_000,

/// The shell to run in the terminal. Accepted values:
///   - "cmd" — run Command Prompt (cmd.exe, default)
///   - "powershell" — run Windows PowerShell (powershell.exe)
///   - "pwsh" — run PowerShell 7+ (pwsh.exe)
///   - "wsl" — run Windows Subsystem for Linux (wsl.exe)
///   - Any other value is treated as a raw command path
shell: []const u8 = "cmd",

/// Show a debug FPS overlay in the bottom-right corner.
@"phantty-debug-fps": bool = false,
@"phantty-debug-draw-calls": bool = false,

// ============================================================================
// Split pane configuration
// ============================================================================

/// Opacity of unfocused split panes (0.15 - 1.0). Lower values make
/// unfocused splits more visible. Matches Ghostty's unfocused-split-opacity.
@"unfocused-split-opacity": f32 = 0.7,

/// Color of the divider line between split panes (hex #RRGGBB).
@"split-divider-color": ?Color = null,

/// When true, moving the mouse into a split pane focuses it.
@"focus-follows-mouse": bool = false,

/// Load an additional config file. Can be repeated. Relative paths are
/// resolved relative to the file containing the directive. Prefix with
/// `?` to make optional (missing file is silently ignored).
@"config-file": ?[]const u8 = null,

// ============================================================================
// Color Overrides (applied on top of theme)
// ============================================================================

/// Background color override. Overrides the theme's background color.
/// Specified as hex (#RRGGBB or RRGGBB).
background: ?Color = null,

/// Foreground color override. Overrides the theme's foreground color.
/// Specified as hex (#RRGGBB or RRGGBB).
foreground: ?Color = null,

/// Cursor color override. Overrides the theme's cursor color.
/// Specified as hex (#RRGGBB or RRGGBB).
@"cursor-color": ?Color = null,

/// Cursor text color override. Overrides the theme's cursor text color.
/// Specified as hex (#RRGGBB or RRGGBB).
@"cursor-text": ?Color = null,

/// Selection background color override.
/// Specified as hex (#RRGGBB or RRGGBB).
@"selection-background": ?Color = null,

/// Selection foreground color override.
/// Specified as hex (#RRGGBB or RRGGBB).
@"selection-foreground": ?Color = null,

/// Palette color overrides. Indexed 0-15 for the 16 ANSI colors.
/// Use syntax: palette = N=#RRGGBB (e.g., palette = 0=#000000)
palette_overrides: [16]?Color = .{null} ** 16,

// ============================================================================
// Window Options
// ============================================================================

/// Force the window title to this value. Programs cannot override it.
title: ?[]const u8 = null,

/// Start the window maximized.
maximize: bool = false,

/// Start the window in fullscreen mode.
fullscreen: bool = false,

// ============================================================================
// Resolved State (not serialized)
// ============================================================================

/// The resolved theme (from theme file or defaults).
resolved_theme: Theme = Theme.default(),

/// Path to the loaded config file (for diagnostics), or null.
config_path: ?[]const u8 = null,

/// Strings allocated during config loading that must be freed.
_owned_strings: std.ArrayListUnmanaged([]const u8) = .empty,

// ============================================================================
// Cleanup
// ============================================================================

/// Free any memory owned by this Config.
pub fn deinit(self: *const Config, allocator: std.mem.Allocator) void {
    if (self.config_path) |path| {
        allocator.free(path);
    }
    for (self._owned_strings.items) |s| {
        allocator.free(s);
    }
    // We need a mutable copy to deinit the list itself
    var list = self._owned_strings;
    list.deinit(allocator);
}

// ============================================================================
// Loading
// ============================================================================

/// Load config from the default file location and CLI args.
/// Order: defaults → config file → CLI flags (last wins).
pub fn load(allocator: std.mem.Allocator) !Config {
    var self = Config{};

    // 1. Try loading from config file
    if (configFilePath(allocator)) |path| {
        self.config_path = path;
        self.loadFile(allocator, path) catch |err| {
            log.warn("failed to load config file {s}: {}", .{ path, err });
        };
    } else |_| {}

    // 2. Override with CLI args (highest priority)
    try self.loadCliArgs(allocator);

    // 3. Resolve theme
    if (self.theme) |theme_name| {
        self.resolveTheme(allocator, theme_name);
    }

    // 4. Apply color overrides on top of resolved theme
    self.applyColorOverrides();

    return self;
}

/// Return the default config file path: %APPDATA%\phantty\config
pub fn configFilePath(allocator: std.mem.Allocator) ![]const u8 {
    // Use APPDATA on Windows (native build target)
    // When cross-compiling from Linux, this won't resolve at build time,
    // so we also support XDG_CONFIG_HOME / HOME fallbacks for testing.
    if (std.process.getEnvVarOwned(allocator, "APPDATA")) |appdata| {
        defer allocator.free(appdata);
        return std.fs.path.join(allocator, &.{ appdata, "phantty", "config" });
    } else |_| {}

    // XDG fallback (works on Linux/WSL for testing)
    if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg| {
        defer allocator.free(xdg);
        return std.fs.path.join(allocator, &.{ xdg, "phantty", "config" });
    } else |_| {}

    // HOME fallback
    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".config", "phantty", "config" });
    } else |_| {}

    return error.NoConfigPath;
}

/// Print the path that would be used for the config file.
pub fn printConfigPath(allocator: std.mem.Allocator) void {
    if (configFilePath(allocator)) |path| {
        defer allocator.free(path);
        std.debug.print("Config file: {s}\n", .{path});
    } else |_| {
        std.debug.print("Config file: (could not determine path)\n", .{});
    }
}

// ============================================================================
// String Ownership
// ============================================================================

/// Duplicate a string and track it for cleanup in deinit.
fn dupeString(self: *Config, allocator: std.mem.Allocator, value: []const u8) ?[]const u8 {
    const duped = allocator.dupe(u8, value) catch return null;
    self._owned_strings.append(allocator, duped) catch {
        allocator.free(duped);
        return null;
    };
    return duped;
}

// ============================================================================
// File Parsing
// ============================================================================

/// Load config values from a file. Values override current state.
fn loadFile(self: *Config, allocator: std.mem.Allocator, path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    const dir = std.fs.path.dirname(path) orelse ".";

    self.parseContent(allocator, content, dir);
}

/// Parse config file content. `base_dir` is used to resolve relative
/// `config-file` paths.
fn parseContent(self: *Config, allocator: std.mem.Allocator, content: []const u8, base_dir: []const u8) void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
            const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            const raw_value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");
            // Strip optional quotes
            const value = stripQuotes(raw_value);

            self.applyKeyValue(allocator, key, value, base_dir);
        }
    }
}

/// Apply a single key = value pair to the config.
fn applyKeyValue(self: *Config, allocator: std.mem.Allocator, key: []const u8, value: []const u8, base_dir: []const u8) void {
    if (std.mem.eql(u8, key, "font-family")) {
        self.@"font-family" = self.dupeString(allocator, value) orelse return;
    } else if (std.mem.eql(u8, key, "font-style")) {
        if (FontWeight.parse(value)) |w| {
            self.@"font-style" = w;
        } else {
            log.warn("unknown font-style: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "font-size")) {
        self.@"font-size" = std.fmt.parseInt(u32, value, 10) catch {
            log.warn("invalid font-size: {s}", .{value});
            return;
        };
    } else if (std.mem.eql(u8, key, "cursor-style")) {
        if (std.mem.eql(u8, value, "block")) {
            self.@"cursor-style" = .block;
        } else if (std.mem.eql(u8, value, "bar")) {
            self.@"cursor-style" = .bar;
        } else if (std.mem.eql(u8, value, "underline")) {
            self.@"cursor-style" = .underline;
        } else if (std.mem.eql(u8, value, "block_hollow")) {
            self.@"cursor-style" = .block_hollow;
        } else {
            log.warn("unknown cursor-style: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "cursor-style-blink")) {
        if (std.mem.eql(u8, value, "true")) {
            self.@"cursor-style-blink" = true;
        } else if (std.mem.eql(u8, value, "false")) {
            self.@"cursor-style-blink" = false;
        } else {
            log.warn("invalid cursor-style-blink: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "theme")) {
        self.theme = self.dupeString(allocator, value) orelse return;
    } else if (std.mem.eql(u8, key, "custom-shader")) {
        self.@"custom-shader" = self.dupeString(allocator, value) orelse return;
    } else if (std.mem.eql(u8, key, "window-height")) {
        const v = std.fmt.parseInt(u16, value, 10) catch {
            log.warn("invalid window-height: {s}", .{value});
            return;
        };
        self.@"window-height" = @max(4, v);
    } else if (std.mem.eql(u8, key, "window-width")) {
        const v = std.fmt.parseInt(u16, value, 10) catch {
            log.warn("invalid window-width: {s}", .{value});
            return;
        };
        self.@"window-width" = @max(10, v);
    } else if (std.mem.eql(u8, key, "scrollback-limit")) {
        self.@"scrollback-limit" = std.fmt.parseInt(u32, value, 10) catch {
            log.warn("invalid scrollback-limit: {s}", .{value});
            return;
        };
    } else if (std.mem.eql(u8, key, "shell")) {
        self.shell = self.dupeString(allocator, value) orelse return;
    } else if (std.mem.eql(u8, key, "phantty-debug-fps")) {
        if (std.mem.eql(u8, value, "true")) {
            self.@"phantty-debug-fps" = true;
        } else if (std.mem.eql(u8, value, "false")) {
            self.@"phantty-debug-fps" = false;
        } else {
            log.warn("invalid phantty-debug-fps: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "phantty-debug-draw-calls")) {
        if (std.mem.eql(u8, value, "true")) {
            self.@"phantty-debug-draw-calls" = true;
        } else if (std.mem.eql(u8, value, "false")) {
            self.@"phantty-debug-draw-calls" = false;
        } else {
            log.warn("invalid phantty-debug-draw-calls: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "unfocused-split-opacity")) {
        if (std.fmt.parseFloat(f32, value)) |opacity| {
            self.@"unfocused-split-opacity" = @max(0.15, @min(1.0, opacity));
        } else |_| {
            log.warn("invalid unfocused-split-opacity: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "split-divider-color")) {
        if (parseColor(value)) |color| {
            self.@"split-divider-color" = color;
        } else {
            log.warn("invalid split-divider-color: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "focus-follows-mouse")) {
        if (std.mem.eql(u8, value, "true")) {
            self.@"focus-follows-mouse" = true;
        } else if (std.mem.eql(u8, value, "false")) {
            self.@"focus-follows-mouse" = false;
        } else {
            log.warn("invalid focus-follows-mouse: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "config-file")) {
        self.loadConfigFileDirective(allocator, value, base_dir);
    } else if (std.mem.eql(u8, key, "background")) {
        if (parseColor(value)) |color| {
            self.background = color;
        } else {
            log.warn("invalid background color: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "foreground")) {
        if (parseColor(value)) |color| {
            self.foreground = color;
        } else {
            log.warn("invalid foreground color: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "cursor-color")) {
        if (parseColor(value)) |color| {
            self.@"cursor-color" = color;
        } else {
            log.warn("invalid cursor-color: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "cursor-text")) {
        if (parseColor(value)) |color| {
            self.@"cursor-text" = color;
        } else {
            log.warn("invalid cursor-text: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "selection-background")) {
        if (parseColor(value)) |color| {
            self.@"selection-background" = color;
        } else {
            log.warn("invalid selection-background: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "selection-foreground")) {
        if (parseColor(value)) |color| {
            self.@"selection-foreground" = color;
        } else {
            log.warn("invalid selection-foreground: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "palette")) {
        // Syntax: palette = N=COLOR (e.g., palette = 0=#000000)
        if (std.mem.indexOf(u8, value, "=")) |eq_idx| {
            const idx_str = value[0..eq_idx];
            const color_str = value[eq_idx + 1 ..];
            const idx = std.fmt.parseInt(u8, idx_str, 10) catch {
                log.warn("invalid palette index: {s}", .{idx_str});
                return;
            };
            if (idx >= 16) {
                log.warn("palette index out of range (0-15): {}", .{idx});
                return;
            }
            if (parseColor(color_str)) |color| {
                self.palette_overrides[idx] = color;
            } else {
                log.warn("invalid palette color: {s}", .{color_str});
            }
        } else {
            log.warn("invalid palette syntax, expected N=COLOR: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "title")) {
        self.title = self.dupeString(allocator, value) orelse return;
    } else if (std.mem.eql(u8, key, "maximize")) {
        if (std.mem.eql(u8, value, "true")) {
            self.maximize = true;
        } else if (std.mem.eql(u8, value, "false")) {
            self.maximize = false;
        } else {
            log.warn("invalid maximize value: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "fullscreen")) {
        if (std.mem.eql(u8, value, "true")) {
            self.fullscreen = true;
        } else if (std.mem.eql(u8, value, "false")) {
            self.fullscreen = false;
        } else {
            log.warn("invalid fullscreen value: {s}", .{value});
        }
    } else {
        // Silently ignore unknown keys (theme files reuse the same format
        // and may contain keys we don't handle, like palette).
    }
}

/// Handle the `config-file` directive: load an additional config file.
fn loadConfigFileDirective(self: *Config, allocator: std.mem.Allocator, raw_path: []const u8, base_dir: []const u8) void {
    if (raw_path.len == 0) return;

    // Optional prefix: `?` means ignore if missing
    const optional = raw_path[0] == '?';
    const path_str = if (optional) raw_path[1..] else raw_path;
    if (path_str.len == 0) return;

    // Resolve relative paths against the containing file's directory
    const resolved = if (std.fs.path.isAbsolute(path_str))
        allocator.dupe(u8, path_str) catch return
    else
        std.fs.path.join(allocator, &.{ base_dir, path_str }) catch return;
    defer allocator.free(resolved);

    self.loadFile(allocator, resolved) catch |err| {
        if (!optional) {
            log.warn("failed to load config-file '{s}': {}", .{ resolved, err });
        }
    };
}

// ============================================================================
// CLI Argument Parsing
// ============================================================================

/// Parse CLI args and apply them to the config (highest priority).
fn loadCliArgs(self: *Config, allocator: std.mem.Allocator) !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // Skip non-flag arguments
        if (arg.len < 2 or arg[0] != '-') continue;

        // Handle --key=value form
        if (std.mem.indexOf(u8, arg, "=")) |eq_pos| {
            const flag = stripDashes(arg[0..eq_pos]);
            const value = arg[eq_pos + 1 ..];
            self.applyKeyValue(allocator, flag, value, ".");
            continue;
        }

        // Handle --key value form (and short aliases)
        const flag = stripDashes(arg);

        // Special commands (not config keys, handled by main)
        if (std.mem.eql(u8, flag, "list-fonts") or
            std.mem.eql(u8, flag, "list-themes") or
            std.mem.eql(u8, flag, "test-font-discovery") or
            std.mem.eql(u8, flag, "help") or
            std.mem.eql(u8, flag, "h") or
            std.mem.eql(u8, flag, "show-config-path"))
        {
            continue;
        }

        // Short aliases and backward-compatible renames
        const resolved_flag = if (std.mem.eql(u8, flag, "f") or std.mem.eql(u8, flag, "font"))
            "font-family"
        else if (std.mem.eql(u8, flag, "shader"))
            "custom-shader"
        else
            flag;

        // Consume next arg as value
        if (i + 1 < args.len) {
            i += 1;
            self.applyKeyValue(allocator, resolved_flag, args[i], ".");
        } else {
            log.warn("flag --{s} requires a value", .{flag});
        }
    }
}

/// Check if CLI args contain a specific command flag (e.g. --list-fonts).
pub fn hasCommand(allocator: std.mem.Allocator, command: []const u8) bool {
    const args = std.process.argsAlloc(allocator) catch return false;
    defer std.process.argsFree(allocator, args);

    for (args[1..]) |arg| {
        const flag = stripDashes(arg);
        if (std.mem.eql(u8, flag, command)) return true;
    }
    return false;
}

// ============================================================================
// Theme Resolution
// ============================================================================

/// Resolve a theme by name or path. Search order (like Ghostty):
///   1. Absolute path → load directly
///   2. User themes:  %APPDATA%\phantty\themes\<name>
///   3. Embedded themes compiled into the binary
fn resolveTheme(self: *Config, allocator: std.mem.Allocator, theme_name: []const u8) void {
    // 1. Absolute path — load directly
    if (std.fs.path.isAbsolute(theme_name)) {
        if (Theme.loadFromFile(allocator, theme_name)) |theme| {
            self.resolved_theme = theme;
            log.info("loaded theme from absolute path: {s}", .{theme_name});
            return;
        } else |_| {}
        log.warn("theme file not found: {s}", .{theme_name});
        return;
    }

    // 2. User themes: %APPDATA%\phantty\themes\<name>
    if (std.process.getEnvVarOwned(allocator, "APPDATA")) |appdata| {
        defer allocator.free(appdata);
        const path = std.fs.path.join(allocator, &.{ appdata, "phantty", "themes", theme_name }) catch return;
        defer allocator.free(path);
        if (Theme.loadFromFile(allocator, path)) |theme| {
            self.resolved_theme = theme;
            log.info("loaded theme '{s}' from user dir: {s}", .{ theme_name, path });
            return;
        } else |_| {}
    } else |_| {}

    // 3. Embedded themes compiled into the binary
    if (themes.get(theme_name)) |data| {
        self.resolved_theme = Theme.parseThemeContent(data);
        log.info("loaded embedded theme: {s}", .{theme_name});
        return;
    }

    log.warn("theme not found: {s}", .{theme_name});
}

/// Apply top-level color overrides to the resolved theme.
/// Called after theme resolution so user overrides take precedence.
fn applyColorOverrides(self: *Config) void {
    if (self.background) |color| {
        self.resolved_theme.background = color;
    }
    if (self.foreground) |color| {
        self.resolved_theme.foreground = color;
    }
    if (self.@"cursor-color") |color| {
        self.resolved_theme.cursor_color = color;
    }
    if (self.@"cursor-text") |color| {
        self.resolved_theme.cursor_text = color;
    }
    if (self.@"selection-background") |color| {
        self.resolved_theme.selection_background = color;
    }
    if (self.@"selection-foreground") |color| {
        self.resolved_theme.selection_foreground = color;
    }
    // Apply palette overrides
    for (self.palette_overrides, 0..) |maybe_color, i| {
        if (maybe_color) |color| {
            self.resolved_theme.palette[i] = color;
        }
    }
}

// ============================================================================
// Help
// ============================================================================

pub fn listThemes() void {
    std.debug.print("Available built-in themes ({} total):\n\n", .{themes.entries.len});
    for (&themes.entries) |*entry| {
        std.debug.print("  {s}\n", .{entry.name});
    }
    std.debug.print("\nUser themes in %APPDATA%\\phantty\\themes\\ take priority.\n", .{});
    std.debug.print("Set with: theme = <name>\n", .{});
}

pub fn printHelp() void {
    std.debug.print(
        \\Phantty - A terminal emulator
        \\
        \\Usage: phantty [options]
        \\
        \\Options:
        \\  --font-family <name>         Font family (default: embedded fallback)
        \\  -f <name>                    Alias for --font-family
        \\  --font-style <style>         Font weight (default: regular)
        \\                               Values: thin, extra-light, light, regular, medium,
        \\                                       semi-bold, bold, extra-bold, black
        \\  --font-size <pt>             Font size in points (default: 12)
        \\  --cursor-style <style>       Cursor shape (default: "block")
        \\                               Values: block, bar, underline, block_hollow
        \\  --cursor-style-blink <bool>  Enable cursor blinking (default: true)
        \\  --theme <name|path>          Theme name or file path
        \\  --custom-shader <path>       Ghostty-compatible GLSL post-processing shader
        \\  --window-height <rows>       Initial height in cells (default: 0=auto, min: 4)
        \\  --window-width <cols>        Initial width in cells (default: 0=auto, min: 10)
        \\  --scrollback-limit <bytes>   Scrollback buffer size (default: 10000000)
        \\  --config-file <path>         Load additional config file (prefix ? for optional)
        \\
        \\Color Options (override theme):
        \\  --background <color>         Background color (#RRGGBB or RRGGBB)
        \\  --foreground <color>         Foreground/text color
        \\  --cursor-color <color>       Cursor color
        \\  --cursor-text <color>        Text color under cursor
        \\  --selection-background <color>  Selection background color
        \\  --selection-foreground <color>  Selection text color
        \\  --palette <N=color>          Set ANSI color N (0-15), e.g. --palette 1=#ff0000
        \\
        \\Window Options:
        \\  --title <text>               Force window title (programs cannot override)
        \\  --maximize <bool>            Start maximized (default: false)
        \\  --fullscreen <bool>          Start in fullscreen (default: false)
        \\
        \\Debug:
        \\  --phantty-debug-fps <bool>   Show FPS overlay (default: false)
        \\  --phantty-debug-draw-calls <bool> Show draw call count overlay (default: false)
        \\
        \\Commands:
        \\  --show-config-path           Print the config file path and exit
        \\  --list-fonts                 List all available system fonts
        \\  --list-themes                List all available themes
        \\  --test-font-discovery        Test font discovery for common fonts
        \\  --help, -h                   Show this help message
        \\
        \\Config file: %APPDATA%\phantty\config
        \\User themes: %APPDATA%\phantty\themes\
        \\
        \\Config file uses Ghostty's key = value format. Example:
        \\
        \\  font-family = Cascadia Code
        \\  font-size = 16
        \\  theme = Catppuccin Mocha
        \\  cursor-style = bar
        \\  background = #1a1b26
        \\  foreground = #c0caf5
        \\  palette = 1=#f7768e
        \\
        \\Examples:
        \\  phantty --font-family "Cascadia Code"
        \\  phantty --font-family "JetBrains Mono" --font-style bold
        \\  phantty --cursor-style bar --cursor-style-blink=false
        \\  phantty --background "#1a1b26" --foreground "#c0caf5"
        \\  phantty --theme poimandres
        \\  phantty --window-height 40 --window-width 120
        \\
    , .{});
}

// ============================================================================
// Ensure config exists on startup
// ============================================================================

/// Ensure the config directory and file exist. Called at startup so the
/// file watcher can observe the directory from the very beginning.
/// If the config file doesn't exist yet, it is created with the default
/// template (same one used by Ctrl+,).
pub fn ensureConfigExists(allocator: std.mem.Allocator) void {
    const path = configFilePath(allocator) catch return;
    defer allocator.free(path);

    // Create parent directory recursively
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch return;
    }

    // Create config file with default template if it doesn't exist
    if (std.fs.cwd().createFile(path, .{ .exclusive = true })) |file| {
        file.writeAll(default_config_template) catch {};
        file.close();
        log.info("created default config file: {s}", .{path});
    } else |_| {}
}

// ============================================================================
// Open / Edit Config (Ctrl+, keybinding)
// ============================================================================

/// Ensure the config file exists (create with default template if not)
/// and open it in notepad.exe. Mimics Ghostty's Ctrl+, behavior.
pub fn openConfigInEditor(allocator: std.mem.Allocator) void {
    std.debug.print("[config] openConfigInEditor called\n", .{});

    const path = configFilePath(allocator) catch |err| {
        std.debug.print("[config] ERROR: cannot determine config path: {}\n", .{err});
        return;
    };
    defer allocator.free(path);
    std.debug.print("[config] config path: {s}\n", .{path});

    // Create parent directory recursively
    if (std.fs.path.dirname(path)) |dir| {
        std.debug.print("[config] creating directory: {s}\n", .{dir});
        std.fs.cwd().makePath(dir) catch |err| {
            std.debug.print("[config] ERROR: failed to create directory: {}\n", .{err});
            return;
        };
    }

    // Create config file with default template if it doesn't exist
    if (std.fs.cwd().createFile(path, .{ .exclusive = true })) |file| {
        file.writeAll(default_config_template) catch {};
        file.close();
        std.debug.print("[config] created default config file\n", .{});
    } else |err| switch (err) {
        error.PathAlreadyExists => {
            std.debug.print("[config] config file already exists\n", .{});
        },
        else => {
            std.debug.print("[config] ERROR: failed to create config file: {}\n", .{err});
            return;
        },
    }

    // Open in notepad.exe
    std.debug.print("[config] spawning notepad.exe with path: {s}\n", .{path});
    const path_z = allocator.dupeZ(u8, path) catch |err| {
        std.debug.print("[config] ERROR: failed to dupe path: {}\n", .{err});
        return;
    };
    defer allocator.free(path_z);

    var child = std.process.Child.init(
        &.{ "notepad.exe", path_z },
        allocator,
    );
    child.spawn() catch |err| {
        std.debug.print("[config] ERROR: failed to spawn notepad.exe: {}\n", .{err});
        return;
    };
    // Don't call wait() — let notepad run independently

    std.debug.print("[config] notepad.exe spawned successfully\n", .{});
}

/// Update or append a single `key = value` line in the main config file.
/// This is used by the built-in Settings page; the file watcher applies the
/// change through the normal hot-reload path.
pub fn setConfigValue(allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    ensureConfigExists(allocator);

    const path = try configFilePath(allocator);
    defer allocator.free(path);

    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    defer if (content.len > 0) allocator.free(content);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    var replaced = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trimRight(u8, line_raw, "\r");
        if (!replaced and configLineMatchesKey(line, key)) {
            try out.writer(allocator).print("{s} = {s}\n", .{ key, value });
            replaced = true;
        } else if (line.len > 0) {
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
        }
    }

    if (!replaced) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
            try out.append(allocator, '\n');
        }
        try out.writer(allocator).print("{s} = {s}\n", .{ key, value });
    }

    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(out.items);
}

fn configLineMatchesKey(line: []const u8, key: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return false;
    const eq_pos = std.mem.indexOf(u8, trimmed, "=") orelse return false;
    const lhs = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
    return std.mem.eql(u8, lhs, key);
}

const default_config_template =
    \\# Phantty Configuration
    \\# Ghostty-compatible key = value format
    \\# See: phantty --help
    \\
    \\# Font
    \\# font-family = JetBrains Mono
    \\# font-style = semi-bold
    \\# font-size = 14
    \\
    \\# Cursor
    \\# cursor-style = block
    \\# cursor-style-blink = true
    \\# cursor-color = #ffffff
    \\# cursor-text = #000000
    \\
    \\# Theme (name or file path)
    \\# theme =
    \\
    \\# Color overrides (override theme colors)
    \\# background = #282c34
    \\# foreground = #ffffff
    \\# selection-background = #ffffff
    \\# selection-foreground = #282c34
    \\# palette = 0=#1d1f21
    \\# palette = 1=#cc6666
    \\
    \\# Custom post-processing shader (GLSL)
    \\# custom-shader =
    \\
    \\# Window
    \\# window-height = 28
    \\# window-width = 110
    \\# title =
    \\# maximize = false
    \\# fullscreen = false
    \\
    \\# Shell (cmd, powershell, pwsh, wsl, or a custom path)
    \\# shell = cmd
    \\
    \\# Scrollback buffer size in bytes (default: 10MB)
    \\# scrollback-limit = 10000000
    \\
    \\# Debug
    \\# phantty-debug-fps = false
    \\# phantty-debug-draw-calls = false
    \\
    \\# Load additional config files
    \\# config-file = ?optional/extra-config
    \\
;

// ============================================================================
// Utilities
// ============================================================================

fn stripDashes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '-' and s[1] == '-') return s[2..];
    if (s.len >= 1 and s[0] == '-') return s[1..];
    return s;
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    return s;
}

pub fn hexToColor(hex: u24) Color {
    const r: f32 = @as(f32, @floatFromInt((hex >> 16) & 0xFF)) / 255.0;
    const g: f32 = @as(f32, @floatFromInt((hex >> 8) & 0xFF)) / 255.0;
    const b: f32 = @as(f32, @floatFromInt(hex & 0xFF)) / 255.0;
    return .{ r, g, b };
}

pub fn parseColor(s: []const u8) ?Color {
    const hex_str = if (s.len > 0 and s[0] == '#') s[1..] else s;
    if (hex_str.len != 6) return null;

    const hex = std.fmt.parseInt(u24, hex_str, 16) catch return null;
    return hexToColor(hex);
}
