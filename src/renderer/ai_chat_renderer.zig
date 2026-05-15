//! Native renderer for AI Chat sessions.

const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const ai_chat = @import("../ai_chat.zig");
const font = AppWindow.font;
const gl_init = AppWindow.gl_init;
const titlebar = AppWindow.titlebar;

const c = @cImport({
    @cInclude("glad/gl.h");
});

pub const LINE_PAD_X: f32 = 18;
const HEADER_H: f32 = 54;
pub const INPUT_H: f32 = 92;
const PERMISSION_CHIP_W: f32 = 104;
const PERMISSION_CHIP_H: f32 = 24;
const STATUS_SLOT_W: f32 = 120;
const STOP_BUTTON_W: f32 = 104;
const STOP_BUTTON_H: f32 = 28;
const MODE_SLOT_W: f32 = 112;
const BUBBLE_PAD_X: f32 = 14;
const BUBBLE_PAD_Y: f32 = 10;
const BUBBLE_GAP: f32 = 12;
const APPROVAL_H: f32 = 128;
const APPROVAL_GAP: f32 = 12;
const COPY_BUTTON_SIZE: f32 = 24;
const COPY_BUTTON_PAD: f32 = 8;
const DETAIL_PAD_X: f32 = 14;
const DETAIL_PAD_Y: f32 = 10;
const DETAIL_ARROW_W: f32 = 12;
const DETAIL_RULE_W: f32 = 3;
const TOOL_GROUP_ITEM_GAP: f32 = 8;
const TABLE_MAX_COLS: usize = 8;
const TABLE_CELL_PAD_X: f32 = 10;
const TABLE_MIN_COL_W: f32 = 56;

pub const HitTarget = union(enum) {
    copy_message: usize,
    toggle_tool_group: usize,
    toggle_tool: usize,
    toggle_reasoning: usize,
};

