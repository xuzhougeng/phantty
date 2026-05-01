//! OpenGL initialization and shared rendering primitives.
//!
//! Shader sources, compilation, buffer setup (VAO/VBO), instanced rendering
//! buffers, and shared drawing helpers (renderQuad, setProjection).

const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const Renderer = @import("Renderer.zig");

const c = @cImport({
    @cInclude("glad/gl.h");
});

// ============================================================================
// GL object handles
// ============================================================================

pub threadlocal var vao: c.GLuint = 0;
pub threadlocal var vbo: c.GLuint = 0;
pub threadlocal var shader_program: c.GLuint = 0;

// GL objects for instanced rendering
pub threadlocal var bg_shader: c.GLuint = 0;
pub threadlocal var fg_shader: c.GLuint = 0;
pub threadlocal var color_fg_shader: c.GLuint = 0; // Color emoji shader (BGRA sampling)
pub threadlocal var bg_vao: c.GLuint = 0;
pub threadlocal var fg_vao: c.GLuint = 0;
pub threadlocal var color_fg_vao: c.GLuint = 0;
pub threadlocal var bg_instance_vbo: c.GLuint = 0;
pub threadlocal var fg_instance_vbo: c.GLuint = 0;
pub threadlocal var color_fg_instance_vbo: c.GLuint = 0;
threadlocal var quad_vbo: c.GLuint = 0; // shared unit quad for instanced draws

pub threadlocal var simple_color_shader: c.GLuint = 0;
pub threadlocal var overlay_shader: c.GLuint = 0;

// Solid white texture for drawing filled quads
threadlocal var solid_texture: c.GLuint = 0;

// Draw call counter (reset each frame)
pub threadlocal var g_draw_call_count: u32 = 0;

// ============================================================================
// Shader sources
// ============================================================================

const vertex_shader_source: [*c]const u8 =
    \\#version 330 core
    \\layout (location = 0) in vec4 vertex;
    \\out vec2 TexCoords;
    \\uniform mat4 projection;
    \\void main() {
    \\    gl_Position = projection * vec4(vertex.xy, 0.0, 1.0);
    \\    TexCoords = vertex.zw;
    \\}
;

const fragment_shader_source: [*c]const u8 =
    \\#version 330 core
    \\in vec2 TexCoords;
    \\out vec4 color;
    \\uniform sampler2D text;
    \\uniform vec3 textColor;
    \\void main() {
    \\    vec4 sampled = vec4(1.0, 1.0, 1.0, texture(text, TexCoords).r);
    \\    color = vec4(textColor, 1.0) * sampled;
    \\}
;

const bg_vertex_source: [*c]const u8 =
    \\#version 330 core
    \\// Unit quad (0,0)-(1,1)
    \\layout (location = 0) in vec2 aQuad;
    \\// Per-instance
    \\layout (location = 1) in vec2 aGridPos;
    \\layout (location = 2) in vec3 aColor;
    \\uniform mat4 projection;
    \\uniform vec2 cellSize;
    \\uniform vec2 gridOffset;
    \\uniform float windowHeight;
    \\flat out vec3 vColor;
    \\void main() {
    \\    // Cell top-left in screen coords
    \\    float cx = gridOffset.x + aGridPos.x * cellSize.x;
    \\    float cy = windowHeight - gridOffset.y - (aGridPos.y + 1.0) * cellSize.y;
    \\    vec2 pos = vec2(cx, cy) + aQuad * cellSize;
    \\    gl_Position = projection * vec4(pos, 0.0, 1.0);
    \\    vColor = aColor;
    \\}
;

const bg_fragment_source: [*c]const u8 =
    \\#version 330 core
    \\flat in vec3 vColor;
    \\out vec4 fragColor;
    \\void main() {
    \\    fragColor = vec4(vColor, 1.0);
    \\}
;

const fg_vertex_source: [*c]const u8 =
    \\#version 330 core
    \\layout (location = 0) in vec2 aQuad;
    \\// Per-instance
    \\layout (location = 1) in vec2 aGridPos;
    \\layout (location = 2) in vec4 aGlyphRect;  // x, y, w, h in pixels
    \\layout (location = 3) in vec4 aUV;          // left, top, right, bottom
    \\layout (location = 4) in vec3 aColor;
    \\uniform mat4 projection;
    \\uniform vec2 cellSize;
    \\uniform vec2 gridOffset;
    \\uniform float windowHeight;
    \\out vec2 vTexCoord;
    \\flat out vec3 vColor;
    \\void main() {
    \\    float cx = gridOffset.x + aGridPos.x * cellSize.x;
    \\    float cy = windowHeight - gridOffset.y - (aGridPos.y + 1.0) * cellSize.y;
    \\    // Glyph quad within cell
    \\    vec2 pos = vec2(cx + aGlyphRect.x, cy + aGlyphRect.y) + aQuad * aGlyphRect.zw;
    \\    gl_Position = projection * vec4(pos, 0.0, 1.0);
    \\    // UV interpolation — V is flipped because atlas Y=0 is top but GL quad Y=0 is bottom
    \\    vTexCoord = vec2(mix(aUV.x, aUV.z, aQuad.x), mix(aUV.w, aUV.y, aQuad.y));
    \\    vColor = aColor;
    \\}
