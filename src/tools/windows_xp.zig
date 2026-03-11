const std = @import("std");
const builtin = @import("builtin");
const config = @import("../core/config.zig");
// FIX 5: Import shared JSON utilities
const json_utils = @import("../utils/json.zig");
const registry = @import("registry.zig");

// ─────────────────────────────────────────────
// FIX 4: CP850 → UTF-8 conversion for Windows XP locale output
// ─────────────────────────────────────────────
// Note: An alternative is to run `chcp 65001` before commands to force UTF-8 console output,
// but this does not work reliably with all XP-era programs (e.g. systeminfo, netstat).
// A lookup table approach is more robust for legacy systems.

const cp850_to_unicode: [128]u21 = .{
    // 0x80-0x8F
    0x00C7, 0x00FC, 0x00E9, 0x00E2, 0x00E4, 0x00E0, 0x00E5, 0x00E7,
    0x00EA, 0x00EB, 0x00E8, 0x00EF, 0x00EE, 0x00EC, 0x00C4, 0x00C5,
    // 0x90-0x9F
    0x00C9, 0x00E6, 0x00C6, 0x00F4, 0x00F6, 0x00F2, 0x00FB, 0x00F9,
    0x00FF, 0x00D6, 0x00DC, 0x00F8, 0x00A3, 0x00D8, 0x00D7, 0x0192,
    // 0xA0-0xAF
    0x00E1, 0x00ED, 0x00F3, 0x00FA, 0x00F1, 0x00D1, 0x00AA, 0x00BA,
    0x00BF, 0x00AE, 0x00AC, 0x00BD, 0x00BC, 0x00A1, 0x00AB, 0x00BB,
    // 0xB0-0xBF
    0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x00C1, 0x00C2, 0x00C0,
    0x00A9, 0x2563, 0x2551, 0x2557, 0x255D, 0x00A2, 0x00A5, 0x2510,
    // 0xC0-0xCF
    0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x00E3, 0x00C3,
    0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x00A4,
    // 0xD0-0xDF
    0x00F0, 0x00D0, 0x00CA, 0x00CB, 0x00C8, 0x0131, 0x00CD, 0x00CE,
    0x00CF, 0x2518, 0x250C, 0x2588, 0x2584, 0x00A6, 0x00CC, 0x2580,
    // 0xE0-0xEF
    0x00D3, 0x00DF, 0x00D4, 0x00D2, 0x00F5, 0x00D5, 0x00B5, 0x00FE,
    0x00DE, 0x00DA, 0x00DB, 0x00D9, 0x00FD, 0x00DD, 0x00AF, 0x00B4,
    // 0xF0-0xFF
    0x00AD, 0x00B1, 0x2017, 0x00BE, 0x00B6, 0x00A7, 0x00F7, 0x00B8,
    0x00B0, 0x00A8, 0x00B7, 0x00B9, 0x00B3, 0x00B2, 0x25A0, 0x00A0,
};

/// Check if a byte slice is valid UTF-8.
/// Returns true if the entire input is well-formed UTF-8, false if it contains
/// invalid sequences (likely CP850/Windows-1252 encoded text).
fn isValidUtf8(input: []const u8) bool {
    var i: usize = 0;
    while (i < input.len) {
        const byte = input[i];
        if (byte < 0x80) {
            // ASCII — always valid
            i += 1;
        } else if (byte & 0xE0 == 0xC0) {
            // 2-byte sequence: 110xxxxx 10xxxxxx
            if (i + 1 >= input.len) return false;
            if (input[i + 1] & 0xC0 != 0x80) return false;
            i += 2;
        } else if (byte & 0xF0 == 0xE0) {
            // 3-byte sequence: 1110xxxx 10xxxxxx 10xxxxxx
            if (i + 2 >= input.len) return false;
            if (input[i + 1] & 0xC0 != 0x80) return false;
            if (input[i + 2] & 0xC0 != 0x80) return false;
            i += 3;
        } else if (byte & 0xF8 == 0xF0) {
            // 4-byte sequence: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
            if (i + 3 >= input.len) return false;
            if (input[i + 1] & 0xC0 != 0x80) return false;
            if (input[i + 2] & 0xC0 != 0x80) return false;
            if (input[i + 3] & 0xC0 != 0x80) return false;
            i += 4;
        } else {
            // Bare continuation byte or invalid lead byte (0x80-0xBF, 0xF8+)
            // This is the key: CP850 bytes like 0x8A, 0x82, etc. land here
            return false;
        }
    }
    return true;
}

