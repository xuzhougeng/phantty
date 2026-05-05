const std = @import("std");

pub fn build(b: *std.Build) void {
    // Windows cross-compilation (x86_64-windows-gnu)
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .x86_64,
            .os_tag = .windows,
            .abi = .gnu,
        },
    });
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Add ghostty-vt dependency with SIMD disabled for cross-compilation
    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .simd = false,
    })) |dep| {
        exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
        exe_mod.addIncludePath(dep.path("src/stb"));
        exe_mod.addCSourceFile(.{
            .file = dep.path("src/stb/stb.c"),
            .flags = &.{},
        });
    }

    // Add libxev dependency (xev event loop for IO thread)
    if (b.lazyDependency("libxev", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        exe_mod.addImport("xev", dep.module("xev"));
    }

    // Win32: link native Windows libraries
    exe_mod.linkSystemLibrary("user32", .{});
    exe_mod.linkSystemLibrary("gdi32", .{});
    exe_mod.linkSystemLibrary("gdiplus", .{});
    exe_mod.linkSystemLibrary("dwmapi", .{});
    exe_mod.linkSystemLibrary("ws2_32", .{});
    exe_mod.linkSystemLibrary("mswsock", .{});

    // Add FreeType dependency (shared between main and harfbuzz)
    const freetype_dep = b.lazyDependency("freetype", .{
        .target = target,
        .optimize = optimize,
    });
    if (freetype_dep) |dep| {
        exe_mod.addImport("freetype", dep.module("freetype"));
        exe_mod.linkLibrary(dep.artifact("freetype"));
    }

    // Add z2d dependency for sprite rendering
    if (b.lazyDependency("z2d", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        exe_mod.addImport("z2d", dep.module("z2d"));
    }

    // Add HarfBuzz — build C library and create Zig module sharing our freetype
    if (b.lazyDependency("harfbuzz", .{})) |hb_dep| {
        if (freetype_dep) |ft_dep| {
            // Build the HarfBuzz C static library from source
            const hb_lib = buildHarfbuzzLib(b, target, optimize, hb_dep, ft_dep);

            // Create Zig wrapper module sharing our freetype module
            const hb_mod = b.addModule("harfbuzz", .{
                .root_source_file = b.path("pkg/harfbuzz/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "freetype", .module = ft_dep.module("freetype") },
                },
            });

            const options = b.addOptions();
            options.addOption(bool, "coretext", false);
            options.addOption(bool, "freetype", true);
            hb_mod.addOptions("build_options", options);

            // Add HarfBuzz C headers to the Zig module
            if (hb_dep.builder.lazyDependency("harfbuzz", .{})) |upstream| {
                hb_mod.addIncludePath(upstream.path("src"));
            }
            // Add FreeType C headers so hb-ft.h can find ft2build.h
            hb_mod.addIncludePath(b.path("pkg/freetype"));
            if (ft_dep.builder.lazyDependency("freetype", .{})) |ft_upstream| {
                hb_mod.addIncludePath(ft_upstream.path("include"));
            }

            exe_mod.addImport("harfbuzz", hb_mod);
            exe_mod.linkLibrary(hb_lib);
        }
    }

    // Add OpenGL/glad headers and source
    exe_mod.addIncludePath(b.path("vendor/glad/include"));
    exe_mod.addCSourceFile(.{
        .file = b.path("vendor/glad/src/gl.c"),
        .flags = &.{},
    });

    // Link OpenGL on Windows
    exe_mod.linkSystemLibrary("opengl32", .{});

    // Embed application icon via Windows resource file
    exe_mod.addWin32ResourceFile(.{
        .file = b.path("assets/phantty.rc"),
        .include_paths = &.{b.path("assets")},
    });

    const exe = b.addExecutable(.{
        .name = "phantty",
        .root_module = exe_mod,
    });

    // Debug builds use Console subsystem so std.debug.print output is visible.
    // Release builds use Windows GUI subsystem to avoid a background console window.
    exe.subsystem = if (optimize == .Debug) .Console else .Windows;

    b.installArtifact(exe);
}

/// Build HarfBuzz as a static C library, linking against our shared FreeType.
fn buildHarfbuzzLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    hb_dep: *std.Build.Dependency,
    ft_dep: *std.Build.Dependency,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "harfbuzz",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    lib.linkLibC();
    lib.linkLibCpp();

    var flags: std.ArrayList([]const u8) = .empty;
    defer flags.deinit(b.allocator);
    flags.appendSlice(b.allocator, &.{
        "-DHAVE_STDBOOL_H",
        "-DHAVE_FREETYPE=1",
        "-DHAVE_FT_GET_VAR_BLEND_COORDINATES=1",
        "-DHAVE_FT_SET_VAR_BLEND_COORDINATES=1",
        "-DHAVE_FT_DONE_MM_VAR=1",
        "-DHAVE_FT_GET_TRANSFORM=1",
    }) catch @panic("OOM");

    if (target.result.os.tag != .windows) {
        flags.appendSlice(b.allocator, &.{
            "-DHAVE_UNISTD_H",
            "-DHAVE_SYS_MMAN_H",
            "-DHAVE_PTHREAD=1",
        }) catch @panic("OOM");
    }

    // Link our shared FreeType
    lib.linkLibrary(ft_dep.artifact("freetype"));

    // Compile HarfBuzz C++ source
    if (hb_dep.builder.lazyDependency("harfbuzz", .{})) |upstream| {
        lib.addIncludePath(upstream.path("src"));
        lib.addCSourceFile(.{
            .file = upstream.path("src/harfbuzz.cc"),
            .flags = flags.items,
        });
    }

    return lib;
}