pub fn render(
    session: *ai_chat.Session,
    window_width: f32,
    window_height: f32,
    titlebar_offset: f32,
    left_panels_w: f32,
    right_panels_w: f32,
) void {
    const gl = &AppWindow.gl;
    gl.Enable.?(c.GL_BLEND);
    gl.BlendFunc.?(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    gl.UseProgram.?(gl_init.shader_program);
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindVertexArray.?(gl_init.vao);

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const muted = mixColor(bg, fg, 0.62);
    const panel = mixColor(bg, fg, 0.045);
    const line = mixColor(bg, fg, 0.18);

    const x = @round(left_panels_w);
    const w = @round(@max(1.0, window_width - left_panels_w - right_panels_w));
    const top = @round(titlebar_offset);
    const h = @round(@max(1.0, window_height - top));
    if (w <= 1 or h <= 1) return;

    gl_init.renderQuad(x, 0, w, h, bg);

    session.mutex.lock();
    defer session.mutex.unlock();

    const header_y = window_height - top - HEADER_H;
    gl_init.renderQuadAlpha(x, header_y, w, HEADER_H, panel, 0.95);
    gl_init.renderQuadAlpha(x, header_y, w, 1, line, 0.8);
    _ = titlebar.renderTextLimited(session.model(), x + LINE_PAD_X, header_y + 10, mixColor(fg, accent, 0.12), w * 0.48);

    const permission = ai_chat.agentPermission();
    const chip_x = permissionChipX(x, w);
    const mode_text = if (session.agent_enabled) "Agent" else "Chat";
    const mode_x = chip_x - MODE_SLOT_W - 8;
    _ = titlebar.renderTextLimited(mode_text, mode_x, header_y + 10, mixColor(fg, accent, 0.18), MODE_SLOT_W);

    const perm_text = permissionDisplayName(permission);
    const perm_color = if (permission == .full) mixColor(fg, accent, 0.25) else mixColor(bg, fg, 0.66);
    _ = titlebar.renderTextLimited(perm_text, chip_x, header_y + 10, perm_color, PERMISSION_CHIP_W);
    gl_init.renderQuadAlpha(chip_x, header_y + 8, PERMISSION_CHIP_W - 8, 1, accent, if (permission == .full) 0.38 else 0.16);

    if (session.request_inflight) {
        renderStopButton(stopButtonRect(x, w, top), window_height, session.request_stopping);
    } else {
        const status_w = measureText(session.status());
        _ = titlebar.renderTextLimited(session.status(), x + w - LINE_PAD_X - @min(status_w, STATUS_SLOT_W), header_y + 10, muted, STATUS_SLOT_W);
    }

    const input_y: f32 = 0;
    gl_init.renderQuadAlpha(x, input_y, w, INPUT_H, panel, 0.98);
    gl_init.renderQuadAlpha(x, input_y + INPUT_H - 1, w, 1, line, 0.8);

    const field_x = x + LINE_PAD_X;
    const field_y = input_y + 16;
    const field_w = w - LINE_PAD_X * 2;
    const field_h = INPUT_H - 32;
    const field_bg = mixColor(bg, fg, 0.075);
    gl_init.renderQuadAlpha(field_x, field_y, field_w, field_h, field_bg, 0.95);
    gl_init.renderQuadAlpha(field_x, field_y, field_w, 1, mixColor(bg, accent, 0.38), 0.6);

    const input_text = session.input();
    if (input_text.len == 0) {
        const placeholder = if (session.agent_enabled) "Ask Agent" else "Ask AI Chat";
        _ = titlebar.renderTextLimited(placeholder, field_x + 12, field_y + (field_h - font.g_titlebar_cell_height) / 2, mixColor(bg, fg, 0.42), field_w - 24);
    } else {
        if (session.input_select_all) {
            gl_init.renderQuadAlpha(field_x + 8, field_y + 8, field_w - 16, field_h - 16, accent, 0.22);
        }
        _ = renderWrappedText(input_text, field_x + 12, window_height - field_y - field_h + 10, field_w - 24, lineHeight(), fg, window_height, window_height);
    }
    if (!session.request_inflight and AppWindow.g_cursor_blink_visible) {
        const cursor_x = inputCursorX(input_text, field_x + 12, field_w - 24);
        gl_init.renderQuad(cursor_x, field_y + 14, 1, field_h - 28, accent);
    }

    const approval = session.approvalView();
    const approval_h: f32 = if (approval != null) APPROVAL_H + APPROVAL_GAP else 0;

    const transcript_top = top + HEADER_H + 18;
    const transcript_bottom = INPUT_H + approval_h + 18;
    const transcript_h = @max(1.0, window_height - transcript_top - transcript_bottom);
    const content_w = w - LINE_PAD_X * 2;
    const content_x = x + LINE_PAD_X;
    const viewport_bottom_top_px = window_height - transcript_bottom;

    var content_h: f32 = 0;
    var measure_index: usize = 0;
    while (measure_index < session.messages.items.len) {
        const msg = session.messages.items[measure_index];
        if (isToolGroupStart(session.messages.items, measure_index)) {
            const group_end = toolGroupEnd(session.messages.items, measure_index);
            content_h += toolGroupBlockHeight(session.messages.items, measure_index, group_end, content_w);
            content_h += BUBBLE_GAP;
            measure_index = group_end;
            continue;
        }

        content_h += messageBlockHeight(msg, content_w);
        if (msg.reasoning) |reasoning| {
            if (reasoning.len > 0) content_h += reasoningCardHeight(msg, content_w);
        }
        content_h += BUBBLE_GAP;
        measure_index += 1;
    }
    const max_scroll = @max(0.0, content_h - transcript_h);
    session.scroll_px = @min(session.scroll_px, max_scroll);

    gl.Enable.?(c.GL_SCISSOR_TEST);
    gl.Scissor.?(
        @intFromFloat(@round(x)),
        @intFromFloat(@round(transcript_bottom)),
        @intFromFloat(@round(w)),
        @intFromFloat(@round(transcript_h)),
    );

    const gravity_offset = @max(0.0, transcript_h - content_h);
    const palette = markdownPalette(bg, fg, accent);
    const transcript_selected = session.transcript_select_all;
    var cursor_top = transcript_top + gravity_offset - session.scroll_px;

    var message_index: usize = 0;
    while (message_index < session.messages.items.len) {
        const msg = session.messages.items[message_index];
        if (isToolGroupStart(session.messages.items, message_index)) {
            const group_end = toolGroupEnd(session.messages.items, message_index);
            const group_h = toolGroupBlockHeight(session.messages.items, message_index, group_end, content_w);
            if (sectionVisible(cursor_top, group_h, transcript_top, viewport_bottom_top_px)) {
                renderToolGroup(session.messages.items, message_index, group_end, content_x, cursor_top, content_w, group_h, window_height, transcript_selected);
            }
            cursor_top += group_h + BUBBLE_GAP;
            message_index = group_end;
            continue;
        }

        const block_h = messageBlockHeight(msg, content_w);
        if (msg.role == .tool) {
            if (sectionVisible(cursor_top, block_h, transcript_top, viewport_bottom_top_px)) {
                renderToolCard(msg, content_x, cursor_top, content_w, block_h, window_height, transcript_selected);
            }
        } else if (sectionVisible(cursor_top, block_h, transcript_top, viewport_bottom_top_px)) {
            renderMessageBubble(msg.role, msg.content, content_x, cursor_top, content_w, block_h, window_height, transcript_selected, palette);
        }
        cursor_top += block_h;

        if (msg.reasoning) |reasoning| {
            if (reasoning.len > 0) {
                const r_h = reasoningCardHeight(msg, content_w);
                if (sectionVisible(cursor_top, r_h, transcript_top, viewport_bottom_top_px)) {
                    renderReasoningCard(reasoning, msg.reasoning_collapsed, content_x, cursor_top, content_w, r_h, window_height, transcript_selected);
                }
                cursor_top += r_h;
            }
        }

        cursor_top += BUBBLE_GAP;
        message_index += 1;
    }

    gl.Disable.?(c.GL_SCISSOR_TEST);

    if (approval) |view| {
        renderApprovalCard(view, x + LINE_PAD_X, INPUT_H + APPROVAL_GAP, w - LINE_PAD_X * 2, APPROVAL_H);
    }
}

pub fn interactionHitTest(
    session: *ai_chat.Session,
    xpos: f64,
    ypos: f64,
    window_width: f32,
    window_height: f32,
    titlebar_offset: f32,
    left_panels_w: f32,
    right_panels_w: f32,
) ?HitTarget {
    const x = @round(left_panels_w);
    const w = @round(@max(1.0, window_width - left_panels_w - right_panels_w));
    if (w <= 1) return null;

    session.mutex.lock();
    defer session.mutex.unlock();

    const approval = session.approvalView();
    const approval_h: f32 = if (approval != null) APPROVAL_H + APPROVAL_GAP else 0;
    const transcript_top = titlebar_offset + HEADER_H + 18;
    const transcript_bottom = INPUT_H + approval_h + 18;
    const transcript_h = @max(1.0, window_height - transcript_top - transcript_bottom);
    const viewport_bottom_top_px = window_height - transcript_bottom;
    const content_w = w - LINE_PAD_X * 2;
    const content_x = x + LINE_PAD_X;

    var content_h: f32 = 0;
    var measure_index: usize = 0;
    while (measure_index < session.messages.items.len) {
        const msg = session.messages.items[measure_index];
        if (isToolGroupStart(session.messages.items, measure_index)) {
            const group_end = toolGroupEnd(session.messages.items, measure_index);
            content_h += toolGroupBlockHeight(session.messages.items, measure_index, group_end, content_w);
            content_h += BUBBLE_GAP;
            measure_index = group_end;
            continue;
        }

        content_h += messageBlockHeight(msg, content_w);
        if (msg.reasoning) |reasoning| {
            if (reasoning.len > 0) content_h += reasoningCardHeight(msg, content_w);
        }
        content_h += BUBBLE_GAP;
        measure_index += 1;
    }

    const scroll_px = @min(session.scroll_px, @max(0.0, content_h - transcript_h));
    const gravity_offset = @max(0.0, transcript_h - content_h);
    const px: f32 = @floatCast(xpos);
    const py: f32 = @floatCast(ypos);
    var cursor_top = transcript_top + gravity_offset - scroll_px;

    var message_index: usize = 0;
    while (message_index < session.messages.items.len) {
        const msg = session.messages.items[message_index];
        if (isToolGroupStart(session.messages.items, message_index)) {
            const group_end = toolGroupEnd(session.messages.items, message_index);
            const group_h = toolGroupBlockHeight(session.messages.items, message_index, group_end, content_w);
            if (sectionVisible(cursor_top, group_h, transcript_top, viewport_bottom_top_px)) {
                const header_rect = detailHeaderRect(content_x, cursor_top, content_w);
                if (pointInRect(px, py, header_rect)) return .{ .toggle_tool_group = message_index };

                if (!msg.tool_group_collapsed) {
                    var child_top = cursor_top + detailHeaderHeight() + TOOL_GROUP_ITEM_GAP;
                    var child_index = message_index;
                    while (child_index < group_end) : (child_index += 1) {
                        const child_h = toolCardHeight(session.messages.items[child_index], content_w);
                        if (sectionVisible(child_top, child_h, transcript_top, viewport_bottom_top_px)) {
                            const copy_rect = detailCopyButtonRect(content_x, child_top, content_w);
                            if (pointInRect(px, py, copy_rect)) return .{ .copy_message = child_index };
                            const child_header_rect = detailHeaderRect(content_x, child_top, content_w);
                            if (pointInRect(px, py, child_header_rect)) return .{ .toggle_tool = child_index };
                        }
                        child_top += child_h + TOOL_GROUP_ITEM_GAP;
                    }
                }
            }
            cursor_top += group_h + BUBBLE_GAP;
            message_index = group_end;
            continue;
        }

        const block_h = messageBlockHeight(msg, content_w);
        if (msg.role == .tool) {
            if (sectionVisible(cursor_top, block_h, transcript_top, viewport_bottom_top_px)) {
                const copy_rect = detailCopyButtonRect(content_x, cursor_top, content_w);
                if (pointInRect(px, py, copy_rect)) return .{ .copy_message = message_index };
                const header_rect = detailHeaderRect(content_x, cursor_top, content_w);
                if (pointInRect(px, py, header_rect)) return .{ .toggle_tool = message_index };
            }
        } else if (sectionVisible(cursor_top, block_h, transcript_top, viewport_bottom_top_px)) {
            const rect = copyButtonRect(msg.role, content_x, cursor_top, content_w);
            if (pointInRect(px, py, rect)) return .{ .copy_message = message_index };
        }
        cursor_top += block_h;

        if (msg.reasoning) |reasoning| {
            if (reasoning.len > 0) {
                const r_h = reasoningCardHeight(msg, content_w);
                if (sectionVisible(cursor_top, r_h, transcript_top, viewport_bottom_top_px)) {
                    const header_rect = detailHeaderRect(content_x, cursor_top, content_w);
                    if (pointInRect(px, py, header_rect)) return .{ .toggle_reasoning = message_index };
                }
                cursor_top += r_h;
            }
        }
        cursor_top += BUBBLE_GAP;
        message_index += 1;
    }

    return null;
}

pub fn stopButtonHitTest(
    session: *ai_chat.Session,
    xpos: f64,
    ypos: f64,
    window_width: f32,
    titlebar_offset: f32,
    left_panels_w: f32,
    right_panels_w: f32,
) bool {
    session.mutex.lock();
    const visible = session.request_inflight;
    session.mutex.unlock();
    if (!visible) return false;

    const x = @round(left_panels_w);
    const w = @round(@max(1.0, window_width - left_panels_w - right_panels_w));
    const rect = stopButtonRect(x, w, titlebar_offset);
    return pointInRect(@floatCast(xpos), @floatCast(ypos), rect);
}

pub fn permissionChipHitTest(
    xpos: f64,
    ypos: f64,
    window_width: f32,
    titlebar_offset: f32,
    left_panels_w: f32,
    right_panels_w: f32,
) bool {
    const x = @round(left_panels_w);
    const w = @round(@max(1.0, window_width - left_panels_w - right_panels_w));
    const chip_x = permissionChipX(x, w);
    return pointInRect(@floatCast(xpos), @floatCast(ypos), .{
        .x = chip_x,
        .top_px = titlebar_offset + 12,
        .w = PERMISSION_CHIP_W,
        .h = PERMISSION_CHIP_H,
    });
}

fn messageBlockHeight(msg: ai_chat.Message, max_w: f32) f32 {
    return switch (msg.role) {
        .tool => toolCardHeight(msg, max_w),
        else => bubbleHeight(msg.role, msg.content, max_w),
    };
}

fn bubbleHeight(role: ai_chat.Role, text: []const u8, max_w: f32) f32 {
    const bubble = bubbleGeometry(role, 0, max_w);
    const inner_w = @max(1.0, bubble.w - BUBBLE_PAD_X * 2);
    const body_h = if (role == .assistant)
        markdownContentHeight(text, inner_w)
    else
        plainContentHeight(text, inner_w, lineHeight());
    return BUBBLE_PAD_Y * 2 + lineHeight() + body_h;
}

fn toolCardHeight(msg: ai_chat.Message, max_w: f32) f32 {
    const body_h = if (msg.content_collapsed)
        0
    else
        plainContentHeight(msg.content, @max(1.0, max_w - DETAIL_PAD_X * 2), lineHeight()) + DETAIL_PAD_Y * 2;
    return detailHeaderHeight() + body_h;
}

fn reasoningCardHeight(msg: ai_chat.Message, max_w: f32) f32 {
    const reasoning = msg.reasoning orelse return 0;
    const body_h = if (msg.reasoning_collapsed)
        0
    else
        plainContentHeight(reasoning, @max(1.0, max_w - DETAIL_PAD_X * 2), reasoningLineHeight()) + DETAIL_PAD_Y * 2;
    return detailHeaderHeight() + body_h;
}

fn isToolGroupStart(messages: []const ai_chat.Message, index: usize) bool {
    if (index >= messages.len) return false;
    return messages[index].role == .tool and messages[index].tool_grouped;
}

fn toolGroupEnd(messages: []const ai_chat.Message, start: usize) usize {
    var end = start;
    while (end < messages.len and messages[end].role == .tool) : (end += 1) {}
    return end;
}

fn toolGroupBlockHeight(messages: []const ai_chat.Message, start: usize, end: usize, max_w: f32) f32 {
    if (start >= end) return 0;
    var h = detailHeaderHeight();
    if (messages[start].tool_group_collapsed) return h;

    var i = start;
    while (i < end) : (i += 1) {
        h += TOOL_GROUP_ITEM_GAP + toolCardHeight(messages[i], max_w);
    }
    return h;
}

fn plainContentHeight(text: []const u8, max_w: f32, line_h: f32) f32 {
    return @as(f32, @floatFromInt(@max(@as(usize, 1), countWrappedLines(text, max_w)))) * line_h;
}

fn markdownContentHeight(text: []const u8, max_w: f32) f32 {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return lineHeight();

    const palette = markdownPalette(AppWindow.g_theme.background, AppWindow.g_theme.foreground, AppWindow.g_theme.cursor_color);
    var cursor: usize = 0;
    var total: f32 = 0;
    var in_code = false;

    while (cursor < text.len) {
        if (!in_code and isMarkdownTableStart(text, cursor)) {
            const end = tableBlockEnd(text, cursor);
            total += tableBlockHeight(text, cursor, end);
            cursor = end;
            continue;
        }

        const info = nextSourceLine(text, cursor);
        cursor = info.next;

        var clean_buf: [1024]u8 = undefined;
        const prepared = prepareMarkdownLine(&clean_buf, info.line, in_code, palette);
        switch (prepared.kind) {
            .blank => total += prepared.line_h,
            .fence => {
                total += prepared.line_h;
                in_code = !in_code;
            },
            .rule => total += prepared.line_h,
            .text => total += plainContentHeight(prepared.text, @max(1.0, max_w - prepared.indent), prepared.line_h),
        }
    }

    return @max(lineHeight(), total);
}

fn renderMessageBubble(
    role: ai_chat.Role,
    text: []const u8,
    x: f32,
    top_px: f32,
    w: f32,
    h: f32,
    window_height: f32,
    selected: bool,
    palette: MarkdownPalette,
) void {
    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const bubble = bubbleGeometry(role, x, w);
    const bubble_y = window_height - top_px - h;
    const is_user = role == .user;
    const bubble_bg = if (selected)
        mixColor(bg, accent, 0.30)
    else if (is_user)
        mixColor(bg, accent, 0.20)
    else
        mixColor(bg, fg, 0.07);

    gl_init.renderQuadAlpha(bubble.x, bubble_y, bubble.w, h, bubble_bg, 0.92);
    gl_init.renderQuadAlpha(bubble.x, bubble_y + h - 1, bubble.w, 1, if (is_user) accent else mixColor(bg, fg, 0.18), 0.55);
    if (selected) gl_init.renderQuadAlpha(bubble.x, bubble_y, 3, h, accent, 0.72);

    const label_color = if (is_user) mixColor(fg, accent, 0.18) else mixColor(fg, accent, 0.05);
    _ = titlebar.renderTextLimited(role.label(), bubble.x + BUBBLE_PAD_X, bubble_y + h - BUBBLE_PAD_Y - font.g_titlebar_cell_height, label_color, bubble.w - BUBBLE_PAD_X * 2);
    renderCopyButton(copyButtonRectForBubble(bubble.x, top_px, bubble.w), window_height, selected);

    const body_x = bubble.x + BUBBLE_PAD_X;
    const body_top = top_px + BUBBLE_PAD_Y + lineHeight();
    const body_w = @max(1.0, bubble.w - BUBBLE_PAD_X * 2);
    if (role == .assistant) {
        _ = renderMarkdownContent(text, body_x, body_top, body_w, window_height, window_height, palette);
    } else {
        _ = renderWrappedText(text, body_x, body_top, body_w, lineHeight(), fg, window_height, window_height);
    }
}

fn renderToolGroup(
    messages: []const ai_chat.Message,
    start: usize,
    end: usize,
    x: f32,
    top_px: f32,
    w: f32,
    h: f32,
    window_height: f32,
    selected: bool,
) void {
    if (start >= end) return;
    const collapsed = messages[start].tool_group_collapsed;
    renderToolGroupHeader(messages[start..end], collapsed, x, top_px, w, h, window_height, selected);
    if (collapsed) return;

    var child_top = top_px + detailHeaderHeight() + TOOL_GROUP_ITEM_GAP;
    var i = start;
    while (i < end) : (i += 1) {
        const child_h = toolCardHeight(messages[i], w);
        renderToolCard(messages[i], x, child_top, w, child_h, window_height, selected);
        child_top += child_h + TOOL_GROUP_ITEM_GAP;
    }
}

fn renderToolGroupHeader(
    messages: []const ai_chat.Message,
    collapsed: bool,
    x: f32,
    top_px: f32,
    w: f32,
    h: f32,
    window_height: f32,
    selected: bool,
) void {
    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const header_h = detailHeaderHeight();
    const y = window_height - top_px - h;
    const header_y = y + h - header_h;
    const card_bg = if (selected) mixColor(bg, accent, 0.20) else mixColor(bg, fg, 0.045);
    const header_bg = if (selected) mixColor(bg, accent, 0.27) else mixColor(bg, fg, 0.085);

    gl_init.renderQuadAlpha(x, y, w, h, card_bg, 0.92);
    gl_init.renderQuadAlpha(x, header_y, w, header_h, header_bg, 0.98);
    gl_init.renderQuadAlpha(x, y, DETAIL_RULE_W, h, accent, if (selected) 0.78 else 0.50);
    gl_init.renderQuadAlpha(x, y + h - 1, w, 1, mixColor(bg, fg, 0.20), 0.62);

    const arrow_x = x + DETAIL_PAD_X;
    const text_y = header_y + @round((header_h - font.g_titlebar_cell_height) / 2);
    _ = titlebar.renderTextLimited(if (collapsed) ">" else "v", arrow_x, text_y, mixColor(fg, accent, 0.16), DETAIL_ARROW_W);

    var text_x = arrow_x + DETAIL_ARROW_W + 6;
    const title_end = titlebar.renderTextLimited("Tool calls", text_x, text_y, mixColor(fg, accent, 0.18), w * 0.26);
    text_x = title_end + 10;

    var count_buf: [32]u8 = undefined;
    const item_word = if (messages.len == 1) "item" else "items";
    const count_text = std.fmt.bufPrint(&count_buf, "{} {s}", .{ messages.len, item_word }) catch "items";
    const count_end = titlebar.renderTextLimited(count_text, text_x, text_y, mixColor(fg, accent, 0.32), w * 0.18);
    text_x = count_end + 10;

    if (collapsed and messages.len > 0 and text_x + 12 < x + w - DETAIL_PAD_X) {
        const meta = toolSectionMeta(messages[0].content);
        const preview = if (meta.name.len > 0) meta.name else meta.preview;
        if (preview.len > 0) {
            _ = titlebar.renderTextLimited(preview, text_x, text_y, mixColor(bg, fg, 0.58), @max(24.0, x + w - DETAIL_PAD_X - text_x));
        }
    }
}

fn renderToolCard(msg: ai_chat.Message, x: f32, top_px: f32, w: f32, h: f32, window_height: f32, selected: bool) void {
    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const y = window_height - top_px - h;
    const header_h = detailHeaderHeight();
    const meta = toolSectionMeta(msg.content);
    const card_bg = if (selected) mixColor(bg, accent, 0.22) else mixColor(bg, fg, 0.055);
    const header_bg = if (selected) mixColor(bg, accent, 0.28) else mixColor(bg, fg, 0.08);
    const header_y = y + h - header_h;

    gl_init.renderQuadAlpha(x, y, w, h, card_bg, 0.94);
    gl_init.renderQuadAlpha(x, y + h - 1, w, 1, mixColor(bg, fg, 0.20), 0.65);
    gl_init.renderQuadAlpha(x, y + h - header_h, w, header_h, header_bg, 0.98);
    gl_init.renderQuadAlpha(x, y, DETAIL_RULE_W, h, accent, if (selected) 0.78 else 0.52);
    if (selected) gl_init.renderQuadAlpha(x, y, 1, h, accent, 0.90);

    const arrow_x = x + DETAIL_PAD_X;
    const arrow_y = header_y + @round((header_h - font.g_titlebar_cell_height) / 2);
    _ = titlebar.renderTextLimited(if (msg.content_collapsed) ">" else "v", arrow_x, arrow_y, mixColor(fg, accent, 0.16), DETAIL_ARROW_W);

    var text_x = arrow_x + DETAIL_ARROW_W + 6;
    const text_y = header_y + @round((header_h - font.g_titlebar_cell_height) / 2);
    const copy_rect = detailCopyButtonRect(x, top_px, w);
    renderCopyButton(copy_rect, window_height, selected);
    const header_text_limit = @max(40.0, copy_rect.x - text_x - 12);
    const title_end = titlebar.renderTextLimited(meta.title, text_x, text_y, mixColor(fg, accent, 0.18), header_text_limit);
    text_x = title_end + 8;
    if (meta.name.len > 0 and text_x + 10 < copy_rect.x) {
        text_x = titlebar.renderTextLimited(meta.name, text_x, text_y, mixColor(fg, accent, 0.32), @max(24.0, copy_rect.x - text_x - 12)) + 10;
    }
    if (msg.content_collapsed and meta.preview.len > 0 and text_x + 12 < copy_rect.x) {
        _ = titlebar.renderTextLimited(meta.preview, text_x, text_y, mixColor(bg, fg, 0.58), @max(24.0, copy_rect.x - text_x - 12));
    }

    if (!msg.content_collapsed) {
        _ = renderWrappedText(
            msg.content,
            x + DETAIL_PAD_X,
            top_px + header_h + DETAIL_PAD_Y,
            @max(1.0, w - DETAIL_PAD_X * 2),
            lineHeight(),
            mixColor(bg, fg, 0.84),
            window_height,
            window_height,
        );
    }
}

fn renderReasoningCard(text: []const u8, collapsed: bool, x: f32, top_px: f32, w: f32, h: f32, window_height: f32, selected: bool) void {
    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const y = window_height - top_px - h;
    const header_h = detailHeaderHeight();
    const card_bg = if (selected) mixColor(bg, accent, 0.18) else mixColor(bg, fg, 0.04);
    const header_bg = if (selected) mixColor(bg, accent, 0.22) else mixColor(bg, fg, 0.06);
    const header_y = y + h - header_h;

    gl_init.renderQuadAlpha(x, y, w, h, card_bg, 0.88);
    gl_init.renderQuadAlpha(x, header_y, w, header_h, header_bg, 0.96);
    gl_init.renderQuadAlpha(x, y, DETAIL_RULE_W, h, accent, if (selected) 0.76 else 0.34);

    const arrow_x = x + DETAIL_PAD_X;
    const arrow_y = header_y + @round((header_h - font.g_titlebar_cell_height) / 2);
    _ = titlebar.renderTextLimited(if (collapsed) ">" else "v", arrow_x, arrow_y, mixColor(fg, accent, 0.14), DETAIL_ARROW_W);

    const title_x = arrow_x + DETAIL_ARROW_W + 6;
    const title_y = header_y + @round((header_h - font.g_titlebar_cell_height) / 2);
    const preview = previewLine(text);
    const title_end = titlebar.renderTextLimited("Thinking", title_x, title_y, mixColor(fg, accent, 0.14), w * 0.3);
    if (collapsed and preview.len > 0) {
        _ = titlebar.renderTextLimited(preview, title_end + 10, title_y, mixColor(bg, fg, 0.56), @max(24.0, w - (title_end - x) - DETAIL_PAD_X - 16));
    }

    if (!collapsed) {
        _ = renderWrappedText(
            text,
            x + DETAIL_PAD_X,
            top_px + header_h + DETAIL_PAD_Y,
            @max(1.0, w - DETAIL_PAD_X * 2),
            reasoningLineHeight(),
            mixColor(bg, fg, 0.58),
            window_height,
            window_height,
        );
    }
}

fn sectionVisible(top_px: f32, h: f32, viewport_top: f32, viewport_bottom_top_px: f32) bool {
    return top_px + h >= viewport_top and top_px <= viewport_bottom_top_px;
}

fn bubbleGeometry(role: ai_chat.Role, x: f32, w: f32) BubbleGeometry {
    const is_user = role == .user;
    const bubble_w = @min(w, if (is_user) w * 0.82 else w);
    return .{
        .x = if (is_user) x + w - bubble_w else x,
        .w = bubble_w,
    };
}

const BubbleGeometry = struct {
    x: f32,
    w: f32,
};

const Rect = struct {
    x: f32,
    top_px: f32,
    w: f32,
    h: f32,
};

const CopyButtonRect = Rect;

const HeaderButtonRect = Rect;

fn pointInRect(px: f32, py: f32, rect: Rect) bool {
    return px >= rect.x and px <= rect.x + rect.w and py >= rect.top_px and py <= rect.top_px + rect.h;
}

fn detailHeaderRect(x: f32, top_px: f32, w: f32) Rect {
    return .{
        .x = x,
        .top_px = top_px,
        .w = w,
        .h = detailHeaderHeight(),
    };
}

fn detailCopyButtonRect(x: f32, top_px: f32, w: f32) CopyButtonRect {
    const header_h = detailHeaderHeight();
    return .{
        .x = x + w - DETAIL_PAD_X - COPY_BUTTON_SIZE,
        .top_px = top_px + @round((header_h - COPY_BUTTON_SIZE) / 2),
        .w = COPY_BUTTON_SIZE,
        .h = COPY_BUTTON_SIZE,
    };
}

fn copyButtonRect(role: ai_chat.Role, x: f32, top_px: f32, w: f32) CopyButtonRect {
    const bubble = bubbleGeometry(role, x, w);
    return copyButtonRectForBubble(bubble.x, top_px, bubble.w);
}

fn copyButtonRectForBubble(bubble_x: f32, top_px: f32, bubble_w: f32) CopyButtonRect {
    return .{
        .x = bubble_x + bubble_w - BUBBLE_PAD_X - COPY_BUTTON_SIZE,
        .top_px = top_px + COPY_BUTTON_PAD,
        .w = COPY_BUTTON_SIZE,
        .h = COPY_BUTTON_SIZE,
    };
}

fn permissionChipX(x: f32, w: f32) f32 {
    return x + w - LINE_PAD_X - STATUS_SLOT_W - 12 - PERMISSION_CHIP_W;
}

fn stopButtonRect(x: f32, w: f32, titlebar_offset: f32) HeaderButtonRect {
    return .{
        .x = x + w - LINE_PAD_X - STOP_BUTTON_W,
        .top_px = titlebar_offset + @round((HEADER_H - STOP_BUTTON_H) / 2),
        .w = STOP_BUTTON_W,
        .h = STOP_BUTTON_H,
    };
}

fn renderStopButton(rect: HeaderButtonRect, window_height: f32, stopping: bool) void {
    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const y = window_height - rect.top_px - rect.h;
    const fill = if (stopping) mixColor(bg, fg, 0.12) else mixColor(bg, accent, 0.20);
    const stroke = if (stopping) mixColor(bg, fg, 0.42) else accent;
    gl_init.renderQuadAlpha(rect.x, y, rect.w, rect.h, fill, 0.92);
    gl_init.renderQuadAlpha(rect.x, y + rect.h - 1, rect.w, 1, stroke, 0.70);
    gl_init.renderQuadAlpha(rect.x, y, rect.w, 1, mixColor(bg, fg, 0.20), 0.70);

    const icon_size: f32 = 8;
    const icon_x = rect.x + 12;
    const icon_y = y + @round((rect.h - icon_size) / 2);
    gl_init.renderQuad(icon_x, icon_y, icon_size, icon_size, if (stopping) mixColor(bg, fg, 0.62) else mixColor(fg, accent, 0.10));

    const label = if (stopping) "Stopping" else "Esc Stop";
    _ = titlebar.renderTextLimited(label, rect.x + 28, y + @round((rect.h - font.g_titlebar_cell_height) / 2), if (stopping) mixColor(bg, fg, 0.72) else fg, rect.w - 34);
}

fn permissionDisplayName(permission: ai_chat.AgentPermission) []const u8 {
    return switch (permission) {
        .confirm => "Ask",
        .full => "Full",
    };
}

fn renderApprovalCard(view: ai_chat.ApprovalView, x: f32, y: f32, w: f32, h: f32) void {
    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const card_bg = mixColor(bg, accent, 0.08);
    gl_init.renderQuadAlpha(x, y, w, h, card_bg, 0.98);
    gl_init.renderQuadAlpha(x, y + h - 1, w, 1, accent, 0.65);
    gl_init.renderQuadAlpha(x, y, w, 1, mixColor(bg, fg, 0.18), 0.8);
    gl_init.renderQuadAlpha(x, y, 4, h, accent, 0.85);

    var title_buf: [256]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Approve {s}?", .{view.tool}) catch "Approve tool?";
    _ = titlebar.renderTextLimited(title, x + 16, y + h - 26, mixColor(fg, accent, 0.20), w - 32);
    _ = titlebar.renderTextLimited("Enter/Y to run, Esc/N to deny", x + 16, y + h - 50, mixColor(bg, fg, 0.62), w - 32);
    if (view.reason.len > 0) {
        _ = titlebar.renderTextLimited(view.reason, x + 16, y + h - 74, mixColor(bg, fg, 0.70), w - 32);
    }
    const command_bg = mixColor(bg, fg, 0.065);
    gl_init.renderQuadAlpha(x + 12, y + 10, w - 24, 34, command_bg, 0.95);
    _ = titlebar.renderTextLimited(view.command, x + 20, y + 18, fg, w - 40);
}

fn renderCopyButton(rect: CopyButtonRect, window_height: f32, selected: bool) void {
    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const button_bg = if (selected) mixColor(bg, accent, 0.24) else mixColor(bg, fg, 0.10);
    const icon = if (selected) mixColor(fg, accent, 0.14) else mixColor(bg, fg, 0.72);
    const y = window_height - rect.top_px - rect.h;
    gl_init.renderQuadAlpha(rect.x, y, rect.w, rect.h, button_bg, 0.72);

    const t: f32 = 1.3;
    const back_x = rect.x + 7;
    const back_y = y + 7;
    const front_x = rect.x + 5;
    const front_y = y + 5;
    const box_w: f32 = 9;
    const box_h: f32 = 10;
    drawOutlineRect(back_x, back_y, box_w, box_h, t, mixColor(icon, bg, 0.22));
    drawOutlineRect(front_x, front_y + 3, box_w, box_h, t, icon);
}

fn drawOutlineRect(x: f32, y: f32, w: f32, h: f32, t: f32, color: [3]f32) void {
    gl_init.renderQuad(x, y + h - t, w, t, color);
    gl_init.renderQuad(x, y, w, t, color);
    gl_init.renderQuad(x, y, t, h, color);
    gl_init.renderQuad(x + w - t, y, t, h, color);
}

const ToolSectionMeta = struct {
    title: []const u8,
    name: []const u8 = "",
    preview: []const u8 = "",
};

fn toolSectionMeta(text: []const u8) ToolSectionMeta {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "running ")) {
        const rest = std.mem.trimLeft(u8, trimmed["running ".len..], " \t");
        var end: usize = 0;
        while (end < rest.len and rest[end] != ' ' and rest[end] != '\t' and rest[end] != '\r' and rest[end] != '\n') : (end += 1) {}
        return .{
            .title = "Tool call",
            .name = if (end > 0) rest[0..end] else "",
            .preview = if (end < rest.len) previewLine(rest[end..]) else "",
        };
    }
    if (std.mem.startsWith(u8, trimmed, "exit_code=") or
        std.mem.startsWith(u8, trimmed, "timed_out=") or
        std.mem.startsWith(u8, trimmed, "stdout:") or
        std.mem.startsWith(u8, trimmed, "stderr:") or
        std.mem.startsWith(u8, trimmed, "DENIED"))
    {
        return .{ .title = "Tool result", .preview = previewLine(trimmed) };
    }
    return .{ .title = "Tool update", .preview = previewLine(trimmed) };
}