pub fn cp850ToUtf8(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    // Worst case: each byte becomes 3 UTF-8 bytes
    var result = try std.ArrayList(u8).initCapacity(allocator, input.len);
    const writer = result.writer(allocator);

    for (input) |byte| {
        if (byte < 0x80) {
            try writer.writeByte(byte);
        } else {
            const codepoint = cp850_to_unicode[byte - 0x80];
            if (codepoint <= 0x7FF) {
                // 2-byte UTF-8
                try writer.writeByte(@intCast(0xC0 | (codepoint >> 6)));
                try writer.writeByte(@intCast(0x80 | (codepoint & 0x3F)));
            } else {
                // 3-byte UTF-8
                try writer.writeByte(@intCast(0xE0 | (codepoint >> 12)));
                try writer.writeByte(@intCast(0x80 | ((codepoint >> 6) & 0x3F)));
                try writer.writeByte(@intCast(0x80 | (codepoint & 0x3F)));
            }
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Execute a Windows command and return output with proper encoding handling
/// FIX 3: Now accepts timeout_ms from config
/// FIX 4: Converts CP850 output to UTF-8 on Windows
pub fn execWindowsCommand(
    allocator: std.mem.Allocator,
    command: []const u8,
    cfg: *config.Config,
) ![]const u8 {
    const shell = if (builtin.os.tag == .windows)
        &[_][]const u8{ "cmd.exe", "/C", command }
    else
        &[_][]const u8{ "/bin/sh", "-c", command };

    var child = std.process.Child.init(shell, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // FIX 3: Use timeout from config via shared helper
    const timeout_ms = cfg.security_max_exec_timeout_ms;
    const result = try registry.waitWithTimeout(allocator, &child, timeout_ms);

    defer allocator.free(result.stderr);

    if (result.timed_out) {
        defer allocator.free(result.stdout);
        return try std.fmt.allocPrint(allocator, "Error: command timed out after {d}ms", .{timeout_ms});
    }

    const raw_stdout = result.stdout;

    // Use exit code from waitWithTimeout (process already waited)
    if (result.exit_code != 0 and result.stderr.len > 0) {
        defer allocator.free(raw_stdout);
        return try std.fmt.allocPrint(allocator, "Error (exit {d}): {s}", .{ result.exit_code, result.stderr });
    }

    // FIX 4: Convert CP850/Windows-1252 output to UTF-8 on Windows,
    // but only if the output is NOT already valid UTF-8 (e.g. wmic output
    // or LLM-generated text is already UTF-8 and must not be re-encoded).
    if (builtin.os.tag == .windows) {
        if (!isValidUtf8(raw_stdout)) {
            const utf8_output = try cp850ToUtf8(allocator, raw_stdout);
            allocator.free(raw_stdout);
            return utf8_output;
        }
    }

    return raw_stdout;
}

/// System Information - systeminfo command
pub fn toolSystemInfo(allocator: std.mem.Allocator, _: []const u8, cfg: *config.Config) ![]const u8 {
    const output = try execWindowsCommand(allocator, "systeminfo", cfg);
    defer allocator.free(output);
    
    var result = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    const writer = result.writer(allocator);
    
    try writer.writeAll("=== System Information ===\n\n");
    try writer.print("{s}\n", .{output});
    
    return try result.toOwnedSlice(allocator);
}

/// List Processes - tasklist command
pub fn toolListProcesses(allocator: std.mem.Allocator, arguments: []const u8, cfg: *config.Config) ![]const u8 {
    _ = arguments;
    
    const output = try execWindowsCommand(allocator, "tasklist /v /fo csv", cfg);
    defer allocator.free(output);
    
    var result = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    const writer = result.writer(allocator);
    
    try writer.writeAll("=== Running Processes ===\n\n");
    try writer.writeAll("PID    | Memory    | Name\n");
    try writer.writeAll("-------|-----------|----------------------------------\n");
    
    var lines = std.mem.splitSequence(u8, output, "\n");
    var count: usize = 0;
    
    _ = lines.next(); // Skip header
    
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\n\t\"");
        if (trimmed.len == 0) continue;
        
        var fields = std.mem.splitSequence(u8, trimmed, "\",\"");
        
        const name = fields.next() orelse continue;
        const pid = fields.next() orelse continue;
        _ = fields.next(); // session name
        _ = fields.next(); // session number
        const mem = fields.next() orelse continue;
        
        const clean_name = std.mem.trim(u8, name, "\"");
        const clean_pid = std.mem.trim(u8, pid, "\"");
        const clean_mem = std.mem.trim(u8, mem, "\"");
        
        try writer.print("{s:6} | {s:9} | {s}\n", .{ clean_pid, clean_mem, clean_name });
        count += 1;
        
        if (count >= 50) {
            try writer.writeAll("\n[Showing first 50 processes. Use filter for specific search]\n");
            break;
        }
    }
    
    try writer.print("\nTotal processes shown: {d}\n", .{count});
    
    return try result.toOwnedSlice(allocator);
}

/// Network Status - netstat command
pub fn toolNetworkStatus(allocator: std.mem.Allocator, _: []const u8, cfg: *config.Config) ![]const u8 {
    const output = try execWindowsCommand(allocator, "netstat -an", cfg);
    defer allocator.free(output);
    
    var result = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    const writer = result.writer(allocator);
    
    try writer.writeAll("=== Network Connections ===\n\n");
    
    var listening: usize = 0;
    var established: usize = 0;
    var time_wait: usize = 0;
    
    var lines = std.mem.splitSequence(u8, output, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\n\t");
        if (trimmed.len == 0) continue;
        
        if (std.mem.indexOf(u8, trimmed, "LISTENING") != null) {
            listening += 1;
        } else if (std.mem.indexOf(u8, trimmed, "ESTABLISHED") != null) {
            established += 1;
        } else if (std.mem.indexOf(u8, trimmed, "TIME_WAIT") != null) {
            time_wait += 1;
        }
    }
    
    try writer.print("Listening ports:      {d}\n", .{listening});
    try writer.print("Established conns:    {d}\n", .{established});
    try writer.print("Time-wait conns:      {d}\n", .{time_wait});
    try writer.writeAll("\nRecent connections:\n");
    try writer.writeAll("--------------------------------------------------\n");
    
    lines = std.mem.splitSequence(u8, output, "\n");
    var count: usize = 0;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\n\t");
        if (trimmed.len == 0) continue;
        if (std.mem.indexOf(u8, trimmed, "Proto") != null) continue;
        
        try writer.print("{s}\n", .{trimmed});
        count += 1;
        if (count >= 20) {
            try writer.writeAll("\n[Showing first 20 connections]\n");
            break;
        }
    }
    
    return try result.toOwnedSlice(allocator);
}

/// Network Configuration - ipconfig command
pub fn toolNetworkConfig(allocator: std.mem.Allocator, _: []const u8, cfg: *config.Config) ![]const u8 {
    const output = try execWindowsCommand(allocator, "ipconfig /all", cfg);
    defer allocator.free(output);
    
    var result = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    const writer = result.writer(allocator);
    
    try writer.writeAll("=== Network Configuration ===\n\n");
    try writer.print("{s}\n", .{output});
    
    return try result.toOwnedSlice(allocator);
}

/// FIX 5: Check Disk Space — uses dynamic JSON extraction instead of fixed buffers
pub fn toolCheckDiskSpace(allocator: std.mem.Allocator, arguments: []const u8, cfg: *config.Config) ![]const u8 {
    // FIX 5: Use shared JSON utility with dynamic allocation
    const drive = try json_utils.extractJsonString(allocator, arguments, "drive") orelse
        try allocator.dupe(u8, "C:");
    defer allocator.free(drive);
    
    const cmd = try std.fmt.allocPrint(allocator, "wmic logicaldisk where \"DeviceID='{s}'\" get Size,FreeSpace /format:list", .{drive});
    defer allocator.free(cmd);
    
    const output = try execWindowsCommand(allocator, cmd, cfg);
    defer allocator.free(output);
    
    var result = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    const writer = result.writer(allocator);
    
    try writer.print("=== Disk Space: {s} ===\n\n", .{drive});
    
    var free_space: u64 = 0;
    var total_size: u64 = 0;
    
    var lines = std.mem.splitSequence(u8, output, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\n\t");
        if (std.mem.startsWith(u8, trimmed, "FreeSpace=")) {
            const val = trimmed["FreeSpace=".len..];
            free_space = std.fmt.parseInt(u64, val, 10) catch 0;
        } else if (std.mem.startsWith(u8, trimmed, "Size=")) {
            const val = trimmed["Size=".len..];
            total_size = std.fmt.parseInt(u64, val, 10) catch 0;
        }
    }
    
    if (total_size > 0) {
        const free_mb = free_space / (1024 * 1024);
        const total_mb = total_size / (1024 * 1024);
        const used_mb = total_mb - free_mb;
        const pct_used = (used_mb * 100) / total_mb;
        
        try writer.print("Total:     {d} MB\n", .{total_mb});
        try writer.print("Used:      {d} MB ({d}%%)\n", .{ used_mb, pct_used });
        try writer.print("Free:      {d} MB\n", .{free_mb});
    } else {
        try writer.print("Raw output:\n{s}\n", .{output});
    }
    
    return try result.toOwnedSlice(allocator);
}

/// List Services - net start command
pub fn toolListServices(allocator: std.mem.Allocator, _: []const u8, cfg: *config.Config) ![]const u8 {
    const output = try execWindowsCommand(allocator, "net start", cfg);
    defer allocator.free(output);
    
    var result = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    const writer = result.writer(allocator);
    
    try writer.writeAll("=== Running Services ===\n\n");
    
    var lines = std.mem.splitSequence(u8, output, "\n");
    var count: usize = 0;
    
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\n\t");
        if (trimmed.len == 0) continue;
        
        if (std.mem.indexOf(u8, trimmed, "These Windows services") != null or
            std.mem.indexOf(u8, trimmed, "----------") != null or
            std.mem.indexOf(u8, trimmed, "The command completed") != null)
        {
            continue;
        }
        
        try writer.print("  - {s}\n", .{trimmed});
        count += 1;
    }
    
    try writer.print("\nTotal running services: {d}\n", .{count});
    
    return try result.toOwnedSlice(allocator);
}

