const std = @import("std");
const builtin = @import("builtin");
const config = @import("../core/config.zig");
const agent_mod = @import("../core/agent.zig");

// ─────────────────────────────────────────────
// Win32 Console API for colors on Windows XP
// ─────────────────────────────────────────────
const HANDLE = *anyopaque;
const WORD = u16;
const DWORD = u32;
const BOOL = i32;
const COORD = extern struct { X: i16, Y: i16 };
const SMALL_RECT = extern struct { Left: i16, Top: i16, Right: i16, Bottom: i16 };
const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: COORD,
    dwCursorPosition: COORD,
    wAttributes: WORD,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: COORD,
};

extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) HANDLE;
extern "kernel32" fn SetConsoleTextAttribute(hConsoleOutput: HANDLE, wAttributes: WORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOutput: HANDLE, lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) BOOL;
extern "kernel32" fn SetConsoleTitleA(lpConsoleTitle: [*:0]const u8) callconv(.winapi) BOOL;

const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));

// Win32 Console Colors
const FG_BLACK: WORD = 0x0000;
const FG_BLUE: WORD = 0x0001;
const FG_GREEN: WORD = 0x0002;
const FG_CYAN: WORD = 0x0003;
const FG_RED: WORD = 0x0004;
const FG_MAGENTA: WORD = 0x0005;
const FG_YELLOW: WORD = 0x0006;
const FG_WHITE: WORD = 0x0007;
const FG_INTENSE: WORD = 0x0008;
const BG_BLUE: WORD = 0x0010;
const BG_GREEN: WORD = 0x0020;
const BG_CYAN: WORD = 0x0030;

// Color presets
const CLR_HEADER: WORD = FG_CYAN | FG_INTENSE;
const CLR_PROMPT: WORD = FG_GREEN | FG_INTENSE;
const CLR_INFO: WORD = FG_CYAN;
const CLR_WARN: WORD = FG_YELLOW | FG_INTENSE;
const CLR_ERR: WORD = FG_RED | FG_INTENSE;
const CLR_TOOL: WORD = FG_MAGENTA | FG_INTENSE;
const CLR_DIM: WORD = FG_WHITE;
const CLR_TEXT: WORD = FG_WHITE | FG_INTENSE;
const CLR_ACCENT: WORD = FG_YELLOW;
const CLR_DEFAULT: WORD = FG_WHITE | FG_INTENSE;

// ─────────────────────────────────────────────
// Box-drawing chars (CP437/CP850 compatible)
// ─────────────────────────────────────────────
// Single line:  \xda \xbf \xc0 \xd9 \xc4 \xb3
// Double line:  \xc9 \xbb \xc8 \xbc \xcd \xba
// Mixed:        \xd5 \xb8 \xd4 \xbe \xc4 \xb3

const BOX_TL = "\xc9"; // top-left double
const BOX_TR = "\xbb"; // top-right double
const BOX_BL = "\xc8"; // bottom-left double
const BOX_BR = "\xbc"; // bottom-right double
const BOX_H  = "\xcd"; // horizontal double
const BOX_V  = "\xba"; // vertical double
const BOX_TL_S = "\xda"; // top-left single
const BOX_TR_S = "\xbf"; // top-right single
const BOX_BL_S = "\xc0"; // bottom-left single
const BOX_BR_S = "\xd9"; // bottom-right single
const BOX_H_S  = "\xc4"; // horizontal single
const BOX_V_S  = "\xb3"; // vertical single
const BOX_T_S  = "\xc2"; // T-junction top single
const BOX_B_S  = "\xc1"; // T-junction bottom single
const BOX_CROSS = "\xc5"; // cross single
const BLOCK_FULL = "\xdb"; // full block
const BLOCK_HALF = "\xdd"; // right half block
const SHADE_LIGHT = "\xb0"; // light shade
const SHADE_MED = "\xb1"; // medium shade
const ARROW_R = "\x10"; // right arrow
const BULLET = "\x07"; // bullet

// ─────────────────────────────────────────────
// Console helper
// ─────────────────────────────────────────────
var console_handle: ?HANDLE = null;
var saved_attributes: WORD = CLR_DEFAULT;

fn getConsole() HANDLE {
    if (console_handle) |h| return h;
    const h = GetStdHandle(STD_OUTPUT_HANDLE);
    console_handle = h;
    // Save original attributes
    var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
    _ = GetConsoleScreenBufferInfo(h, &info);
    saved_attributes = info.wAttributes;
    return h;
}