fn previewLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return "";
    const end = std.mem.indexOfAny(u8, trimmed, "\r\n") orelse trimmed.len;
    return std.mem.trim(u8, trimmed[0..end], " \t");
}

const MarkdownPalette = struct {
    normal: [3]f32,
    muted: [3]f32,
    strong: [3]f32,
    accent: [3]f32,
    code_bg: [3]f32,
    heading_bg: [3]f32,
    quote_bg: [3]f32,
    table_bg: [3]f32,
    table_alt: [3]f32,
    table_border: [3]f32,
};

fn markdownPalette(bg: [3]f32, fg: [3]f32, accent: [3]f32) MarkdownPalette {
    return .{
        .normal = fg,
        .muted = mixColor(bg, fg, 0.60),
        .strong = mixColor(bg, fg, 0.96),
        .accent = mixColor(fg, accent, 0.10),
        .code_bg = mixColor(bg, fg, 0.075),
        .heading_bg = mixColor(bg, accent, 0.08),
        .quote_bg = mixColor(bg, fg, 0.05),
        .table_bg = mixColor(bg, fg, 0.055),
        .table_alt = mixColor(bg, fg, 0.08),
        .table_border = mixColor(bg, fg, 0.20),
    };
}

const MarkdownBlockKind = enum {
    blank,
    fence,
    rule,
    text,
};