/// FIX 5: Ping Host — uses dynamic JSON extraction instead of fixed buffers
pub fn toolPingHost(allocator: std.mem.Allocator, arguments: []const u8, cfg: *config.Config) ![]const u8 {
    const host = try json_utils.extractJsonString(allocator, arguments, "host") orelse
        try allocator.dupe(u8, "127.0.0.1");
    defer allocator.free(host);

    const count_val = try json_utils.extractJsonInt(allocator, arguments, "count");
    const count: u32 = if (count_val) |c|
        @intCast(@min(10, @max(1, c)))
    else
        4;
    
    const cmd = try std.fmt.allocPrint(allocator, "ping -n {d} {s}", .{ count, host });
    defer allocator.free(cmd);
    
    const output = try execWindowsCommand(allocator, cmd, cfg);
    defer allocator.free(output);
    
    var result = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    const writer = result.writer(allocator);
    
    try writer.print("=== Ping: {s} ===\n\n", .{host});
    try writer.print("{s}\n", .{output});
    
    return try result.toOwnedSlice(allocator);
}

/// FIX 5: Get Service Details — uses dynamic JSON extraction instead of fixed buffers
pub fn toolGetServiceDetails(allocator: std.mem.Allocator, arguments: []const u8, cfg: *config.Config) ![]const u8 {
    const service_name = try json_utils.extractJsonString(allocator, arguments, "service_name") orelse
        return try allocator.dupe(u8, "Error: service_name parameter required");
    defer allocator.free(service_name);
    
    const cmd = try std.fmt.allocPrint(allocator, "sc query \"{s}\"", .{service_name});
    defer allocator.free(cmd);
    
    const output = try execWindowsCommand(allocator, cmd, cfg);
    defer allocator.free(output);
    
    var result = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    const writer = result.writer(allocator);
    
    try writer.print("=== Service: {s} ===\n\n", .{service_name});
    try writer.print("{s}\n", .{output});
    
    return try result.toOwnedSlice(allocator);
}