fn setColor(color: WORD) void {
    if (builtin.os.tag == .windows) {
        _ = SetConsoleTextAttribute(getConsole(), color);
    }
}

fn resetColor() void {
    if (builtin.os.tag == .windows) {
        _ = SetConsoleTextAttribute(getConsole(), CLR_DEFAULT);
    }
}

fn getConsoleWidth() u16 {
    if (builtin.os.tag == .windows) {
        var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
        _ = GetConsoleScreenBufferInfo(getConsole(), &info);
        const w = info.srWindow.Right - info.srWindow.Left + 1;
        return if (w > 20) @intCast(w) else 80;
    }
    return 80;
}

// ─────────────────────────────────────────────
// Drawing primitives
// ─────────────────────────────────────────────
fn drawHLine(stdout: std.fs.File, ch: []const u8, width: usize) !void {
    var i: usize = 0;
    while (i < width) : (i += 1) {
        try stdout.writeAll(ch);
    }
}

fn drawBoxTop(stdout: std.fs.File, width: usize) !void {
    setColor(CLR_HEADER);
    try stdout.writeAll(BOX_TL);
    try drawHLine(stdout, BOX_H, width - 2);
    try stdout.writeAll(BOX_TR);
    try stdout.writeAll("\n");
}

fn drawBoxBottom(stdout: std.fs.File, width: usize) !void {
    setColor(CLR_HEADER);
    try stdout.writeAll(BOX_BL);
    try drawHLine(stdout, BOX_H, width - 2);
    try stdout.writeAll(BOX_BR);
    try stdout.writeAll("\n");
    resetColor();
}

fn drawBoxLine(stdout: std.fs.File, text: []const u8, width: usize, color: WORD) !void {
    setColor(CLR_HEADER);
    try stdout.writeAll(BOX_V);
    try stdout.writeAll(" ");
    setColor(color);
    
    // Calculate available space: width - 2 (borders) - 2 (padding left+right)
    const avail = if (width > 3) width - 3 else 0;
    
    if (text.len <= avail) {
        try stdout.writeAll(text);
        // Pad remaining
        var i: usize = text.len;
        while (i < avail) : (i += 1) {
            try stdout.writeAll(" ");
        }
    } else {
        // Truncate
        try stdout.writeAll(text[0..avail]);
    }
    
    setColor(CLR_HEADER);
    try stdout.writeAll(" ");
    try stdout.writeAll(BOX_V);
    try stdout.writeAll("\n");
}

fn drawSeparator(stdout: std.fs.File, width: usize) !void {
    setColor(CLR_DIM);
    try drawHLine(stdout, BOX_H_S, width);
    try stdout.writeAll("\n");
    resetColor();
}

// ─────────────────────────────────────────────
// Banner
// ─────────────────────────────────────────────
fn drawBanner(stdout: std.fs.File, cfg: *config.Config) !void {
    const w: usize = 52;
    var buf: [256]u8 = undefined;

    // Set console title
    if (builtin.os.tag == .windows) {
        _ = SetConsoleTitleA("Retro Agent - Windows XP System Assistant");
    }

    try stdout.writeAll("\n");
    drawBoxTop(stdout, w) catch {};
    drawBoxLine(stdout, "", w, CLR_TEXT) catch {};
    drawBoxLine(stdout, "  Retro Agent v0.1.0", w, CLR_TEXT) catch {};
    drawBoxLine(stdout, "  Windows XP System Assistant", w, CLR_DIM) catch {};
    drawBoxLine(stdout, "", w, CLR_TEXT) catch {};

    // Separator inside box
    setColor(CLR_HEADER);
    try stdout.writeAll(BOX_V);
    setColor(CLR_DIM);
    try drawHLine(stdout, BOX_H_S, w - 2);
    setColor(CLR_HEADER);
    try stdout.writeAll(BOX_V);
    try stdout.writeAll("\n");

    // Agent info
    const agent_line = std.fmt.bufPrint(&buf, "Agent:    {s}", .{cfg.agent_name}) catch "Agent: ?";
    drawBoxLine(stdout, agent_line, w, CLR_INFO) catch {};

    const mode_line = std.fmt.bufPrint(&buf, "Mode:     {s}", .{@tagName(cfg.mode)}) catch "Mode: ?";
    drawBoxLine(stdout, mode_line, w, CLR_INFO) catch {};

    if (cfg.mode == .api or cfg.mode == .interactive) {
        const model_line = std.fmt.bufPrint(&buf, "Model:    {s}", .{cfg.transport_api_model}) catch "Model: ?";
        drawBoxLine(stdout, model_line, w, CLR_INFO) catch {};

        const endpoint_line = std.fmt.bufPrint(&buf, "Endpoint: {s}", .{cfg.transport_api_base_url}) catch "Endpoint: ?";
        drawBoxLine(stdout, endpoint_line, w, CLR_DIM) catch {};
    }

    const approval_str = if (cfg.security_require_approval) "enabled" else "disabled";
    const approval_line = std.fmt.bufPrint(&buf, "Approval: {s}", .{approval_str}) catch "Approval: ?";
    drawBoxLine(stdout, approval_line, w, CLR_DIM) catch {};

    drawBoxLine(stdout, "", w, CLR_TEXT) catch {};
    drawBoxBottom(stdout, w) catch {};

    try stdout.writeAll("\n");
    setColor(CLR_DIM);
    try stdout.writeAll("  Type ");
    setColor(CLR_ACCENT);
    try stdout.writeAll("/help");
    setColor(CLR_DIM);
    try stdout.writeAll(" for commands, or ask a question in natural language.\n\n");
    resetColor();
}

