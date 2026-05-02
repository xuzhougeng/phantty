//! Phantty entry point.
//!
//! Handles CLI args and special commands, then creates an App which
//! manages one or more AppWindow instances. Most terminal logic lives
//! in AppWindow.zig.

const std = @import("std");
const Config = @import("config.zig");
const directwrite = @import("directwrite.zig");
const App = @import("App.zig");
const image_decoder = @import("image_decoder.zig");

// ============================================================================
// Font Discovery Test Functions (use --list-fonts or --test-font-discovery)
// ============================================================================

fn listSystemFonts(allocator: std.mem.Allocator) !void {
    std.debug.print("Listing system fonts via DirectWrite...\n\n", .{});

    var dw = directwrite.FontDiscovery.init() catch |err| {
        std.debug.print("Failed to initialize DirectWrite: {}\n", .{err});
        return err;
    };
    defer dw.deinit();

    const families = try dw.listFontFamilies(allocator);
    defer {
        for (families) |f| allocator.free(f);
        allocator.free(families);
    }

    std.debug.print("Found {} font families:\n", .{families.len});
    for (families, 0..) |family, i| {
        std.debug.print("  {d:4}. {s}\n", .{ i + 1, family });
    }
}

fn testFontDiscovery(allocator: std.mem.Allocator) !void {
    std.debug.print("Testing font discovery...\n\n", .{});

    var dw = directwrite.FontDiscovery.init() catch |err| {
        std.debug.print("Failed to initialize DirectWrite: {}\n", .{err});
        return err;
    };
    defer dw.deinit();

    // Test fonts to look for
    const test_fonts = [_][]const u8{
        "JetBrains Mono",
        "Cascadia Code",
        "Consolas",
        "Courier New",
        "Arial",
        "Segoe UI",
        "NonExistentFont12345",
    };

    for (test_fonts) |font_name| {
        std.debug.print("Looking for '{s}'... ", .{font_name});

        if (dw.findFontFilePath(allocator, font_name, .NORMAL, .NORMAL)) |maybe_result| {
            if (maybe_result) |result| {
                var r = result;
                defer r.deinit();
                std.debug.print("FOUND\n", .{});
                std.debug.print("  Path: {s}\n", .{result.path});
                std.debug.print("  Face index: {}\n\n", .{result.face_index});
            } else {
                std.debug.print("NOT FOUND\n\n", .{});
            }
        } else |err| {
            std.debug.print("ERROR: {}\n\n", .{err});
        }
    }
}

pub fn main() !void {
    std.debug.print("Phantty starting...\n", .{});
    image_decoder.install();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Handle special commands before loading full config
    if (Config.hasCommand(allocator, "help") or Config.hasCommand(allocator, "h")) {
        Config.printHelp();
        return;
    }
    if (Config.hasCommand(allocator, "list-fonts")) {
        try listSystemFonts(allocator);
        return;
    }
    if (Config.hasCommand(allocator, "list-themes")) {
        Config.listThemes();
        return;
    }
    if (Config.hasCommand(allocator, "test-font-discovery")) {
        try testFontDiscovery(allocator);
        return;
    }
    if (Config.hasCommand(allocator, "show-config-path")) {
        Config.printConfigPath(allocator);
        return;
    }

    // Load configuration: defaults → config file → CLI flags
    const cfg = try Config.load(allocator);
    defer cfg.deinit(allocator);

    if (cfg.config_path) |path| {
        std.debug.print("Config loaded from: {s}\n", .{path});
    } else {
        std.debug.print("No config file found, using defaults\n", .{});
    }

    // Create the App and run (first window on main thread, spawned windows on separate threads)
    var app = try App.init(allocator, cfg);
    defer app.deinit();

    try app.run();

    std.debug.print("Phantty exiting...\n", .{});
}
