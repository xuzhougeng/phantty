//! Post-processing custom shader system (Ghostty-compatible).
//!
//! Ghostty custom shaders use Shadertoy-style conventions:
//!   - iResolution: vec3 (viewport resolution in pixels, z=1.0)
//!   - iTime: float (elapsed time in seconds)
//!   - iTimeDelta: float (time since last frame)
//!   - iFrame: int (frame counter)
//!   - iChannel0: sampler2D (the terminal framebuffer)
//!   - iChannelResolution[0]: vec3 (texture resolution)
//!
//! The shader must define: void mainImage(out vec4 fragColor, in vec2 fragCoord)

const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const gl_init = AppWindow.gl_init;
const cell_renderer = AppWindow.cell_renderer;
const Renderer = @import("Renderer.zig");

const c = @cImport({
    @cInclude("glad/gl.h");
});

// Post-processing state
threadlocal var g_post_fbo: c.GLuint = 0; // Framebuffer object for off-screen render
threadlocal var g_post_texture: c.GLuint = 0; // Color attachment texture
threadlocal var g_post_program: c.GLuint = 0; // Post-processing shader program
threadlocal var g_post_vao: c.GLuint = 0; // Fullscreen quad VAO
threadlocal var g_post_vbo: c.GLuint = 0; // Fullscreen quad VBO
pub threadlocal var g_post_enabled: bool = false; // Whether custom shader is active
threadlocal var g_post_fb_width: c_int = 0; // Current FBO texture dimensions
threadlocal var g_post_fb_height: c_int = 0;
threadlocal var g_frame_count: u32 = 0; // Frame counter for iFrame
threadlocal var g_start_time: i64 = 0; // Start time for iTime

/// Vertex shader for the fullscreen post-processing quad
const post_vertex_source: [*c]const u8 =
    \\#version 330 core
    \\layout (location = 0) in vec2 aPos;
    \\layout (location = 1) in vec2 aTexCoord;
    \\out vec2 vTexCoord;
    \\void main() {
    \\    gl_Position = vec4(aPos, 0.0, 1.0);
    \\    vTexCoord = aTexCoord;
    \\}
;

/// Build the post-processing fragment shader by wrapping a Ghostty/Shadertoy-style
/// mainImage shader with our uniform declarations and main() entry point.
fn buildPostFragmentSource(allocator: std.mem.Allocator, user_shader: []const u8) ![:0]const u8 {
    const preamble =
        \\#version 330 core
        \\out vec4 _fragColor;
        \\in vec2 vTexCoord;
        \\
        \\uniform vec3 iResolution;
        \\uniform float iTime;
        \\uniform float iTimeDelta;
        \\uniform int iFrame;
        \\uniform sampler2D iChannel0;
        \\uniform vec3 iChannelResolution[1];
        \\
        \\// Provide textureLod via extension or fallback
        \\
    ;
    const epilogue =
        \\
        \\void main() {
        \\    vec2 fragCoord = vTexCoord * iResolution.xy;
        \\    mainImage(_fragColor, fragCoord);
        \\}
    ;

    const total_len = preamble.len + user_shader.len + epilogue.len;
    const buf = try allocator.alloc(u8, total_len + 1); // +1 for sentinel
    @memcpy(buf[0..preamble.len], preamble);
    @memcpy(buf[preamble.len..][0..user_shader.len], user_shader);
    @memcpy(buf[preamble.len + user_shader.len ..][0..epilogue.len], epilogue);
    buf[total_len] = 0; // null-terminate

    return buf[0..total_len :0];
}

