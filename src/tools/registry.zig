const std = @import("std");
const config = @import("../core/config.zig");
const transport = @import("../transport/transport.zig");
const builtin = @import("builtin");
const windows_xp = @import("windows_xp.zig");
// FIX 5: Import shared JSON utilities
const json_utils = @import("../utils/json.zig");

/// Function pointer type for tool execution
const ToolFn = *const fn (allocator: std.mem.Allocator, arguments: []const u8, cfg: *config.Config) anyerror![]const u8;

/// Registered tool entry
const ToolEntry = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
    execute: ToolFn,
    enabled: bool,
};

pub const ToolRegistry = struct {
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    tools: std.ArrayList(ToolEntry),
    _cached_defs: ?[]transport.ToolDef = null,
    _cache_dirty: bool = true,

    pub fn init(allocator: std.mem.Allocator, cfg: *config.Config) ToolRegistry {
        return .{
            .allocator = allocator,
            .cfg = cfg,
            .tools = std.ArrayList(ToolEntry).initCapacity(allocator, 0) catch unreachable,
        };
    }

    pub fn deinit(self: *ToolRegistry) void {
        if (self._cached_defs) |defs| {
            self.allocator.free(defs);
        }
        self.tools.deinit(self.allocator);
    }

    /// Register all built-in tools based on config
    pub fn registerBuiltins(self: *ToolRegistry) !void {
        self._cache_dirty = true;

        // FIX 2: Windows XP tools registered only on Windows; generic system_info only on non-Windows
        if (builtin.os.tag == .windows) {
            // ── Windows XP Specific Tools ──
            try self.tools.append(self.allocator, .{
                .name = "system_info",
                .description = "Get detailed Windows XP system information: OS version, RAM, CPU, uptime, patches. Essential for diagnostics.",
                .parameters_json =
                \\{"type":"object","properties":{}}
                ,
                .execute = &windows_xp.toolSystemInfo,
                .enabled = true,
            });

            try self.tools.append(self.allocator, .{
                .name = "list_processes",
                .description = "List all running processes with PID, memory usage, and name. Use to identify resource-heavy processes.",
                .parameters_json =
                \\{"type":"object","properties":{}}
                ,
                .execute = &windows_xp.toolListProcesses,
                .enabled = true,
            });

            try self.tools.append(self.allocator, .{
                .name = "network_status",
                .description = "Show active network connections, listening ports, and connection states. Use for network diagnostics.",
                .parameters_json =
                \\{"type":"object","properties":{}}
                ,
                .execute = &windows_xp.toolNetworkStatus,
                .enabled = true,
            });

            try self.tools.append(self.allocator, .{
                .name = "network_config",
                .description = "Show network adapter configuration: IP address, subnet mask, gateway, DNS servers, MAC address.",
                .parameters_json =
                \\{"type":"object","properties":{}}
                ,
                .execute = &windows_xp.toolNetworkConfig,
                .enabled = true,
            });

            try self.tools.append(self.allocator, .{
                .name = "check_disk_space",
                .description = "Check available disk space on a specific drive. Essential for monitoring storage.",
                .parameters_json =
                \\{"type":"object","properties":{"drive":{"type":"string","description":"Drive letter (e.g., C:, D:)","default":"C:"}},"required":[]}
                ,
                .execute = &windows_xp.toolCheckDiskSpace,
                .enabled = true,
            });

            try self.tools.append(self.allocator, .{
                .name = "list_services",
                .description = "List all currently running Windows services. Use to check service status.",
                .parameters_json =
                \\{"type":"object","properties":{}}
                ,
                .execute = &windows_xp.toolListServices,
                .enabled = true,
            });

            try self.tools.append(self.allocator, .{
                .name = "ping_host",
                .description = "Ping a host to test network connectivity and measure latency. Use for network troubleshooting.",
                .parameters_json =
                \\{"type":"object","properties":{"host":{"type":"string","description":"Hostname or IP address to ping"},"count":{"type":"integer","description":"Number of ping requests (1-10, default 4)"}},"required":["host"]}
                ,
                .execute = &windows_xp.toolPingHost,
                .enabled = true,
            });

            try self.tools.append(self.allocator, .{
                .name = "get_service_details",
                .description = "Get detailed information about a specific Windows service: state, status, dependencies.",
                .parameters_json =
                \\{"type":"object","properties":{"service_name":{"type":"string","description":"Name of the service to query"}},"required":["service_name"]}
                ,
                .execute = &windows_xp.toolGetServiceDetails,
                .enabled = true,
            });

            try self.tools.append(self.allocator, .{
                .name = "check_memory_usage",
                .description = "Check total and available physical memory (RAM). Critical for performance diagnostics.",
                .parameters_json =
                \\{"type":"object","properties":{}}
                ,
                .execute = &windows_xp.toolCheckMemoryUsage,
                .enabled = true,
            });

            try self.tools.append(self.allocator, .{
                .name = "diagnose_high_cpu",
                .description = "Analyze processes by CPU usage and provide recommendations. Use when system is slow.",
                .parameters_json =
                \\{"type":"object","properties":{}}
                ,
                .execute = &windows_xp.toolDiagnoseHighCPU,
                .enabled = true,
            });

            try self.tools.append(self.allocator, .{
                .name = "test_echo",
                .description = "Simple test tool that echoes back a message. Use to verify tool execution works.",
                .parameters_json =
                \\{"type":"object","properties":{"message":{"type":"string","description":"Message to echo back"}},"required":["message"]}
                ,
                .execute = &windows_xp.toolTestEcho,
                .enabled = true,
            });
        } else {
            // FIX 2: Generic system_info only on non-Windows platforms
            try self.tools.append(self.allocator, .{
                .name = "system_info",
                .description = "Get basic system information: OS, architecture, memory, disk space.",
                .parameters_json =
                \\{"type":"object","properties":{}}
                ,
                .execute = &toolSystemInfo,
                .enabled = true,
            });
        }

        // ── exec: run a shell command ──
        if (self.cfg.tool_exec_enabled) {
            try self.tools.append(self.allocator, .{
                .name = "exec",
                .description = "Execute a shell command on the local system. Use for system administration, diagnostics, and automation.",
                .parameters_json =
                \\{"type":"object","properties":{"command":{"type":"string","description":"The shell command to execute"}},"required":["command"]}
                ,
                .execute = &toolExec,
                .enabled = true,
            });
        }

        // ── file_read: read a file ──
        if (self.cfg.tool_file_read_enabled) {
            try self.tools.append(self.allocator, .{
                .name = "file_read",
                .description = "Read the contents of a file. Use for log analysis, config inspection, data extraction.",
                .parameters_json =
                \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file to read"},"max_lines":{"type":"integer","description":"Maximum number of lines to read (default: 100)"}},"required":["path"]}
                ,
                .execute = &toolFileRead,
                .enabled = true,
            });
        }

        // ── file_write: write a file ──
        if (self.cfg.tool_file_write_enabled) {
            try self.tools.append(self.allocator, .{
                .name = "file_write",
                .description = "Write content to a file. Use for generating reports, configs, logs.",
                .parameters_json =
                \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file to write"},"content":{"type":"string","description":"Content to write"}},"required":["path","content"]}
                ,
                .execute = &toolFileWrite,
                .enabled = true,
            });
        }

        // ── alert: send an alert/notification ──
        if (self.cfg.tool_alert_enabled) {
            try self.tools.append(self.allocator, .{
                .name = "alert",
                .description = "Send an alert or notification. Output goes to stdout or a file.",
                .parameters_json =
                \\{"type":"object","properties":{"level":{"type":"string","enum":["info","warning","critical"],"description":"Alert severity level"},"message":{"type":"string","description":"Alert message"}},"required":["level","message"]}
                ,
                .execute = &toolAlert,
                .enabled = true,
            });
        }

        // ── list_dir: list directory contents ──
        if (self.cfg.tool_list_dir_enabled) {
            try self.tools.append(self.allocator, .{
                .name = "list_dir",
                .description = "List files and directories in a given path. Use to explore the filesystem.",
                .parameters_json =
                \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the directory to list"}},"required":["path"]}
                ,
                .execute = &toolListDir,
                .enabled = true,
            });
        }
    }

    /// Register a custom tool
    pub fn register(self: *ToolRegistry, entry: ToolEntry) !void {
        self._cache_dirty = true;
        try self.tools.append(self.allocator, entry);
    }

    /// Get tool definitions for the API (function calling schema)
    pub fn getToolDefs(self: *ToolRegistry) ?[]const transport.ToolDef {
        if (self.tools.items.len == 0) return null;

        if (!self._cache_dirty) {
            return self._cached_defs;
        }

        if (self._cached_defs) |old| {
            self.allocator.free(old);
        }

        var count: usize = 0;
        for (self.tools.items) |t| {
            if (t.enabled) count += 1;
        }
        if (count == 0) return null;

        var defs = self.allocator.alloc(transport.ToolDef, count) catch return null;
        var idx: usize = 0;
        for (self.tools.items) |t| {
            if (t.enabled) {
                defs[idx] = .{
                    .name = t.name,
                    .description = t.description,
                    .parameters_json = t.parameters_json,
                };
                idx += 1;
            }
        }
        self._cached_defs = defs;
        self._cache_dirty = false;
        return defs;
    }

    /// Execute a tool by name
    pub fn execute(self: *ToolRegistry, name: []const u8, arguments: []const u8) ![]const u8 {
        for (self.tools.items) |tool| {
            if (tool.enabled and std.mem.eql(u8, tool.name, name)) {
                return try tool.execute(self.allocator, arguments, self.cfg);
            }
        }
        return try std.fmt.allocPrint(self.allocator, "Error: unknown tool '{s}'.", .{name});
    }
};