;

const fg_fragment_source: [*c]const u8 =
    \\#version 330 core
    \\in vec2 vTexCoord;
    \\flat in vec3 vColor;
    \\uniform sampler2D atlas;
    \\out vec4 fragColor;
    \\void main() {
    \\    float a = texture(atlas, vTexCoord).r;
    \\    fragColor = vec4(vColor, 1.0) * vec4(1.0, 1.0, 1.0, a);
    \\}
;

// Color emoji fragment shader — samples RGBA directly from the color atlas.
// FreeType's color emoji bitmaps (CBDT/CBLC) use premultiplied alpha,
// so we output them directly and use premultiplied blend mode (GL_ONE, GL_ONE_MINUS_SRC_ALPHA).
const color_fg_fragment_source: [*c]const u8 =
    \\#version 330 core
    \\in vec2 vTexCoord;
    \\flat in vec3 vColor;
    \\uniform sampler2D atlas;
    \\out vec4 fragColor;
    \\void main() {
    \\    fragColor = texture(atlas, vTexCoord);
    \\}
;

// Simple (non-instanced) color emoji fragment shader for titlebar/overlay use.
// Uses the same vertex layout as the text shader (vec4: xy=pos, zw=texcoord).
const simple_color_fragment_source: [*c]const u8 =
    \\#version 330 core
    \\in vec2 TexCoords;
    \\out vec4 color;
    \\uniform sampler2D text;
    \\uniform float opacity;
    \\void main() {
    \\    vec4 texColor = texture(text, TexCoords);
    \\    color = texColor * opacity;
    \\}
;

// Solid color overlay shader - outputs a solid color with alpha for true blending.
const overlay_fragment_source: [*c]const u8 =
    \\#version 330 core
    \\out vec4 color;
    \\uniform vec4 overlayColor;
    \\void main() {
    \\    color = overlayColor;
    \\}
;

// ============================================================================
// Shader compilation and linking
// ============================================================================

pub fn compileShader(shader_type: c.GLenum, source: [*c]const u8) ?c.GLuint {
    const gl = AppWindow.gl;
    const shader = gl.CreateShader.?(shader_type);
    if (shader == 0) {
        const gl_err = if (gl.GetError) |getErr| getErr() else 0;
        std.debug.print("Shader error: glCreateShader returned 0, type=0x{X}, glError=0x{X}\n", .{ shader_type, gl_err });
        return null;
    }

    gl.ShaderSource.?(shader, 1, &source, null);
    gl.CompileShader.?(shader);

    var success: c.GLint = 0;
    gl.GetShaderiv.?(shader, c.GL_COMPILE_STATUS, &success);
    if (success == 0) {
        var info_log: [512]u8 = @splat(0);
        var log_len: c.GLsizei = 0;
        gl.GetShaderInfoLog.?(shader, 512, &log_len, &info_log);
        const len: usize = if (log_len > 0) @intCast(log_len) else 0;
        if (len > 0) {
            std.debug.print("Shader compilation failed: {s}\n", .{info_log[0..len]});
        } else {
            std.debug.print("Shader compilation failed (no error log, shader={})\n", .{shader});
        }
        return null;
    }
    return shader;
}

fn linkProgram(vs_src: [*c]const u8, fs_src: [*c]const u8) c.GLuint {
    const gl = AppWindow.gl;
    const vs = compileShader(c.GL_VERTEX_SHADER, vs_src) orelse return 0;
    defer gl.DeleteShader.?(vs);
    const fs = compileShader(c.GL_FRAGMENT_SHADER, fs_src) orelse return 0;
    defer gl.DeleteShader.?(fs);
    const prog = gl.CreateProgram.?();
    gl.AttachShader.?(prog, vs);
    gl.AttachShader.?(prog, fs);
    gl.LinkProgram.?(prog);
    var success: c.GLint = 0;
    gl.GetProgramiv.?(prog, c.GL_LINK_STATUS, &success);
    if (success == 0) {
        var info_log: [512]u8 = @splat(0);
        var log_len: c.GLsizei = 0;
        gl.GetProgramInfoLog.?(prog, 512, &log_len, &info_log);
        const len: usize = if (log_len > 0) @intCast(log_len) else 0;
        if (len > 0) std.debug.print("Shader link failed: {s}\n", .{info_log[0..len]});
        return 0;
    }
    return prog;
}