const MarkdownPreparedLine = struct {
    kind: MarkdownBlockKind,
    text: []const u8 = "",
    color: [3]f32 = .{ 0.0, 0.0, 0.0 },
    indent: f32 = 0,
    line_h: f32 = 0,
    background: ?[3]f32 = null,
    left_rule: ?[3]f32 = null,
    underline: bool = false,
    fence_label: []const u8 = "",
};

fn prepareMarkdownLine(buf: *[1024]u8, raw_line: []const u8, in_code: bool, palette: MarkdownPalette) MarkdownPreparedLine {
    const trimmed = std.mem.trimLeft(u8, raw_line, " \t");
    const base_h = lineHeight();

    if (trimmed.len == 0) {
        return .{ .kind = .blank, .line_h = blankLineHeight(), .color = palette.muted };
    }
    if (isFence(trimmed)) {
        return .{
            .kind = .fence,
            .line_h = fenceLineHeight(),
            .color = palette.muted,
            .fence_label = fenceLanguage(trimmed),
        };
    }
    if (isHorizontalRule(trimmed)) {
        return .{ .kind = .rule, .line_h = @round(base_h * 0.78), .color = palette.muted };
    }
    if (in_code) {
        return .{
            .kind = .text,
            .text = cleanPlain(buf, raw_line),
            .color = palette.accent,
            .line_h = base_h,
            .background = palette.code_bg,
            .left_rule = palette.accent,
        };
    }
    if (headingBody(trimmed)) |heading| {
        return .{
            .kind = .text,
            .text = cleanInline(buf, heading.body),
            .color = if (heading.level <= 2) palette.strong else palette.normal,
            .line_h = switch (heading.level) {
                1 => @round(base_h * 1.72),
                2 => @round(base_h * 1.45),
                3 => @round(base_h * 1.24),
                else => @round(base_h * 1.10),
            },
            .background = if (heading.level <= 2) palette.heading_bg else null,
            .left_rule = if (heading.level <= 2) palette.accent else null,
            .underline = heading.level <= 2,
        };
    }
    if (htmlHeadingBody(trimmed)) |heading| {
        return .{
            .kind = .text,
            .text = cleanInline(buf, heading.body),
            .color = if (heading.level <= 2) palette.strong else palette.normal,
            .line_h = switch (heading.level) {
                1 => @round(base_h * 1.72),
                2 => @round(base_h * 1.45),
                3 => @round(base_h * 1.24),
                else => @round(base_h * 1.10),
            },
            .background = if (heading.level <= 2) palette.heading_bg else null,
            .left_rule = if (heading.level <= 2) palette.accent else null,
            .underline = heading.level <= 2,
        };
    }
    if (std.mem.startsWith(u8, trimmed, ">")) {
        return .{
            .kind = .text,
            .text = cleanInline(buf, std.mem.trimLeft(u8, trimmed[1..], " \t")),
            .color = palette.muted,
            .indent = 16,
            .line_h = base_h,
            .background = palette.quote_bg,
            .left_rule = palette.accent,
        };
    }
    if (listBody(trimmed)) |list| {
        const body = cleanInline(buf, list.body);
        if (body.len + list.marker.len <= buf.len) {
            std.mem.copyBackwards(u8, buf[list.marker.len .. list.marker.len + body.len], body);
            @memcpy(buf[0..list.marker.len], list.marker);
            return .{
                .kind = .text,
                .text = buf[0 .. list.marker.len + body.len],
                .color = palette.normal,
                .indent = 12,
                .line_h = base_h,
            };
        }
        return .{
            .kind = .text,
            .text = body,
            .color = palette.normal,
            .indent = 12,
            .line_h = base_h,
        };
    }

    return .{
        .kind = .text,
        .text = cleanInline(buf, trimmed),
        .color = palette.normal,
        .line_h = base_h,
    };
}