// ─────────────────────────────────────────────
// Built-in tool implementations
// ─────────────────────────────────────────────

// FIX 3: Shared timeout helper for child processes
// Returns stdout, stderr, whether it timed out, and the exit code
pub fn waitWithTimeout(allocator: std.mem.Allocator, child: *std.process.Child, timeout_ms: u32) !struct { stdout: []const u8, stderr: []const u8, timed_out: bool, exit_code: u32 } {
    // Read stdout/stderr first (before waiting, to avoid deadlock on full pipe)
    const stdout_data = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    const stderr_data = try child.stderr.?.readToEndAlloc(allocator, 64 * 1024);

    if (builtin.os.tag == .windows) {
        // Windows: use WaitForSingleObject with timeout
        const HANDLE = std.os.windows.HANDLE;
        const DWORD = std.os.windows.DWORD;
        const kernel32_ext = struct {
            extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
            extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: u32) callconv(.winapi) i32;
        };
        const WAIT_TIMEOUT: DWORD = 0x00000102;

        const handle = child.id;
        const wait_result = kernel32_ext.WaitForSingleObject(handle, @as(DWORD, timeout_ms));

        if (wait_result == WAIT_TIMEOUT) {
            _ = kernel32_ext.TerminateProcess(handle, 1);
            _ = child.wait() catch {};
            return .{ .stdout = stdout_data, .stderr = stderr_data, .timed_out = true, .exit_code = 1 };
        }

        const term = try child.wait();
        const code: u32 = switch (term) {
            .Exited => |c| c,
            else => 1,
        };
        return .{ .stdout = stdout_data, .stderr = stderr_data, .timed_out = false, .exit_code = code };
    } else {
        // Non-Windows: pipes already drained above, wait with timeout
        // Zig 0.15.2: nanoTimestamp returns i128
        const start_ns: i128 = std.time.nanoTimestamp();
        const timeout_ns: i128 = @as(i128, timeout_ms) * std.time.ns_per_ms;

        // After pipes are drained, the process should finish soon.
        // Simple polling loop with timeout check.
        while (true) {
            const elapsed: i128 = std.time.nanoTimestamp() - start_ns;
            if (elapsed >= timeout_ns) {
                // Timeout: kill the process
                const pid = child.id;
                _ = std.posix.kill(pid, std.posix.SIG.KILL) catch {};
                _ = child.wait() catch {};
                return .{ .stdout = stdout_data, .stderr = stderr_data, .timed_out = true, .exit_code = 1 };
            }

            // Try to reap the child (non-blocking would be ideal, but since pipes are drained,
            // the process should exit quickly). Use child.wait() which is blocking but safe here.
            const term = child.wait() catch {
                return .{ .stdout = stdout_data, .stderr = stderr_data, .timed_out = false, .exit_code = 1 };
            };
            const code: u32 = switch (term) {
                .Exited => |c| c,
                else => 1,
            };
            return .{ .stdout = stdout_data, .stderr = stderr_data, .timed_out = false, .exit_code = code };
        }
    }
}