/// Load and compile a custom post-processing shader from a file
fn initPostShader(allocator: std.mem.Allocator, shader_path: []const u8) bool {
    const gl = &AppWindow.gl;
    // Read shader source file
    const file = std.fs.cwd().openFile(shader_path, .{}) catch |err| {
        std.debug.print("Failed to open shader file '{s}': {}\n", .{ shader_path, err });
        return false;
    };
    defer file.close();

    const user_source = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        std.debug.print("Failed to read shader file: {}\n", .{err});
        return false;
    };
    defer allocator.free(user_source);

    // Build complete fragment shader
    const frag_source = buildPostFragmentSource(allocator, user_source) catch |err| {
        std.debug.print("Failed to build shader source: {}\n", .{err});
        return false;
    };
    defer allocator.free(frag_source);

    // Compile vertex shader
    const vert = gl_init.compileShader(c.GL_VERTEX_SHADER, post_vertex_source) orelse return false;
    defer gl.DeleteShader.?(vert);

    // Compile fragment shader
    const frag = gl_init.compileShader(c.GL_FRAGMENT_SHADER, frag_source.ptr) orelse return false;
    defer gl.DeleteShader.?(frag);

    // Link program
    g_post_program = gl.CreateProgram.?();
    gl.AttachShader.?(g_post_program, vert);
    gl.AttachShader.?(g_post_program, frag);
    gl.LinkProgram.?(g_post_program);

    var success: c.GLint = 0;
    gl.GetProgramiv.?(g_post_program, c.GL_LINK_STATUS, &success);
    if (success == 0) {
        var info_log: [512]u8 = undefined;
        gl.GetProgramInfoLog.?(g_post_program, 512, null, &info_log);
        std.debug.print("Post shader linking failed: {s}\n", .{&info_log});
        return false;
    }

    // Set up fullscreen quad VAO/VBO
    // Two triangles covering [-1,1] NDC with tex coords [0,1]
    const quad_verts = [_]f32{
        // pos      // tex
        -1.0, -1.0, 0.0, 0.0,
        1.0,  -1.0, 1.0, 0.0,
        -1.0, 1.0,  0.0, 1.0,

        1.0,  -1.0, 1.0, 0.0,
        1.0,  1.0,  1.0, 1.0,
        -1.0, 1.0,  0.0, 1.0,
    };

    gl.GenVertexArrays.?(1, &g_post_vao);
    gl.GenBuffers.?(1, &g_post_vbo);
    gl.BindVertexArray.?(g_post_vao);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, g_post_vbo);
    gl.BufferData.?(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(quad_verts)), &quad_verts, c.GL_STATIC_DRAW);
    // position (location 0)
    gl.EnableVertexAttribArray.?(0);
    gl.VertexAttribPointer.?(0, 2, c.GL_FLOAT, c.GL_FALSE, 4 * @sizeOf(f32), null);
    // texcoord (location 1)
    gl.EnableVertexAttribArray.?(1);
    gl.VertexAttribPointer.?(1, 2, c.GL_FLOAT, c.GL_FALSE, 4 * @sizeOf(f32), @ptrFromInt(2 * @sizeOf(f32)));
    gl.BindVertexArray.?(0);

    std.debug.print("Custom shader loaded: {s}\n", .{shader_path});
    return true;
}

/// Create or resize the off-screen framebuffer for post-processing
fn ensurePostFBO(width: c_int, height: c_int) void {
    const gl = &AppWindow.gl;
    if (width == g_post_fb_width and height == g_post_fb_height and g_post_fbo != 0) return;

    // Delete old FBO/texture if resizing
    if (g_post_fbo != 0) {
        gl.DeleteFramebuffers.?(1, &g_post_fbo);
        gl.DeleteTextures.?(1, &g_post_texture);
    }

    // Create FBO
    gl.GenFramebuffers.?(1, &g_post_fbo);
    gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, g_post_fbo);

    // Create color texture
    gl.GenTextures.?(1, &g_post_texture);
    gl.BindTexture.?(c.GL_TEXTURE_2D, g_post_texture);
    gl.TexImage2D.?(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, width, height, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);

    // Attach to FBO
    gl.FramebufferTexture2D.?(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, g_post_texture, 0);

    if (gl.CheckFramebufferStatus.?(c.GL_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE) {
        std.debug.print("Post-processing FBO is incomplete!\n", .{});
    }

    gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, 0);
    g_post_fb_width = width;
    g_post_fb_height = height;
}