// ============================================================================
// Initialization
// ============================================================================

pub fn initShaders() bool {
    const gl = AppWindow.gl;
    const vertex_shader = compileShader(c.GL_VERTEX_SHADER, vertex_shader_source) orelse return false;
    defer gl.DeleteShader.?(vertex_shader);

    const fragment_shader = compileShader(c.GL_FRAGMENT_SHADER, fragment_shader_source) orelse return false;
    defer gl.DeleteShader.?(fragment_shader);

    shader_program = gl.CreateProgram.?();
    gl.AttachShader.?(shader_program, vertex_shader);
    gl.AttachShader.?(shader_program, fragment_shader);
    gl.LinkProgram.?(shader_program);

    var success: c.GLint = 0;
    gl.GetProgramiv.?(shader_program, c.GL_LINK_STATUS, &success);
    if (success == 0) {
        var info_log: [512]u8 = @splat(0);
        var log_len: c.GLsizei = 0;
        gl.GetProgramInfoLog.?(shader_program, 512, &log_len, &info_log);
        const len: usize = if (log_len > 0) @intCast(log_len) else 0;
        if (len > 0) {
            std.debug.print("Shader linking failed: {s}\n", .{info_log[0..len]});
        } else {
            std.debug.print("Shader linking failed (no error log available)\n", .{});
        }
        return false;
    }

    return true;
}

pub fn initBuffers() void {
    const gl = AppWindow.gl;
    gl.GenVertexArrays.?(1, &vao);
    gl.GenBuffers.?(1, &vbo);
    gl.BindVertexArray.?(vao);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, vbo);
    gl.BufferData.?(c.GL_ARRAY_BUFFER, @sizeOf(f32) * 6 * 4, null, c.GL_DYNAMIC_DRAW);
    gl.EnableVertexAttribArray.?(0);
    gl.VertexAttribPointer.?(0, 4, c.GL_FLOAT, c.GL_FALSE, 4 * @sizeOf(f32), null);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    gl.BindVertexArray.?(0);
}