fn toolExec(allocator: std.mem.Allocator, arguments: []const u8, cfg: *config.Config) ![]const u8 {
    // FIX 5: Use shared JSON utility
    const command = try json_utils.extractJsonString(allocator, arguments, "command") orelse
        return try allocator.dupe(u8, "Error: missing 'command' argument.");
    defer allocator.free(command);

    // Security: validate against allowed_commands whitelist
    if (cfg.tool_exec_allowed_commands) |allowed| {
        var is_allowed = false;
        for (allowed) |pattern| {
            if (commandMatchesPattern(command, pattern)) {
                is_allowed = true;
                break;
            }
        }
        if (!is_allowed) {
            return try std.fmt.allocPrint(allocator, "Error: command '{s}' not in allowed_commands whitelist.", .{command});
        }
    }

    // Execute via child process
    const shell = if (builtin.os.tag == .windows)
        &[_][]const u8{ "cmd.exe", "/C", command }
    else
        &[_][]const u8{ "/bin/sh", "-c", command };

    var child = std.process.Child.init(shell, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // FIX 3: Use timeout from config
    const timeout_ms = cfg.security_max_exec_timeout_ms;
    const result = try waitWithTimeout(allocator, &child, timeout_ms);
    const stdout = result.stdout;
    const stderr = result.stderr;
    defer allocator.free(stderr);

    if (result.timed_out) {
        defer allocator.free(stdout);
        return try std.fmt.allocPrint(allocator, "Error: command timed out after {d}ms", .{timeout_ms});
    }

    // Use exit code from waitWithTimeout (process already waited)
    if (result.exit_code != 0) {
        defer allocator.free(stdout);
        return try std.fmt.allocPrint(allocator, "Exit code: {d}\nStderr: {s}\nStdout: {s}", .{ result.exit_code, stderr, stdout });
    }

    return stdout;
}

/// Check if a command matches an allowed pattern
fn commandMatchesPattern(command: []const u8, pattern: []const u8) bool {
    if (std.mem.endsWith(u8, pattern, "*")) {
        const prefix = pattern[0 .. pattern.len - 1];
        return std.mem.startsWith(u8, command, prefix);
    }
    return std.mem.eql(u8, command, pattern);
}

fn toolFileRead(allocator: std.mem.Allocator, arguments: []const u8, cfg: *config.Config) ![]const u8 {
    // FIX 5: Use shared JSON utility
    const path = try json_utils.extractJsonString(allocator, arguments, "path") orelse
        return try allocator.dupe(u8, "Error: missing 'path' argument.");
    defer allocator.free(path);

    if (cfg.tool_file_read_allowed_paths) |allowed| {
        var is_allowed = false;
        for (allowed) |allowed_prefix| {
            if (std.mem.startsWith(u8, path, allowed_prefix)) {
                is_allowed = true;
                break;
            }
        }
        if (!is_allowed) {
            return try std.fmt.allocPrint(allocator, "Error: path '{s}' not in allowed_paths whitelist.", .{path});
        }
    }

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return std.fmt.allocPrint(allocator, "Error opening file: {}", .{err}) catch "Error opening file.";
    };
    defer file.close();

    return try file.readToEndAlloc(allocator, 64 * 1024);
}