fn renderMarkdownContent(
    text: []const u8,
    x: f32,
    top_px: f32,
    max_w: f32,
    window_height: f32,
    clip_bottom_top_px: f32,
    palette: MarkdownPalette,
) f32 {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        return renderWrappedText("", x, top_px, max_w, lineHeight(), palette.normal, window_height, clip_bottom_top_px);
    }

    var cursor: usize = 0;
    var current_top = top_px;
    var in_code = false;

    while (cursor < text.len) {
        if (!in_code and isMarkdownTableStart(text, cursor)) {
            const end = tableBlockEnd(text, cursor);
            current_top += renderTableBlock(text, cursor, end, x, current_top, max_w, window_height, palette);
            cursor = end;
            continue;
        }

        const info = nextSourceLine(text, cursor);
        cursor = info.next;

        var clean_buf: [1024]u8 = undefined;
        const prepared = prepareMarkdownLine(&clean_buf, info.line, in_code, palette);
        switch (prepared.kind) {
            .blank => current_top += prepared.line_h,
            .fence => {
                renderMarkdownFence(prepared.fence_label, x, current_top, max_w, window_height, palette);
                current_top += prepared.line_h;
                in_code = !in_code;
            },
            .rule => {
                renderTopQuad(x, max_w, window_height, current_top + prepared.line_h * 0.42, 1, prepared.color);
                current_top += prepared.line_h;
            },
            .text => {
                const body_h = plainContentHeight(prepared.text, @max(1.0, max_w - prepared.indent), prepared.line_h);
                if (prepared.background) |bg_color| {
                    renderTopQuad(x - 8, max_w + 16, window_height, current_top, body_h, bg_color);
                }
                if (prepared.left_rule) |rule_color| {
                    renderTopQuad(x - 8, DETAIL_RULE_W, window_height, current_top, body_h, rule_color);
                }
                if (prepared.underline) {
                    renderTopQuad(x, max_w, window_height, current_top + body_h - 3, 1, mixColor(AppWindow.g_theme.background, AppWindow.g_theme.cursor_color, 0.32));
                }
                current_top = renderWrappedText(
                    prepared.text,
                    x + prepared.indent,
                    current_top,
                    @max(1.0, max_w - prepared.indent),
                    prepared.line_h,
                    prepared.color,
                    window_height,
                    clip_bottom_top_px,
                );
            },
        }
    }

    return current_top - top_px;
}

