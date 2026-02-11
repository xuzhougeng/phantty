//! FBO (Framebuffer Object) management for per-surface rendering.
//!
//! Creates, resizes, and draws FBOs that allow each split surface to be
//! rendered independently and then composited onto the main framebuffer.

const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const gl_init = AppWindow.gl_init;
const Renderer = @import("../Renderer.zig");

const c = @cImport({
    @cInclude("glad/gl.h");
});

/// Create or resize an FBO for a renderer.
/// Must be called from main thread with GL context current.
pub fn ensureRendererFBO(rend: *Renderer, width: u32, height: u32) void {
    if (!rend.needsFBOUpdate(width, height)) return;

    const gl = &AppWindow.gl;

    // Clean up existing FBO if resizing
    if (rend.isFBOReady()) {
        cleanupRendererFBO(rend);
    }

    // Create framebuffer
    var fbo: c.GLuint = 0;
    gl.GenFramebuffers.?(1, &fbo);
    gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, fbo);

    // Create texture for color attachment
    var texture: c.GLuint = 0;
    gl.GenTextures.?(1, &texture);
    gl.BindTexture.?(c.GL_TEXTURE_2D, texture);
    gl.TexImage2D.?(
        c.GL_TEXTURE_2D,
        0,
        c.GL_RGBA8,
        @intCast(width),
        @intCast(height),
        0,
        c.GL_RGBA,
        c.GL_UNSIGNED_BYTE,
        null,
    );
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);

    // Attach texture to framebuffer
    gl.FramebufferTexture2D.?(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, texture, 0);

    // Check framebuffer completeness
    const status = gl.CheckFramebufferStatus.?(c.GL_FRAMEBUFFER);
    if (status != c.GL_FRAMEBUFFER_COMPLETE) {
        std.debug.print("FBO incomplete: 0x{X}\n", .{status});
    }

    // Unbind
    gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, 0);
    gl.BindTexture.?(c.GL_TEXTURE_2D, 0);

    // Store handles in renderer
    rend.setFBOHandles(fbo, texture, width, height);
}

/// Clean up FBO resources for a renderer.
pub fn cleanupRendererFBO(rend: *Renderer) void {
    if (!rend.isFBOReady()) return;

    const gl = &AppWindow.gl;

    var texture = rend.getTexture();
    var fbo = rend.getFBO();

    if (texture != 0) {
        gl.DeleteTextures.?(1, &texture);
    }
    if (fbo != 0) {
        gl.DeleteFramebuffers.?(1, &fbo);
    }

    rend.clearFBOHandles();
}

/// Bind a renderer's FBO for drawing.
pub fn bindRendererFBO(rend: *Renderer) void {
    if (!rend.isFBOReady()) return;
    const gl = &AppWindow.gl;
    gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, rend.getFBO());
    const size = rend.getFBOSize();
    gl.Viewport.?(0, 0, @intCast(size.width), @intCast(size.height));
}

/// Unbind FBO (return to default framebuffer).
pub fn unbindFBO() void {
    const gl = &AppWindow.gl;
    gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, 0);
}

/// Draw a renderer's FBO texture as a quad at the given screen position.
/// This composites the surface onto the main framebuffer.
pub fn drawRendererFBOToScreen(rend: *Renderer, x: f32, y: f32, w: f32, h: f32, window_height: f32, window_width: f32) void {
    if (!rend.isFBOReady()) return;

    const gl = &AppWindow.gl;

    // Convert from top-left screen coords to OpenGL bottom-left coords
    const gl_y = window_height - y - h;

    // Vertices for textured quad (position + texcoord)
    const vertices = [6][4]f32{
        .{ x, gl_y + h, 0.0, 1.0 }, // top-left
        .{ x, gl_y, 0.0, 0.0 }, // bottom-left
        .{ x + w, gl_y, 1.0, 0.0 }, // bottom-right
        .{ x, gl_y + h, 0.0, 1.0 }, // top-left
        .{ x + w, gl_y, 1.0, 0.0 }, // bottom-right
        .{ x + w, gl_y + h, 1.0, 1.0 }, // top-right
    };

    // Set up projection matrix for screen space
    const projection = [16]f32{
        2.0 / window_width, 0.0,                 0.0,  0.0,
        0.0,                2.0 / window_height, 0.0,  0.0,
        0.0,                0.0,                 -1.0, 0.0,
        -1.0,               -1.0,                0.0,  1.0,
    };

    // Use the color texture shader (samples RGBA directly)
    gl.UseProgram.?(gl_init.simple_color_shader);
    gl.UniformMatrix4fv.?(gl.GetUniformLocation.?(gl_init.simple_color_shader, "projection"), 1, c.GL_FALSE, &projection);
    gl.Uniform1f.?(gl.GetUniformLocation.?(gl_init.simple_color_shader, "opacity"), 1.0);
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindTexture.?(c.GL_TEXTURE_2D, rend.getTexture());
    gl.Uniform1i.?(gl.GetUniformLocation.?(gl_init.simple_color_shader, "text"), 0);
    gl.BindVertexArray.?(gl_init.vao);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, gl_init.vbo);
    gl.BufferSubData.?(c.GL_ARRAY_BUFFER, 0, @sizeOf(@TypeOf(vertices)), &vertices);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6);
    gl_init.g_draw_call_count += 1;
}
