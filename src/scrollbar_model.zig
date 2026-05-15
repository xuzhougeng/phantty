const std = @import("std");

pub const IDLE_OPACITY: f32 = 0.72;
pub const TRACK_ALPHA_SCALE: f32 = 0.34;
pub const THUMB_ALPHA_SCALE: f32 = 0.90;

pub fn effectiveOpacity(stored_opacity: f32, has_scrollback: bool) f32 {
    if (!has_scrollback) return 0;
    const clamped = if (stored_opacity < 0)
        @as(f32, 0)
    else if (stored_opacity > 1)
        @as(f32, 1)
    else
        stored_opacity;
    return @max(IDLE_OPACITY, clamped);
}

pub fn canInteract(has_scrollback: bool) bool {
    return has_scrollback;
}

pub fn trackAlpha(effective_opacity: f32) f32 {
    return clamp01(effective_opacity) * TRACK_ALPHA_SCALE;
}

pub fn thumbAlpha(effective_opacity: f32) f32 {
    return clamp01(effective_opacity) * THUMB_ALPHA_SCALE;
}

fn clamp01(value: f32) f32 {
    if (value < 0) return 0;
    if (value > 1) return 1;
    return value;
}

test "scrollbar remains visible and interactive at idle when scrollback exists" {
    try std.testing.expect(effectiveOpacity(0, true) > 0.01);
    try std.testing.expect(canInteract(true));
}

test "scrollbar thumb keeps enough contrast at idle" {
    const idle_fade = effectiveOpacity(0, true);
    try std.testing.expect(thumbAlpha(idle_fade) >= 0.64);
    try std.testing.expect(trackAlpha(idle_fade) >= 0.22);
    try std.testing.expect(thumbAlpha(1.0) >= 0.90);
}

test "scrollbar hides and ignores input without scrollback" {
    try std.testing.expectEqual(@as(f32, 0), effectiveOpacity(1, false));
    try std.testing.expect(!canInteract(false));
}