// ─────────────────────────────────────────────
// Help screen
// ─────────────────────────────────────────────
fn drawHelp(stdout: std.fs.File) !void {
    try stdout.writeAll("\n");
    setColor(CLR_HEADER);
    try stdout.writeAll("  COMMANDS\n");
    setColor(CLR_DIM);
    try drawHLine(stdout, BOX_H_S, 50);
    try stdout.writeAll("\n");

    const cmds = [_][2][]const u8{
        .{ "/help", "Show this help" },
        .{ "/tools", "List available tools" },
        .{ "/info", "Show configuration" },
        .{ "/clear", "Clear conversation history" },
        .{ "/quit", "Exit micro-agent" },
    };

    for (cmds) |cmd| {
        setColor(CLR_ACCENT);
        try stdout.writeAll("  ");
        try stdout.writeAll(cmd[0]);
        // Pad to 12 chars
        var pad: usize = cmd[0].len;
        while (pad < 10) : (pad += 1) try stdout.writeAll(" ");
        setColor(CLR_DIM);
        try stdout.writeAll(cmd[1]);
        try stdout.writeAll("\n");
    }

    try stdout.writeAll("\n");
    setColor(CLR_HEADER);
    try stdout.writeAll("  EXAMPLES\n");
    setColor(CLR_DIM);
    try drawHLine(stdout, BOX_H_S, 50);
    try stdout.writeAll("\n");

    const examples = [_][]const u8{
        "\"Check system memory\"",
        "\"List running processes\"",
        "\"Ping google.com\"",
        "\"Show disk space on C:\"",
        "\"Why is the system slow?\"",
        "\"Write a report to C:\\report.txt\"",
    };

    for (examples) |ex| {
        setColor(CLR_DIM);
        try stdout.writeAll("  ");
        try stdout.writeAll(ARROW_R);
        try stdout.writeAll(" ");
        setColor(CLR_TEXT);
        try stdout.writeAll(ex);
        try stdout.writeAll("\n");
    }

    try stdout.writeAll("\n");
    resetColor();
}

// ─────────────────────────────────────────────
// Tools list
// ─────────────────────────────────────────────
fn drawToolsList(stdout: std.fs.File, ag: *agent_mod.Agent) !void {
    var buf: [512]u8 = undefined;

    try stdout.writeAll("\n");
    setColor(CLR_HEADER);
    try stdout.writeAll("  AVAILABLE TOOLS\n");
    setColor(CLR_DIM);
    try drawHLine(stdout, BOX_H_S, 60);
    try stdout.writeAll("\n\n");

    var count: usize = 0;
    for (ag.tool_registry.tools.items) |tool| {
        if (!tool.enabled) continue;

        // Tool name with bullet
        setColor(CLR_TOOL);
        try stdout.writeAll("  ");
        try stdout.writeAll(BLOCK_HALF);
        try stdout.writeAll(" ");
        setColor(CLR_TEXT);
        try stdout.writeAll(tool.name);
        try stdout.writeAll("\n");

        // Description
        setColor(CLR_DIM);
        try stdout.writeAll("    ");
        // Truncate long descriptions
        const max_desc: usize = 65;
        if (tool.description.len > max_desc) {
            try stdout.writeAll(tool.description[0..max_desc]);
            try stdout.writeAll("...");
        } else {
            try stdout.writeAll(tool.description);
        }
        try stdout.writeAll("\n\n");
        count += 1;
    }

    setColor(CLR_DIM);
    try drawHLine(stdout, BOX_H_S, 60);
    try stdout.writeAll("\n");
    setColor(CLR_INFO);
    const total = std.fmt.bufPrint(&buf, "  {d} tools available\n\n", .{count}) catch "  ? tools\n\n";
    try stdout.writeAll(total);
    resetColor();
}