fn renderMarkdownFence(label: []const u8, x: f32, top_px: f32, max_w: f32, window_height: f32, palette: MarkdownPalette) void {
    const mid_top = top_px + fenceLineHeight() * 0.55;
    renderTopQuad(x, max_w, window_height, mid_top, 1, palette.table_border);
    if (label.len > 0) {
        renderTextLine(label, x + 8, top_px, max_w - 16, palette.muted, window_height, window_height);
    }
}

const SourceLine = struct {
    line: []const u8,
    next: usize,
};

fn nextSourceLine(text: []const u8, start: usize) SourceLine {
    if (start >= text.len) return .{ .line = "", .next = text.len };
    const line_end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    const raw = std.mem.trimRight(u8, text[start..line_end], "\r");
    return .{
        .line = raw,
        .next = if (line_end < text.len) line_end + 1 else text.len,
    };
}

fn isMarkdownTableStart(text: []const u8, start: usize) bool {
    const first = nextSourceLine(text, start);
    if (!looksLikeTableRow(first.line)) return false;
    if (first.next >= text.len) return false;
    const second = nextSourceLine(text, first.next);
    return isTableSeparatorLine(second.line);
}

fn tableBlockEnd(text: []const u8, start: usize) usize {
    const first = nextSourceLine(text, start);
    const second = nextSourceLine(text, first.next);
    var cursor = second.next;
    while (cursor < text.len) {
        const line = nextSourceLine(text, cursor);
        const trimmed = std.mem.trim(u8, line.line, " \t");
        if (trimmed.len == 0 or !looksLikeTableRow(line.line) or isTableSeparatorLine(line.line)) break;
        cursor = line.next;
    }
    return cursor;
}