/// Check Memory Usage - wmic for locale-independent output
pub fn toolCheckMemoryUsage(allocator: std.mem.Allocator, _: []const u8, cfg: *config.Config) ![]const u8 {
    const output = try execWindowsCommand(allocator, "wmic OS get TotalVisibleMemorySize,FreePhysicalMemory /format:list", cfg);
    defer allocator.free(output);
    
    var result = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    const writer = result.writer(allocator);
    
    try writer.writeAll("=== Memory Usage ===\n\n");
    
    var free_kb: u64 = 0;
    var total_kb: u64 = 0;
    
    var lines = std.mem.splitSequence(u8, output, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\n\t");
        if (std.mem.startsWith(u8, trimmed, "FreePhysicalMemory=")) {
            const val = trimmed["FreePhysicalMemory=".len..];
            free_kb = std.fmt.parseInt(u64, val, 10) catch 0;
        } else if (std.mem.startsWith(u8, trimmed, "TotalVisibleMemorySize=")) {
            const val = trimmed["TotalVisibleMemorySize=".len..];
            total_kb = std.fmt.parseInt(u64, val, 10) catch 0;
        }
    }
    
    if (total_kb > 0) {
        const free_mb = free_kb / 1024;
        const total_mb = total_kb / 1024;
        const used_mb = total_mb - free_mb;
        const pct_used = (used_mb * 100) / total_mb;
        
        try writer.print("Total RAM:     {d} MB\n", .{total_mb});
        try writer.print("Used:          {d} MB ({d}%%)\n", .{ used_mb, pct_used });
        try writer.print("Available:     {d} MB\n", .{free_mb});
    } else {
        try writer.print("Raw output:\n{s}\n", .{output});
    }
    
    return try result.toOwnedSlice(allocator);
}