/// Render the fullscreen quad with post-processing shader applied
fn renderPostProcess(width: c_int, height: c_int) void {
    const gl = &AppWindow.gl;
    // Bind default framebuffer (screen)
    gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, 0);
    gl.Viewport.?(0, 0, width, height);
    gl.Clear.?(c.GL_COLOR_BUFFER_BIT);

    // Disable blending for the fullscreen quad - shader output is final color
    gl.Disable.?(c.GL_BLEND);

    gl.UseProgram.?(g_post_program);

    // Set uniforms (Ghostty/Shadertoy conventions)
    const w_f: f32 = @floatFromInt(width);
    const h_f: f32 = @floatFromInt(height);
    const now_ms = std.time.milliTimestamp();
    const elapsed: f32 = @floatCast(@as(f64, @floatFromInt(now_ms - g_start_time)) / 1000.0);

    // iResolution
    gl.Uniform3f.?(gl.GetUniformLocation.?(g_post_program, "iResolution"), w_f, h_f, 1.0);
    // iTime
    gl.Uniform1f.?(gl.GetUniformLocation.?(g_post_program, "iTime"), elapsed);
    // iTimeDelta (approximate ~16ms)
    gl.Uniform1f.?(gl.GetUniformLocation.?(g_post_program, "iTimeDelta"), 0.016);
    // iFrame
    gl.Uniform1i.?(gl.GetUniformLocation.?(g_post_program, "iFrame"), @intCast(g_frame_count));
    // iChannel0 = texture unit 0
    gl.Uniform1i.?(gl.GetUniformLocation.?(g_post_program, "iChannel0"), 0);
    // iChannelResolution[0]
    gl.Uniform3f.?(gl.GetUniformLocation.?(g_post_program, "iChannelResolution[0]"), w_f, h_f, 1.0);

    // Bind the terminal framebuffer texture
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindTexture.?(c.GL_TEXTURE_2D, g_post_texture);

    // Draw fullscreen quad
    gl.BindVertexArray.?(g_post_vao);
    gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6);
    gl_init.g_draw_call_count += 1;
    gl.BindVertexArray.?(0);

    // Re-enable blending for next terminal render pass
    gl.Enable.?(c.GL_BLEND);

    g_frame_count +%= 1;
}

/// Helper: render a frame to FBO, then apply post-processing to screen.
/// Render with post-processing. Called after updateTerminalCells() has
/// already been called under the lock — this only does GL work.
pub fn renderFrameWithPostFromCells(rend: *const Renderer, width: c_int, height: c_int, padding: f32) void {
    const gl = &AppWindow.gl;
    ensurePostFBO(width, height);

    // 1. Render terminal to FBO
    gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, g_post_fbo);
    gl.Viewport.?(0, 0, width, height);
    gl_init.setProjection(@floatFromInt(width), @floatFromInt(height));
    gl.ClearColor.?(AppWindow.g_theme.background[0], AppWindow.g_theme.background[1], AppWindow.g_theme.background[2], 1.0);
    gl.Clear.?(c.GL_COLOR_BUFFER_BIT);
    cell_renderer.drawCells(rend, @floatFromInt(height), padding, padding);

    // 2. Apply post-processing shader to screen
    renderPostProcess(width, height);
}

/// Initialize post-processing from a shader path. Returns true if enabled.
pub fn init(allocator: std.mem.Allocator, shader_path: ?[]const u8) void {
    const sp = shader_path orelse return;
    if (initPostShader(allocator, sp)) {
        g_post_enabled = true;
        g_start_time = std.time.milliTimestamp();
    } else {
        std.debug.print("Warning: custom shader failed to load, continuing without it\n", .{});
    }
}

/// Clean up post-processing GL resources.
pub fn deinit() void {
    if (!g_post_enabled) return;
    const gl = &AppWindow.gl;
    gl.DeleteProgram.?(g_post_program);
    gl.DeleteVertexArrays.?(1, &g_post_vao);
    gl.DeleteBuffers.?(1, &g_post_vbo);
    if (g_post_fbo != 0) {
        gl.DeleteFramebuffers.?(1, &g_post_fbo);
        gl.DeleteTextures.?(1, &g_post_texture);
    }
}