fn tableBlockHeight(text: []const u8, start: usize, end: usize) f32 {
    var row_count: usize = 0;
    var cursor = start;
    while (cursor < end) {
        const info = nextSourceLine(text, cursor);
        cursor = info.next;
        if (isTableSeparatorLine(info.line)) continue;
        row_count += 1;
    }
    if (row_count == 0) return tableRowHeight();
    return @as(f32, @floatFromInt(row_count)) * tableRowHeight() + 1;
}

fn renderTableBlock(
    text: []const u8,
    start: usize,
    end: usize,
    x: f32,
    top_px: f32,
    max_w: f32,
    window_height: f32,
    palette: MarkdownPalette,
) f32 {
    var widths: [TABLE_MAX_COLS]f32 = .{0} ** TABLE_MAX_COLS;
    const col_count = measureTableColumns(text, start, end, max_w, &widths);
    if (col_count == 0) return 0;

    const table_w = tableUsedWidth(widths[0..col_count]);
    const row_h = tableRowHeight();
    const total_h = tableBlockHeight(text, start, end);
    const table_y = window_height - top_px - total_h;

    gl_init.renderQuadAlpha(x, table_y, table_w, total_h, palette.table_bg, 0.94);
    gl_init.renderQuadAlpha(x, table_y, DETAIL_RULE_W, total_h, palette.table_border, 0.85);
    gl_init.renderQuadAlpha(x, table_y, table_w, 1, palette.table_border, 0.85);
    gl_init.renderQuadAlpha(x, table_y + total_h - 1, table_w, 1, palette.table_border, 0.85);
    gl_init.renderQuadAlpha(x + table_w - 1, table_y, 1, total_h, palette.table_border, 0.85);

    var cursor = start;
    var row_index: usize = 0;
    while (cursor < end) {
        const info = nextSourceLine(text, cursor);
        cursor = info.next;
        if (isTableSeparatorLine(info.line)) continue;

        var cells: [TABLE_MAX_COLS][]const u8 = .{""} ** TABLE_MAX_COLS;
        const cell_count = parseTableRowCells(info.line, &cells);
        const row_top = top_px + @as(f32, @floatFromInt(row_index)) * row_h;
        const row_y = window_height - row_top - row_h;
        const row_bg = if (row_index == 0)
            mixColor(palette.table_bg, AppWindow.g_theme.cursor_color, 0.10)
        else if (row_index % 2 == 0)
            palette.table_bg
        else
            palette.table_alt;
        gl_init.renderQuadAlpha(x, row_y, table_w, row_h, row_bg, if (row_index == 0) 0.98 else 0.92);
        gl_init.renderQuadAlpha(x, row_y, table_w, 1, palette.table_border, 0.85);

        var cell_x = x + 1;
        for (0..col_count) |col| {
            if (col > 0) gl_init.renderQuadAlpha(cell_x - 1, row_y, 1, row_h, palette.table_border, 0.85);
            const text_w = widths[col];
            const cell_w = text_w + TABLE_CELL_PAD_X * 2 + 1;
            var clean_buf: [256]u8 = undefined;
            const cell_text = if (col < cell_count) cleanInline(&clean_buf, cells[col]) else "";
            _ = titlebar.renderTextLimited(
                cell_text,
                cell_x + TABLE_CELL_PAD_X,
                row_y + @round((row_h - font.g_titlebar_cell_height) / 2),
                if (row_index == 0) palette.strong else palette.normal,
                text_w,
            );
            cell_x += cell_w;
        }

        row_index += 1;
    }

    return total_h;
}

fn measureTableColumns(text: []const u8, start: usize, end: usize, max_w: f32, widths: *[TABLE_MAX_COLS]f32) usize {
    @memset(widths, 0);
    var col_count: usize = 0;
    var cursor = start;
    while (cursor < end) {
        const info = nextSourceLine(text, cursor);
        cursor = info.next;
        if (isTableSeparatorLine(info.line)) continue;

        var cells: [TABLE_MAX_COLS][]const u8 = .{""} ** TABLE_MAX_COLS;
        const count = parseTableRowCells(info.line, &cells);
        col_count = @max(col_count, count);
        for (0..count) |i| {
            var clean_buf: [256]u8 = undefined;
            const cell_text = cleanInline(&clean_buf, cells[i]);
            widths[i] = @max(widths[i], measureText(cell_text));
        }
    }
    if (col_count == 0) return 0;

    var natural_content_w: f32 = 0;
    for (0..col_count) |i| {
        widths[i] = @max(widths[i], TABLE_MIN_COL_W);
        natural_content_w += widths[i];
    }

    const chrome = @as(f32, @floatFromInt(col_count)) * (TABLE_CELL_PAD_X * 2 + 1) + 1;
    if (natural_content_w + chrome > max_w) {
        const available = @max(24.0, (max_w - chrome) / @as(f32, @floatFromInt(col_count)));
        for (0..col_count) |i| widths[i] = available;
    }

    return col_count;
}

fn tableUsedWidth(widths: []const f32) f32 {
    var total: f32 = 1;
    for (widths) |w| total += w + TABLE_CELL_PAD_X * 2 + 1;
    return total;
}

fn parseTableRowCells(line: []const u8, out: *[TABLE_MAX_COLS][]const u8) usize {
    var trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return 0;
    if (trimmed[0] == '|') trimmed = trimmed[1..];
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '|') trimmed = trimmed[0 .. trimmed.len - 1];

    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, trimmed, '|');
    while (parts.next()) |part| {
        if (count >= TABLE_MAX_COLS) break;
        out[count] = std.mem.trim(u8, part, " \t");
        count += 1;
    }
    return count;
}

fn looksLikeTableRow(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    return trimmed.len > 0 and std.mem.indexOfScalar(u8, trimmed, '|') != null;
}

fn isTableSeparatorLine(line: []const u8) bool {
    if (!looksLikeTableRow(line)) return false;
    var cells: [TABLE_MAX_COLS][]const u8 = .{""} ** TABLE_MAX_COLS;
    const count = parseTableRowCells(line, &cells);
    if (count == 0) return false;

    for (cells[0..count]) |cell| {
        const trimmed = std.mem.trim(u8, cell, " \t");
        if (trimmed.len == 0) return false;
        var dash_count: usize = 0;
        for (trimmed) |ch| {
            if (ch == '-') {
                dash_count += 1;
                continue;
            }
            if (ch == ':') continue;
            return false;
        }
        if (dash_count == 0) return false;
    }
    return true;
}

fn renderWrappedText(
    text: []const u8,
    x: f32,
    top_px: f32,
    max_w: f32,
    line_h: f32,
    color: [3]f32,
    window_height: f32,
    clip_bottom_top_px: f32,
) f32 {
    var line_start: usize = 0;
    var line_width: f32 = 0;
    var i: usize = 0;
    var current_top = top_px;
    while (i < text.len) {
        if (text[i] == '\n') {
            renderTextLine(text[line_start..i], x, current_top, max_w, color, window_height, clip_bottom_top_px);
            current_top += line_h;
            i += 1;
            line_start = i;
            line_width = 0;
            continue;
        }
        const item = nextCodepoint(text, i);
        if (line_width > 0 and line_width + item.advance > max_w) {
            renderTextLine(text[line_start..i], x, current_top, max_w, color, window_height, clip_bottom_top_px);
            current_top += line_h;
            line_start = i;
            line_width = 0;
            continue;
        }
        line_width += item.advance;
        i += item.len;
    }
    renderTextLine(text[line_start..i], x, current_top, max_w, color, window_height, clip_bottom_top_px);
    return current_top + line_h;
}