// ─────────────────────────────────────────────
// Info screen
// ─────────────────────────────────────────────
fn drawInfo(stdout: std.fs.File, ag: *agent_mod.Agent, cfg: *config.Config) !void {
    var buf: [512]u8 = undefined;

    try stdout.writeAll("\n");
    setColor(CLR_HEADER);
    try stdout.writeAll("  CONFIGURATION\n");
    setColor(CLR_DIM);
    try drawHLine(stdout, BOX_H_S, 50);
    try stdout.writeAll("\n\n");

    const fields = [_][2][]const u8{
        .{ "Agent", cfg.agent_name },
        .{ "Mode", @tagName(cfg.mode) },
        .{ "Provider", cfg.transport_api_provider },
        .{ "Model", cfg.transport_api_model },
        .{ "Endpoint", cfg.transport_api_base_url },
    };

    for (fields) |f| {
        setColor(CLR_DIM);
        try stdout.writeAll("  ");
        try stdout.writeAll(f[0]);
        var pad: usize = f[0].len;
        while (pad < 12) : (pad += 1) try stdout.writeAll(" ");
        setColor(CLR_TEXT);
        try stdout.writeAll(f[1]);
        try stdout.writeAll("\n");
    }

    // Approval
    setColor(CLR_DIM);
    try stdout.writeAll("  Approval    ");
    if (cfg.security_require_approval) {
        setColor(CLR_WARN);
        try stdout.writeAll("enabled");
    } else {
        setColor(CLR_INFO);
        try stdout.writeAll("disabled");
    }
    try stdout.writeAll("\n");

    // History
    setColor(CLR_DIM);
    try stdout.writeAll("  History     ");
    setColor(CLR_TEXT);
    const hist = std.fmt.bufPrint(&buf, "{d} messages", .{ag.history.items.len}) catch "?";
    try stdout.writeAll(hist);
    try stdout.writeAll("\n\n");
    resetColor();
}