fn toolFileWrite(allocator: std.mem.Allocator, arguments: []const u8, cfg: *config.Config) ![]const u8 {
    // FIX 5: Use shared JSON utility
    const path = try json_utils.extractJsonString(allocator, arguments, "path") orelse
        return try allocator.dupe(u8, "Error: missing 'path' argument.");
    defer allocator.free(path);
    
    const content = try json_utils.extractJsonString(allocator, arguments, "content") orelse
        return try allocator.dupe(u8, "Error: missing 'content' argument.");
    defer allocator.free(content);

    if (cfg.tool_file_write_allowed_paths) |allowed| {
        var is_allowed = false;
        for (allowed) |allowed_prefix| {
            if (std.mem.startsWith(u8, path, allowed_prefix)) {
                is_allowed = true;
                break;
            }
        }
        if (!is_allowed) {
            return try std.fmt.allocPrint(allocator, "Error: path '{s}' not in allowed_paths whitelist.", .{path});
        }
    }

    const file = std.fs.cwd().createFile(path, .{}) catch |err| {
        return std.fmt.allocPrint(allocator, "Error creating file: {}", .{err}) catch "Error creating file.";
    };
    defer file.close();

    file.writeAll(content) catch |err| {
        return std.fmt.allocPrint(allocator, "Error writing file: {}", .{err}) catch "Error writing file.";
    };

    return try std.fmt.allocPrint(allocator, "Written {d} bytes to {s}", .{ content.len, path });
}