pub fn initInstancedBuffers() void {
    const gl = AppWindow.gl;

    // Shared unit quad (triangle strip: 4 verts)
    const quad_verts = [4][2]f32{
        .{ 0.0, 0.0 }, // bottom-left
        .{ 1.0, 0.0 }, // bottom-right
        .{ 0.0, 1.0 }, // top-left
        .{ 1.0, 1.0 }, // top-right
    };
    gl.GenBuffers.?(1, &quad_vbo);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, quad_vbo);
    gl.BufferData.?(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(quad_verts)), &quad_verts, c.GL_STATIC_DRAW);

    // --- BG VAO ---
    gl.GenVertexArrays.?(1, &bg_vao);
    gl.GenBuffers.?(1, &bg_instance_vbo);
    gl.BindVertexArray.?(bg_vao);

    // Attr 0: unit quad (per-vertex)
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, quad_vbo);
    gl.EnableVertexAttribArray.?(0);
    gl.VertexAttribPointer.?(0, 2, c.GL_FLOAT, c.GL_FALSE, 2 * @sizeOf(f32), null);

    // Attrs 1-2: per-instance BG data
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, bg_instance_vbo);
    gl.BufferData.?(c.GL_ARRAY_BUFFER, @sizeOf(Renderer.CellBg) * Renderer.MAX_CELLS, null, c.GL_STREAM_DRAW);
    const bg_stride: c.GLsizei = @sizeOf(Renderer.CellBg);
    // Attr 1: grid_col, grid_row
    gl.EnableVertexAttribArray.?(1);
    gl.VertexAttribPointer.?(1, 2, c.GL_FLOAT, c.GL_FALSE, bg_stride, @ptrFromInt(0));
    gl.VertexAttribDivisor.?(1, 1);
    // Attr 2: r, g, b
    gl.EnableVertexAttribArray.?(2);
    gl.VertexAttribPointer.?(2, 3, c.GL_FLOAT, c.GL_FALSE, bg_stride, @ptrFromInt(2 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(2, 1);

    gl.BindVertexArray.?(0);

    // --- FG VAO ---
    gl.GenVertexArrays.?(1, &fg_vao);
    gl.GenBuffers.?(1, &fg_instance_vbo);
    gl.BindVertexArray.?(fg_vao);

    // Attr 0: unit quad (per-vertex)
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, quad_vbo);
    gl.EnableVertexAttribArray.?(0);
    gl.VertexAttribPointer.?(0, 2, c.GL_FLOAT, c.GL_FALSE, 2 * @sizeOf(f32), null);

    // Attrs 1-4: per-instance FG data
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, fg_instance_vbo);
    gl.BufferData.?(c.GL_ARRAY_BUFFER, @sizeOf(Renderer.CellFg) * Renderer.MAX_CELLS, null, c.GL_STREAM_DRAW);
    const fg_stride: c.GLsizei = @sizeOf(Renderer.CellFg);
    // Attr 1: grid_col, grid_row
    gl.EnableVertexAttribArray.?(1);
    gl.VertexAttribPointer.?(1, 2, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(0));
    gl.VertexAttribDivisor.?(1, 1);
    // Attr 2: glyph_x, glyph_y, glyph_w, glyph_h
    gl.EnableVertexAttribArray.?(2);
    gl.VertexAttribPointer.?(2, 4, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(2 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(2, 1);
    // Attr 3: uv_left, uv_top, uv_right, uv_bottom
    gl.EnableVertexAttribArray.?(3);
    gl.VertexAttribPointer.?(3, 4, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(6 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(3, 1);
    // Attr 4: r, g, b
    gl.EnableVertexAttribArray.?(4);
    gl.VertexAttribPointer.?(4, 3, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(10 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(4, 1);

    gl.BindVertexArray.?(0);

    // --- Color FG VAO (same layout as FG, separate buffer for color emoji) ---
    gl.GenVertexArrays.?(1, &color_fg_vao);
    gl.GenBuffers.?(1, &color_fg_instance_vbo);
    gl.BindVertexArray.?(color_fg_vao);

    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, quad_vbo);
    gl.EnableVertexAttribArray.?(0);
    gl.VertexAttribPointer.?(0, 2, c.GL_FLOAT, c.GL_FALSE, 2 * @sizeOf(f32), null);

    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, color_fg_instance_vbo);
    gl.BufferData.?(c.GL_ARRAY_BUFFER, @sizeOf(Renderer.CellFg) * Renderer.MAX_CELLS, null, c.GL_STREAM_DRAW);
    gl.EnableVertexAttribArray.?(1);
    gl.VertexAttribPointer.?(1, 2, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(0));
    gl.VertexAttribDivisor.?(1, 1);
    gl.EnableVertexAttribArray.?(2);
    gl.VertexAttribPointer.?(2, 4, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(2 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(2, 1);
    gl.EnableVertexAttribArray.?(3);
    gl.VertexAttribPointer.?(3, 4, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(6 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(3, 1);
    gl.EnableVertexAttribArray.?(4);
    gl.VertexAttribPointer.?(4, 3, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(10 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(4, 1);

    gl.BindVertexArray.?(0);

    // --- Compile instanced shaders ---
    bg_shader = linkProgram(bg_vertex_source, bg_fragment_source);
    fg_shader = linkProgram(fg_vertex_source, fg_fragment_source);
    color_fg_shader = linkProgram(fg_vertex_source, color_fg_fragment_source);
    if (bg_shader == 0) std.debug.print("BG instanced shader failed\n", .{});
    if (fg_shader == 0) std.debug.print("FG instanced shader failed\n", .{});
    if (color_fg_shader == 0) std.debug.print("Color FG instanced shader failed\n", .{});

    // Simple color shader for titlebar emoji (uses same vertex layout as text shader)
    simple_color_shader = linkProgram(vertex_shader_source, simple_color_fragment_source);
    if (simple_color_shader == 0) std.debug.print("Simple color shader failed\n", .{});

    // Overlay shader for unfocused split dimming (solid color with alpha)
    overlay_shader = linkProgram(vertex_shader_source, overlay_fragment_source);
    if (overlay_shader == 0) std.debug.print("Overlay shader failed\n", .{});
}

pub fn initSolidTexture() void {
    const gl = &AppWindow.gl;
    const white_pixel = [_]u8{255};
    gl.GenTextures.?(1, &solid_texture);
    gl.BindTexture.?(c.GL_TEXTURE_2D, solid_texture);
    gl.TexImage2D.?(c.GL_TEXTURE_2D, 0, c.GL_RED, 1, 1, 0, c.GL_RED, c.GL_UNSIGNED_BYTE, &white_pixel);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
}

// ============================================================================
// Cleanup
// ============================================================================

pub fn deinitInstancedResources() void {
    const gl = &AppWindow.gl;
    if (bg_shader != 0) gl.DeleteProgram.?(bg_shader);
    if (fg_shader != 0) gl.DeleteProgram.?(fg_shader);
    if (color_fg_shader != 0) gl.DeleteProgram.?(color_fg_shader);
    if (bg_vao != 0) gl.DeleteVertexArrays.?(1, &bg_vao);
    if (fg_vao != 0) gl.DeleteVertexArrays.?(1, &fg_vao);
    if (color_fg_vao != 0) gl.DeleteVertexArrays.?(1, &color_fg_vao);
    if (bg_instance_vbo != 0) gl.DeleteBuffers.?(1, &bg_instance_vbo);
    if (fg_instance_vbo != 0) gl.DeleteBuffers.?(1, &fg_instance_vbo);
    if (color_fg_instance_vbo != 0) gl.DeleteBuffers.?(1, &color_fg_instance_vbo);
    if (quad_vbo != 0) gl.DeleteBuffers.?(1, &quad_vbo);
}

// ============================================================================
// Render helpers
// ============================================================================

pub fn renderQuad(x: f32, y: f32, w: f32, h: f32, color: [3]f32) void {
    renderQuadAlpha(x, y, w, h, color, 1.0);
}

pub fn renderQuadAlpha(x: f32, y: f32, w: f32, h: f32, color: [3]f32, alpha: f32) void {
    const gl = AppWindow.gl;
    const vertices = [6][4]f32{
        .{ x, y + h, 0.0, 0.0 },
        .{ x, y, 0.0, 1.0 },
        .{ x + w, y, 1.0, 1.0 },
        .{ x, y + h, 0.0, 0.0 },
        .{ x + w, y, 1.0, 1.0 },
        .{ x + w, y + h, 1.0, 0.0 },
    };

    // Pre-multiply alpha into color and use the solid texture (which has alpha=1).
    // With GL_SRC_ALPHA blending, we set textColor to full RGB and modulate alpha
    // via the vec4 output. Since our fragment shader does:
    //   color = vec4(textColor, 1.0) * sampled
    // and sampled = vec4(1,1,1, texture.r) with solid_texture.r = 1,
    // the output alpha is always 1. To get transparency we use a small trick:
    // temporarily blend manually by dimming the color toward the background.
    // This avoids needing a shader change.
    const bg = AppWindow.g_theme.background;
    const r = color[0] * alpha + bg[0] * (1 - alpha);
    const g = color[1] * alpha + bg[1] * (1 - alpha);
    const b = color[2] * alpha + bg[2] * (1 - alpha);

    gl.Uniform3f.?(gl.GetUniformLocation.?(shader_program, "textColor"), r, g, b);
    gl.BindTexture.?(c.GL_TEXTURE_2D, solid_texture);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, vbo);
    gl.BufferSubData.?(c.GL_ARRAY_BUFFER, 0, @sizeOf(@TypeOf(vertices)), &vertices);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6);
    g_draw_call_count += 1;
}

pub fn setProjection(width: f32, height: f32) void {
    const gl = AppWindow.gl;
    const projection = [16]f32{
        2.0 / width, 0.0,          0.0,  0.0,
        0.0,         2.0 / height, 0.0,  0.0,
        0.0,         0.0,          -1.0, 0.0,
        -1.0,        -1.0,         0.0,  1.0,
    };

    gl.UseProgram.?(shader_program);
    gl.UniformMatrix4fv.?(gl.GetUniformLocation.?(shader_program, "projection"), 1, c.GL_FALSE, &projection);
}

/// Set the orthographic projection matrix on a specific shader program.
pub fn setProjectionForProgram(program: c.GLuint, window_height: f32) void {
    const gl = AppWindow.gl;
    var viewport: [4]c.GLint = undefined;
    gl.GetIntegerv.?(c.GL_VIEWPORT, &viewport);
    const width: f32 = @floatFromInt(viewport[2]);
    const height: f32 = @floatFromInt(viewport[3]);
    _ = window_height;

    const projection = [16]f32{
        2.0 / width, 0.0,          0.0,  0.0,
        0.0,         2.0 / height, 0.0,  0.0,
        0.0,         0.0,          -1.0, 0.0,
        -1.0,        -1.0,         0.0,  1.0,
    };

    gl.UniformMatrix4fv.?(gl.GetUniformLocation.?(program, "projection"), 1, c.GL_FALSE, &projection);
}