// ─────────────────────────────────────────────
// UTF-8 sanitization for CP850/CP437 console
// ─────────────────────────────────────────────
// The LLM responds in UTF-8, but the Windows XP console renders bytes as CP850.
// Multi-byte UTF-8 sequences (accented chars, special symbols) become garbage.
// This function replaces common UTF-8 codepoints with their closest ASCII/CP850
// equivalents, and drops anything else non-ASCII that has no good mapping.
fn sanitizeUtf8ForConsole(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).initCapacity(allocator, input.len) catch unreachable;
    const writer = result.writer(allocator);

    var i: usize = 0;
    while (i < input.len) {
        const byte = input[i];
        if (byte < 0x80) {
            // ASCII — pass through
            try writer.writeByte(byte);
            i += 1;
            continue;
        }

        // Decode UTF-8 codepoint
        var codepoint: u21 = 0;
        var seq_len: usize = 0;

        if (byte & 0xE0 == 0xC0) {
            seq_len = 2;
            if (i + 1 < input.len and input[i + 1] & 0xC0 == 0x80) {
                codepoint = (@as(u21, byte & 0x1F) << 6) | @as(u21, input[i + 1] & 0x3F);
            } else {
                try writer.writeByte('?');
                i += 1;
                continue;
            }
        } else if (byte & 0xF0 == 0xE0) {
            seq_len = 3;
            if (i + 2 < input.len and input[i + 1] & 0xC0 == 0x80 and input[i + 2] & 0xC0 == 0x80) {
                codepoint = (@as(u21, byte & 0x0F) << 12) | (@as(u21, input[i + 1] & 0x3F) << 6) | @as(u21, input[i + 2] & 0x3F);
            } else {
                try writer.writeByte('?');
                i += 1;
                continue;
            }
        } else if (byte & 0xF8 == 0xF0) {
            seq_len = 4;
            if (i + 3 < input.len and input[i + 1] & 0xC0 == 0x80 and input[i + 2] & 0xC0 == 0x80 and input[i + 3] & 0xC0 == 0x80) {
                codepoint = (@as(u21, byte & 0x07) << 18) | (@as(u21, input[i + 1] & 0x3F) << 12) | (@as(u21, input[i + 2] & 0x3F) << 6) | @as(u21, input[i + 3] & 0x3F);
            } else {
                try writer.writeByte('?');
                i += 1;
                continue;
            }
        } else {
            // Invalid lead byte
            try writer.writeByte('?');
            i += 1;
            continue;
        }

        // Map common Unicode codepoints to ASCII equivalents
        switch (codepoint) {
            // Accented vowels → base letter
            0xE0, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5 => try writer.writeByte('a'),
            0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5 => try writer.writeByte('A'),
            0xE8, 0xE9, 0xEA, 0xEB => try writer.writeByte('e'),
            0xC8, 0xC9, 0xCA, 0xCB => try writer.writeByte('E'),
            0xEC, 0xED, 0xEE, 0xEF => try writer.writeByte('i'),
            0xCC, 0xCD, 0xCE, 0xCF => try writer.writeByte('I'),
            0xF2, 0xF3, 0xF4, 0xF5, 0xF6 => try writer.writeByte('o'),
            0xD2, 0xD3, 0xD4, 0xD5, 0xD6 => try writer.writeByte('O'),
            0xF9, 0xFA, 0xFB, 0xFC => try writer.writeByte('u'),
            0xD9, 0xDA, 0xDB, 0xDC => try writer.writeByte('U'),
            0xF1 => try writer.writeByte('n'),
            0xD1 => try writer.writeByte('N'),
            0xE7 => try writer.writeByte('c'),
            0xC7 => try writer.writeByte('C'),
            0xDF => try writer.writeAll("ss"), // ß
            0xE6 => try writer.writeAll("ae"), // æ
            0xC6 => try writer.writeAll("AE"), // Æ
            0xF8 => try writer.writeByte('o'), // ø
            0xD8 => try writer.writeByte('O'), // Ø
            // Punctuation and symbols
            0x2018, 0x2019 => try writer.writeByte('\''), // smart quotes
            0x201C, 0x201D => try writer.writeByte('"'), // smart double quotes
            0x2013 => try writer.writeByte('-'), // en dash
            0x2014 => try writer.writeAll("--"), // em dash
            0x2026 => try writer.writeAll("..."), // ellipsis
            0x2022 => try writer.writeByte('*'), // bullet
            0x00B7 => try writer.writeByte('.'), // middle dot
            0x00AB, 0x00BB => try writer.writeByte('"'), // guillemets
            0x00A0 => try writer.writeByte(' '), // non-breaking space
            0x00B0 => try writer.writeByte('o'), // degree sign
            0x00D7 => try writer.writeByte('x'), // multiplication sign
            0x00F7 => try writer.writeByte('/'), // division sign
            0x00A9 => try writer.writeAll("(c)"), // ©
            0x00AE => try writer.writeAll("(R)"), // ®
            0x2122 => try writer.writeAll("(TM)"), // ™
            0x00B1 => try writer.writeAll("+/-"), // ±
            0x2248 => try writer.writeByte('~'), // ≈
            0x2260 => try writer.writeAll("!="), // ≠
            0x2264 => try writer.writeAll("<="), // ≤
            0x2265 => try writer.writeAll(">="), // ≥
            0x2192 => try writer.writeAll("->"), // →
            0x2190 => try writer.writeAll("<-"), // ←
            0x00BC => try writer.writeAll("1/4"), // ¼
            0x00BD => try writer.writeAll("1/2"), // ½
            0x00BE => try writer.writeAll("3/4"), // ¾
            0x00B2 => try writer.writeByte('2'), // ²
            0x00B3 => try writer.writeByte('3'), // ³
            0x00B9 => try writer.writeByte('1'), // ¹
            // Anything else non-ASCII: skip silently
            else => {},
        }

        i += seq_len;
    }

    return try result.toOwnedSlice(allocator);
}