fn toolAlert(allocator: std.mem.Allocator, arguments: []const u8, cfg: *config.Config) ![]const u8 {
    _ = cfg;
    // FIX 5: Use shared JSON utility
    const level_owned = try json_utils.extractJsonString(allocator, arguments, "level");
    defer if (level_owned) |l| allocator.free(l);
    const level = level_owned orelse "info";
    
    const message = try json_utils.extractJsonString(allocator, arguments, "message") orelse
        return try allocator.dupe(u8, "Error: missing 'message' argument.");
    defer allocator.free(message);

    const prefix = if (std.mem.eql(u8, level, "critical"))
        "CRITICAL"
    else if (std.mem.eql(u8, level, "warning"))
        "WARNING"
    else
        "INFO";

    std.debug.print("\n[{s}]: {s}\n", .{ prefix, message });

    return try std.fmt.allocPrint(allocator, "Alert sent: [{s}] {s}", .{ level, message });
}

fn toolListDir(allocator: std.mem.Allocator, arguments: []const u8, cfg: *config.Config) ![]const u8 {
    _ = cfg;
    // FIX 5: Use shared JSON utility
    const path = try json_utils.extractJsonString(allocator, arguments, "path") orelse
        return try allocator.dupe(u8, "Error: missing 'path' argument.");
    defer allocator.free(path);

    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        return try std.fmt.allocPrint(allocator, "Error opening directory '{s}': {}", .{ path, err });
    };
    defer dir.close();

    var buf = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    const writer = buf.writer(allocator);

    try writer.print("Contents of {s}:\n", .{path});

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const type_str = switch (entry.kind) {
            .directory => "DIR",
            .file => "FILE",
            else => "OTHER",
        };
        try writer.print("  [{s}] {s}\n", .{ type_str, entry.name });
    }

    return try buf.toOwnedSlice(allocator);
}

fn toolSystemInfo(allocator: std.mem.Allocator, _: []const u8, cfg: *config.Config) ![]const u8 {
    _ = cfg;
    var buf = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    const writer = buf.writer(allocator);

    try writer.writeAll("System Information:\n");

    if (builtin.os.tag == .windows) {
        try writer.writeAll("  OS: Windows\n");
        try writer.print("  Arch: {s}\n", .{@tagName(builtin.cpu.arch)});
    } else {
        if (std.posix.uname()) |uname| {
            try writer.print("  OS: {s}\n", .{std.mem.sliceTo(&uname.sysname, 0)});
            try writer.print("  Hostname: {s}\n", .{std.mem.sliceTo(&uname.nodename, 0)});
            try writer.print("  Kernel: {s}\n", .{std.mem.sliceTo(&uname.release, 0)});
            try writer.print("  Arch: {s}\n", .{std.mem.sliceTo(&uname.machine, 0)});
        } else |_| {
            try writer.writeAll("  OS: unknown\n");
        }
    }

    return try buf.toOwnedSlice(allocator);
}

test "tool registry init" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var cfg = config.Config.defaults(gpa.allocator());
    defer cfg.deinit();
    var reg = ToolRegistry.init(gpa.allocator(), &cfg);
    defer reg.deinit();
    try reg.registerBuiltins();
    try std.testing.expect(reg.tools.items.len >= 2);
}

test "command matches pattern" {
    try std.testing.expect(commandMatchesPattern("df -h", "df -h"));
    try std.testing.expect(commandMatchesPattern("systemctl status nginx", "systemctl status *"));
    try std.testing.expect(!commandMatchesPattern("rm -rf /", "df -h"));
}