fn renderTextLine(text: []const u8, x: f32, top_px: f32, max_w: f32, color: [3]f32, window_height: f32, clip_bottom_top_px: f32) void {
    if (top_px + lineHeight() < 0 or top_px > clip_bottom_top_px) return;
    const y = window_height - top_px - font.g_titlebar_cell_height;
    _ = titlebar.renderTextLimited(text, x, y, color, max_w);
}

fn renderTopQuad(x: f32, w: f32, window_height: f32, top_px: f32, h: f32, color: [3]f32) void {
    const y = window_height - top_px - h;
    gl_init.renderQuadAlpha(x, y, w, h, color, 0.96);
}

const CodepointItem = struct {
    len: usize,
    advance: f32,
};

fn nextCodepoint(text: []const u8, i: usize) CodepointItem {
    const first = text[i];
    const len = std.unicode.utf8ByteSequenceLength(first) catch 1;
    if (i + len > text.len) return .{ .len = 1, .advance = titlebar.titlebarGlyphAdvance('?') };
    const cp = std.unicode.utf8Decode(text[i .. i + len]) catch @as(u21, '?');
    return .{ .len = len, .advance = titlebar.titlebarGlyphAdvance(@intCast(cp)) };
}

fn countWrappedLines(text: []const u8, max_w: f32) usize {
    if (text.len == 0) return 1;
    var lines: usize = 1;
    var width: f32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\n') {
            lines += 1;
            width = 0;
            i += 1;
            continue;
        }
        const item = nextCodepoint(text, i);
        if (width > 0 and width + item.advance > max_w) {
            lines += 1;
            width = 0;
        }
        width += item.advance;
        i += item.len;
    }
    return lines;
}

pub fn inputCursorX(text: []const u8, x: f32, max_w: f32) f32 {
    var width: f32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const item = nextCodepoint(text, i);
        if (width + item.advance > max_w) break;
        width += item.advance;
        i += item.len;
    }
    return x + width + 2;
}

fn measureText(text: []const u8) f32 {
    var width: f32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const item = nextCodepoint(text, i);
        width += item.advance;
        i += item.len;
    }
    return width;
}

fn detailHeaderHeight() f32 {
    return @round(@max(34.0, font.g_titlebar_cell_height + 12.0));
}

fn reasoningLineHeight() f32 {
    return @round(@max(21.0, font.g_titlebar_cell_height + 6.0));
}

fn tableRowHeight() f32 {
    return @round(@max(28.0, font.g_titlebar_cell_height + 10.0));
}

fn blankLineHeight() f32 {
    return @round(@max(12.0, lineHeight() * 0.56));
}

fn fenceLineHeight() f32 {
    return @round(@max(16.0, lineHeight() * 0.72));
}

fn lineHeight() f32 {
    return @round(@max(23.0, font.g_titlebar_cell_height + 8.0));
}

fn mixColor(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    const clamped = @max(0.0, @min(1.0, t));
    return .{
        a[0] + (b[0] - a[0]) * clamped,
        a[1] + (b[1] - a[1]) * clamped,
        a[2] + (b[2] - a[2]) * clamped,
    };
}

const Heading = struct {
    level: usize,
    body: []const u8,
};

const List = struct {
    marker: []const u8,
    body: []const u8,
};

const Link = struct {
    label: []const u8,
    end: usize,
};

fn headingBody(line: []const u8) ?Heading {
    var level: usize = 0;
    while (level < line.len and line[level] == '#' and level < 6) : (level += 1) {}
    if (level == 0 or level >= line.len or line[level] != ' ') return null;
    return .{ .level = level, .body = std.mem.trimLeft(u8, line[level + 1 ..], " \t") };
}

fn htmlHeadingBody(line: []const u8) ?Heading {
    if (line.len < 4 or line[0] != '<' or (line[1] != 'h' and line[1] != 'H')) return null;
    const level_ch = line[2];
    if (level_ch < '1' or level_ch > '6') return null;
    const open_end = std.mem.indexOfScalar(u8, line, '>') orelse return null;
    const close_start = std.mem.indexOf(u8, line[open_end + 1 ..], "</") orelse line.len - (open_end + 1);
    return .{
        .level = @intCast(level_ch - '0'),
        .body = line[open_end + 1 .. open_end + 1 + close_start],
    };
}

fn isFence(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "```") or std.mem.startsWith(u8, line, "~~~");
}

fn fenceLanguage(line: []const u8) []const u8 {
    if (!isFence(line) or line.len <= 3) return "";
    return std.mem.trim(u8, line[3..], " \t");
}

fn isHorizontalRule(line: []const u8) bool {
    var marker: u8 = 0;
    var count: usize = 0;
    for (line) |ch| {
        if (ch == ' ' or ch == '\t') continue;
        if (ch != '-' and ch != '*' and ch != '_') return false;
        if (marker == 0) marker = ch;
        if (ch != marker) return false;
        count += 1;
    }
    return count >= 3;
}

fn listBody(line: []const u8) ?List {
    if (line.len >= 2 and (line[0] == '-' or line[0] == '*' or line[0] == '+') and isSpace(line[1])) {
        const body = std.mem.trimLeft(u8, line[2..], " \t");
        if (std.mem.startsWith(u8, body, "[ ] ")) return .{ .marker = "[ ] ", .body = body[4..] };
        if (body.len >= 4 and body[0] == '[' and (body[1] == 'x' or body[1] == 'X') and body[2] == ']' and isSpace(body[3])) {
            return .{ .marker = "[x] ", .body = body[4..] };
        }
        return .{ .marker = "- ", .body = body };
    }

    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
    if (i > 0 and i + 1 < line.len and (line[i] == '.' or line[i] == ')') and isSpace(line[i + 1])) {
        return .{
            .marker = line[0 .. i + 2],
            .body = std.mem.trimLeft(u8, line[i + 2 ..], " \t"),
        };
    }
    return null;
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t';
}

fn cleanPlain(buf: []u8, text: []const u8) []const u8 {
    var pos: usize = 0;
    for (text) |ch| {
        if (pos >= buf.len) break;
        if (ch == '\r' or ch == '\n' or ch == 0x1b) continue;
        buf[pos] = ch;
        pos += 1;
    }
    return std.mem.trim(u8, buf[0..pos], " \t");
}

fn cleanInline(buf: []u8, text: []const u8) []const u8 {
    var pos: usize = 0;
    var i: usize = 0;
    while (i < text.len and pos < buf.len) {
        const ch = text[i];
        if (ch == '<') {
            while (i < text.len and text[i] != '>') : (i += 1) {}
            if (i < text.len) i += 1;
            continue;
        }
        if (ch == '[') {
            if (parseMarkdownLink(text, i)) |link| {
                pos = appendSlice(buf, pos, link.label);
                i = link.end;
                continue;
            }
        }
        if (ch == '!' and i + 1 < text.len and text[i + 1] == '[') {
            if (parseMarkdownLink(text, i + 1)) |link| {
                pos = appendSlice(buf, pos, link.label);
                i = link.end;
                continue;
            }
        }
        if (ch == '*' or ch == '_' or ch == '`' or ch == '\r' or ch == '\n' or ch == 0x1b) {
            i += 1;
            continue;
        }
        buf[pos] = ch;
        pos += 1;
        i += 1;
    }
    return std.mem.trim(u8, buf[0..pos], " \t");
}

fn parseMarkdownLink(text: []const u8, bracket: usize) ?Link {
    const close_rel = std.mem.indexOfScalar(u8, text[bracket + 1 ..], ']') orelse return null;
    const close = bracket + 1 + close_rel;
    if (close + 1 >= text.len or text[close + 1] != '(') return null;
    const url_start = close + 2;
    const url_rel = std.mem.indexOfScalar(u8, text[url_start..], ')') orelse return null;
    return .{
        .label = text[bracket + 1 .. close],
        .end = url_start + url_rel + 1,
    };
}

fn appendSlice(buf: []u8, pos: usize, text: []const u8) usize {
    const len = @min(text.len, buf.len - pos);
    @memcpy(buf[pos..][0..len], text[0..len]);
    return pos + len;
}