// ─────────────────────────────────────────────
// Response formatting
// ─────────────────────────────────────────────
fn printFormattedResponse(stdout: std.fs.File, allocator: std.mem.Allocator, response: []const u8) !void {
    const max_width: usize = 76;

    // Sanitize UTF-8 for CP850 console on Windows XP
    const safe_response = if (builtin.os.tag == .windows)
        sanitizeUtf8ForConsole(allocator, response) catch response
    else
        response;
    defer if (builtin.os.tag == .windows and safe_response.ptr != response.ptr) allocator.free(safe_response);

    setColor(CLR_TEXT);

    var lines_iter = std.mem.splitSequence(u8, safe_response, "\n");
    while (lines_iter.next()) |line| {
        if (line.len == 0) {
            try stdout.writeAll("\n");
            continue;
        }

        const trimmed = std.mem.trim(u8, line, "\r");

        // Section headers (===)
        if (std.mem.startsWith(u8, trimmed, "===")) {
            setColor(CLR_HEADER);
            try stdout.writeAll(trimmed);
            try stdout.writeAll("\n");
            setColor(CLR_TEXT);
            continue;
        }

        // Separator lines (---)
        if (std.mem.startsWith(u8, trimmed, "---")) {
            setColor(CLR_DIM);
            try drawHLine(stdout, BOX_H_S, @min(trimmed.len, max_width));
            try stdout.writeAll("\n");
            setColor(CLR_TEXT);
            continue;
        }

        // Bullet points
        if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ")) {
            setColor(CLR_ACCENT);
            try stdout.writeAll("  ");
            try stdout.writeAll(ARROW_R);
            setColor(CLR_TEXT);
            try stdout.writeAll(trimmed[1..]);
            try stdout.writeAll("\n");
            continue;
        }

        // Numbered items
        if (trimmed.len > 2 and trimmed[0] >= '1' and trimmed[0] <= '9' and trimmed[1] == '.') {
            setColor(CLR_ACCENT);
            try stdout.writeAll("  ");
            try stdout.writeAll(trimmed[0..1]);
            try stdout.writeAll(".");
            setColor(CLR_TEXT);
            try stdout.writeAll(trimmed[2..]);
            try stdout.writeAll("\n");
            continue;
        }

        // Word wrap long lines
        if (trimmed.len > max_width) {
            var remaining: []const u8 = trimmed;
            while (remaining.len > 0) {
                const chunk_len = @min(max_width, remaining.len);
                if (chunk_len < remaining.len) {
                    // Break at word boundary
                    if (std.mem.lastIndexOf(u8, remaining[0..chunk_len], " ")) |last_space| {
                        try stdout.writeAll(remaining[0..last_space]);
                        try stdout.writeAll("\n");
                        remaining = std.mem.trimLeft(u8, remaining[last_space..], " ");
                        continue;
                    }
                }
                try stdout.writeAll(remaining[0..chunk_len]);
                remaining = remaining[chunk_len..];
                if (remaining.len > 0) try stdout.writeAll("\n");
            }
            try stdout.writeAll("\n");
        } else {
            try stdout.writeAll(trimmed);
            try stdout.writeAll("\n");
        }
    }

    try stdout.writeAll("\n");
    resetColor();
}

// ─────────────────────────────────────────────
// Processing indicator
// ─────────────────────────────────────────────
fn showProcessing(stdout: std.fs.File) !void {
    setColor(CLR_DIM);
    try stdout.writeAll("\n  ");
    try stdout.writeAll(SHADE_MED);
    try stdout.writeAll(SHADE_MED);
    try stdout.writeAll(SHADE_MED);
    try stdout.writeAll(" Processing");
    try stdout.writeAll(" ");
    try stdout.writeAll(SHADE_MED);
    try stdout.writeAll(SHADE_MED);
    try stdout.writeAll(SHADE_MED);
    try stdout.writeAll("\n\n");
    resetColor();
}