// ─────────────────────────────────────────────
// FIX 8: Diagnose High CPU — now actually parses CPU Time and sorts
// ─────────────────────────────────────────────

const ProcessInfo = struct {
    name: []const u8,
    pid: []const u8,
    mem: []const u8,
    cpu_seconds: u64,
};

/// Parse CPU Time string "H:MM:SS" into total seconds
fn parseCpuTime(s: []const u8) u64 {
    // Format: "H:MM:SS" or "HH:MM:SS"
    var parts = std.mem.splitSequence(u8, s, ":");
    const hours_str = parts.next() orelse return 0;
    const mins_str = parts.next() orelse return 0;
    const secs_str = parts.next() orelse return 0;

    const hours = std.fmt.parseInt(u64, std.mem.trim(u8, hours_str, " "), 10) catch return 0;
    const mins = std.fmt.parseInt(u64, std.mem.trim(u8, mins_str, " "), 10) catch return 0;
    const secs = std.fmt.parseInt(u64, std.mem.trim(u8, secs_str, " "), 10) catch return 0;

    return hours * 3600 + mins * 60 + secs;
}

pub fn toolDiagnoseHighCPU(allocator: std.mem.Allocator, _: []const u8, cfg: *config.Config) ![]const u8 {
    var result_buf = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    const writer = result_buf.writer(allocator);

    try writer.writeAll("=== CPU Usage Analysis ===\n\n");

    // FIX 8: Get current CPU load via wmic
    const cpu_output = execWindowsCommand(allocator, "wmic cpu get LoadPercentage /format:list", cfg) catch {
        try writer.writeAll("(Could not query CPU load)\n\n");
        return try result_buf.toOwnedSlice(allocator);
    };
    defer allocator.free(cpu_output);

    var cpu_lines = std.mem.splitSequence(u8, cpu_output, "\n");
    while (cpu_lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\n\t");
        if (std.mem.startsWith(u8, trimmed, "LoadPercentage=")) {
            const val = trimmed["LoadPercentage=".len..];
            try writer.print("Current CPU Load: {s}%%\n\n", .{val});
        }
    }

    // Get tasklist with verbose CSV output
    const output = try execWindowsCommand(allocator, "tasklist /v /fo csv", cfg);
    defer allocator.free(output);

    // FIX 8: Parse processes and collect CPU time
    var processes: [200]ProcessInfo = undefined;
    var proc_count: usize = 0;

    var lines = std.mem.splitSequence(u8, output, "\n");
    _ = lines.next(); // Skip CSV header

    while (lines.next()) |line| {
        if (proc_count >= 200) break;

        const trimmed = std.mem.trim(u8, line, " \r\n\t\"");
        if (trimmed.len == 0) continue;

        // CSV fields: "Image Name","PID","Session Name","Session#","Mem Usage","Status","User Name","CPU Time","Window Title"
        var fields = std.mem.splitSequence(u8, trimmed, "\",\"");
        const name = std.mem.trim(u8, fields.next() orelse continue, "\"");
        const pid = std.mem.trim(u8, fields.next() orelse continue, "\"");
        _ = fields.next(); // session name
        _ = fields.next(); // session number
        const mem = std.mem.trim(u8, fields.next() orelse continue, "\"");
        _ = fields.next(); // status
        _ = fields.next(); // user name
        const cpu_time_str = std.mem.trim(u8, fields.next() orelse continue, "\"");

        const cpu_secs = parseCpuTime(cpu_time_str);

        processes[proc_count] = .{
            .name = name,
            .pid = pid,
            .mem = mem,
            .cpu_seconds = cpu_secs,
        };
        proc_count += 1;
    }

    // FIX 8: Insertion sort by cpu_seconds descending
    if (proc_count > 1) {
        var i: usize = 1;
        while (i < proc_count) : (i += 1) {
            const key = processes[i];
            var j: usize = i;
            while (j > 0 and processes[j - 1].cpu_seconds < key.cpu_seconds) {
                processes[j] = processes[j - 1];
                j -= 1;
            }
            processes[j] = key;
        }
    }

    // Show top 15
    try writer.writeAll("Top processes by CPU time:\n");
    try writer.writeAll("PID    | CPU Time   | Memory    | Name\n");
    try writer.writeAll("-------|------------|-----------|----------------------------------\n");

    const show_count = @min(proc_count, 15);
    for (processes[0..show_count]) |proc| {
        const hours = proc.cpu_seconds / 3600;
        const mins = (proc.cpu_seconds % 3600) / 60;
        const secs = proc.cpu_seconds % 60;
        try writer.print("{s:6} | {d:2}:{d:0>2}:{d:0>2}   | {s:9} | {s}\n", .{
            proc.pid, hours, mins, secs, proc.mem, proc.name,
        });
    }

    try writer.print("\nTotal processes analyzed: {d}\n", .{proc_count});
    try writer.writeAll("\nRecommendations:\n");
    try writer.writeAll("- Processes at the top consume the most CPU time\n");
    try writer.writeAll("- Consider stopping unnecessary services or processes\n");

    return try result_buf.toOwnedSlice(allocator);
}

/// FIX 11: Test Echo — fixed use-after-free by using extractJsonString (which dupes before freeing parsed)
pub fn toolTestEcho(allocator: std.mem.Allocator, arguments: []const u8, cfg: *config.Config) ![]const u8 {
    _ = cfg;
    const message = try json_utils.extractJsonString(allocator, arguments, "message") orelse
        return try allocator.dupe(u8, "ECHO: Hello from test_echo!");
    defer allocator.free(message);
    return try std.fmt.allocPrint(allocator, "ECHO: {s}", .{message});
}