// ─────────────────────────────────────────────
// Main run loop
// ─────────────────────────────────────────────
pub fn run(allocator: std.mem.Allocator, cfg: *config.Config) !void {
    const stdout = std.fs.File.stdout();
    var msg_buf: [4096]u8 = undefined;

    // Draw banner
    try drawBanner(stdout, cfg);

    // Initialize agent
    var ag = try agent_mod.Agent.init(allocator, cfg);
    defer ag.deinit();

    // Main input loop
    var input_buf: [4096]u8 = undefined;

    while (true) {
        // Prompt
        setColor(CLR_PROMPT);
        try stdout.writeAll(ARROW_R);
        try stdout.writeAll(" ");
        resetColor();

        const bytes_read = std.fs.File.stdin().read(&input_buf) catch |err| {
            if (err == error.EndOfStream) break;
            setColor(CLR_ERR);
            try stdout.writeAll("Error reading input\n");
            resetColor();
            return err;
        };
        if (bytes_read == 0) break;

        const trimmed = std.mem.trim(u8, input_buf[0..bytes_read], " \t\r\n");
        if (trimmed.len == 0) continue;

        // Handle slash commands
        if (trimmed[0] == '/') {
            const should_continue = try handleCommand(trimmed, &ag, cfg);
            if (!should_continue) break;
            continue;
        }

        // Send to agent
        try showProcessing(stdout);

        const response = ag.processMessage(trimmed) catch |err| {
            setColor(CLR_ERR);
            const msg = std.fmt.bufPrint(&msg_buf, "  Error: {}\n", .{err}) catch "  Error\n";
            try stdout.writeAll(msg);
            resetColor();
            continue;
        };

        try printFormattedResponse(stdout, allocator, response);
    }

    // Goodbye
    try stdout.writeAll("\n");
    setColor(CLR_DIM);
    try drawHLine(stdout, BOX_H_S, 40);
    try stdout.writeAll("\n");
    setColor(CLR_INFO);
    try stdout.writeAll("  Session ended. Goodbye.\n\n");
    resetColor();
}

fn handleCommand(
    cmd: []const u8,
    ag: *agent_mod.Agent,
    cfg: *config.Config,
) !bool {
    const stdout = std.fs.File.stdout();

    if (std.mem.eql(u8, cmd, "/quit") or std.mem.eql(u8, cmd, "/exit") or std.mem.eql(u8, cmd, "/q")) {
        return false;
    }

    if (std.mem.eql(u8, cmd, "/help") or std.mem.eql(u8, cmd, "/h")) {
        try drawHelp(stdout);
        return true;
    }

    if (std.mem.eql(u8, cmd, "/info")) {
        try drawInfo(stdout, ag, cfg);
        return true;
    }

    if (std.mem.eql(u8, cmd, "/tools")) {
        try drawToolsList(stdout, ag);
        return true;
    }

    if (std.mem.eql(u8, cmd, "/mode")) {
        try stdout.writeAll("\n");
        setColor(CLR_INFO);
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "  Mode: {s}\n\n", .{@tagName(cfg.mode)}) catch "  Mode: ?\n\n";
        try stdout.writeAll(msg);
        resetColor();
        return true;
    }

    if (std.mem.eql(u8, cmd, "/clear")) {
        for (ag.history.items) |msg| {
            ag.allocator.free(msg.content);
            if (msg.tool_id) |id| ag.allocator.free(id);
            if (msg.tool_name) |name| ag.allocator.free(name);
        }
        ag.history.clearRetainingCapacity();

        const owned_system_prompt = try ag.allocator.dupe(u8, cfg.system_prompt);
        try ag.history.append(ag.allocator, .{
            .role = .system,
            .content = owned_system_prompt,
        });

        setColor(CLR_INFO);
        try stdout.writeAll("\n  History cleared.\n\n");
        resetColor();
        return true;
    }

    setColor(CLR_WARN);
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "\n  Unknown command: {s}. Type /help\n\n", .{cmd}) catch "\n  Unknown command\n\n";
    try stdout.writeAll(msg);
    resetColor();
    return true;
}

pub const StatusLevel = enum { info, warning, err };

fn showStatus(allocator: std.mem.Allocator, s: []const u8, level: StatusLevel) !void {
    _ = allocator;
    const stdout = std.fs.File.stdout();

    const color: WORD = switch (level) {
        .info => CLR_INFO,
        .warning => CLR_WARN,
        .err => CLR_ERR,
    };
    const symbol = switch (level) {
        .info => "[OK] ",
        .warning => "[!!] ",
        .err => "[XX] ",
    };

    setColor(color);
    try stdout.writeAll("  ");
    try stdout.writeAll(symbol);
    try stdout.writeAll(s);
    try stdout.writeAll("\n");
    resetColor();
}
