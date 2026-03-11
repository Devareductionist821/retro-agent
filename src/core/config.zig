const std = @import("std");

pub const AgentMode = enum {
    api,
    bridge,
    offline,
    interactive,
    local,
};

pub const Config = struct {
    allocator: std.mem.Allocator,

    // Agent
    agent_name: []const u8 = "micro-agent",
    mode: AgentMode = .interactive,
    system_prompt: []const u8 = 
        \\You are a specialized AI assistant for Windows XP system administrators and technicians.
        \\
        \\SYSTEM CONTEXT:
        \\- OS: Windows XP SP3 (32-bit)
        \\- Shell: cmd.exe (NO PowerShell available)
        \\- Hardware: Legacy (Pentium III-IV, 64-512 MB RAM, slow HDD)
        \\- Encoding: Windows-1252 / CP850
        \\
        \\YOUR CAPABILITIES:
        \\You have access to diagnostic and maintenance tools for Windows XP systems:
        \\- System diagnostics (systeminfo, memory, disk space)
        \\- Process management (list, analyze CPU/memory usage)
        \\- Network diagnostics (connections, configuration, ping)
        \\- Service management (list, query status)
        \\- File operations (read logs, list directories)
        \\
        \\BEHAVIOR GUIDELINES:
        \\1. Be proactive: Suggest relevant diagnostic actions
        \\2. Be precise: Use technical terminology correctly
        \\3. Be efficient: Minimize commands on slow hardware
        \\4. Be clear: Explain what you're doing and why
        \\5. Be helpful: Provide actionable recommendations
        \\
        \\DIAGNOSTIC WORKFLOW:
        \\1. Gather information using read-only tools
        \\2. Analyze data and identify issues
        \\3. Propose solutions with clear rationale
        \\4. Execute fixes (with user approval if needed)
        \\5. Verify resolution
        \\
        \\HARDWARE LIMITATIONS:
        \\- Avoid full disk scans (too slow on legacy hardware)
        \\- Limit output to essential information
        \\- Consider limited RAM (no memory-intensive operations)
        \\- Be patient with command execution times
        \\
        \\OUTPUT FORMAT:
        \\- Present information in clear, organized sections
        \\- Use bullet points for lists
        \\- Highlight critical issues
        \\- Provide specific recommendations
        \\- Include relevant metrics (MB, %, counts)
        \\
        \\EXAMPLE INTERACTIONS:
        \\
        \\User: "System is running slow"
        \\You: Let me check system resources and running processes.
        \\[Use: system_info, check_memory_usage, diagnose_high_cpu]
        \\Analysis: Found high memory usage (450/512 MB used). Process "app.exe" using 180 MB.
        \\Recommendation: Consider closing unnecessary applications or restarting the high-memory process.
        \\
        \\User: "Can't connect to network"
        \\You: I'll check network configuration and connectivity.
        \\[Use: network_config, network_status, ping_host]
        \\Analysis: Network adapter configured correctly. Gateway not responding.
        \\Recommendation: Check physical connection or restart network adapter.
        \\
        \\Remember: You're assisting professionals managing critical legacy systems. Be thorough, accurate, and helpful.
    ,

    // Transport: API
    transport_api_provider: []const u8 = "openai",
    transport_api_key: []const u8 = "",
    transport_api_model: []const u8 = "",
    transport_api_base_url: []const u8 = "http://localhost:11434",

    // Transport: Serial
    transport_serial_port: []const u8 = "/dev/ttyUSB0",
    transport_serial_baud: u32 = 115200,

    // Transport: File queue
    transport_file_inbox: []const u8 = "/var/spool/micro-agent/inbox",
    transport_file_outbox: []const u8 = "/var/spool/micro-agent/outbox",
    transport_file_poll_ms: u32 = 5000,

    // Monitor
    monitor_enabled: bool = false,

    // Security
    security_require_approval: bool = false,
    security_sandbox: bool = true,
    security_max_exec_timeout_ms: u32 = 30000,
    
    // Debug
    debug_mode: bool = false,

    // FIX 6: History sliding window — max messages to keep in conversation history
    max_history_messages: u32 = 100,

    // Tools
    tool_exec_enabled: bool = true,
    tool_file_read_enabled: bool = true,
    tool_file_write_enabled: bool = true,
    tool_list_dir_enabled: bool = true,
    tool_alert_enabled: bool = true,

    // Allowed commands for exec tool (whitelist)
    tool_exec_allowed_commands: ?[]const []const u8 = null,
    // Allowed paths for file operations
    tool_file_read_allowed_paths: ?[]const []const u8 = null,
    tool_file_write_allowed_paths: ?[]const []const u8 = null,

    // Allocated strings that we own (need to free)
    _owned_json: ?[]const u8 = null,
    // Strings duplicated from JSON parsing (must be freed individually)
    _owned_strings: std.ArrayList([]const u8) = undefined,
    _strings_initialized: bool = false,

    pub fn defaults(allocator: std.mem.Allocator) Config {
        return Config{
            .allocator = allocator,
            ._owned_strings = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable,
            ._strings_initialized = true,
        };
    }

    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Config {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            std.log.err("Cannot open config file '{s}': {}", .{ path, err });
            return err;
        };
        defer file.close();

        const stat = try file.stat();
        if (stat.size > 1024 * 1024) { // 1 MB max config
            return error.ConfigTooLarge;
        }

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);

        var cfg = Config{
            .allocator = allocator,
            ._owned_json = content,
            ._owned_strings = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable,
            ._strings_initialized = true,
        };

        // Parse JSON config
        cfg.parseJson(content) catch |err| {
            std.log.err("Invalid config JSON: {}", .{err});
            return err;
        };

        return cfg;
    }

    /// Duplicate a string and track it for cleanup
    pub fn dupeAndOwn(self: *Config, s: []const u8) ![]const u8 {
        const owned = try self.allocator.dupe(u8, s);
        try self._owned_strings.append(self.allocator, owned);
        return owned;
    }

    fn parseJson(self: *Config, content: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return;

        // Agent section
        if (root.object.get("agent")) |agent_val| {
            if (agent_val == .object) {
                if (agent_val.object.get("name")) |v| {
                    if (v == .string) self.agent_name = try self.dupeAndOwn(v.string);
                }
                if (agent_val.object.get("system_prompt")) |v| {
                    if (v == .string) self.system_prompt = try self.dupeAndOwn(v.string);
                }
                if (agent_val.object.get("mode")) |v| {
                    if (v == .string) {
                        self.mode = modeFromString(v.string);
                    }
                }
                // FIX 6: Parse max_history from agent section
                if (agent_val.object.get("max_history")) |v| {
                    if (v == .integer) {
                        const val_int: i64 = v.integer;
                        if (val_int > 0 and val_int <= 10000) {
                            self.max_history_messages = @intCast(@as(u64, @bitCast(val_int)));
                        }
                    }
                }
            }
        }

        // Transport section
        if (root.object.get("transport")) |transport_val| {
            if (transport_val == .object) {
                // API config
                if (transport_val.object.get("api")) |api_val| {
                    if (api_val == .object) {
                        if (api_val.object.get("provider")) |v| {
                            if (v == .string) self.transport_api_provider = try self.dupeAndOwn(v.string);
                        }
                        if (api_val.object.get("api_key")) |v| {
                            if (v == .string) self.transport_api_key = try self.dupeAndOwn(v.string);
                        }
                        if (api_val.object.get("model")) |v| {
                            if (v == .string) self.transport_api_model = try self.dupeAndOwn(v.string);
                        }
                        if (api_val.object.get("base_url")) |v| {
                            if (v == .string) self.transport_api_base_url = try self.dupeAndOwn(v.string);
                        }
                    }
                }

                // Serial config
                if (transport_val.object.get("serial")) |serial_val| {
                    if (serial_val == .object) {
                        if (serial_val.object.get("port")) |v| {
                            if (v == .string) self.transport_serial_port = try self.dupeAndOwn(v.string);
                        }
                        if (serial_val.object.get("baud_rate")) |v| {
                            if (v == .integer) self.transport_serial_baud = @intCast(@as(u32, @truncate(@as(u64, @bitCast(v.integer)))));
                        }
                    }
                }

                // File queue config
                if (transport_val.object.get("file_queue")) |fq_val| {
                    if (fq_val == .object) {
                        if (fq_val.object.get("inbox")) |v| {
                            if (v == .string) self.transport_file_inbox = try self.dupeAndOwn(v.string);
                        }
                        if (fq_val.object.get("outbox")) |v| {
                            if (v == .string) self.transport_file_outbox = try self.dupeAndOwn(v.string);
                        }
                    }
                }
            }
        }

        // Security section
        if (root.object.get("security")) |sec_val| {
            if (sec_val == .object) {
                if (sec_val.object.get("require_approval")) |v| {
                    if (v == .bool) self.security_require_approval = v.bool;
                }
                if (sec_val.object.get("sandbox")) |v| {
                    if (v == .bool) self.security_sandbox = v.bool;
                }
                // FIX 3: Parse max_exec_timeout_ms from security section
                if (sec_val.object.get("max_exec_timeout_ms")) |v| {
                    if (v == .integer) {
                        const val_int: i64 = v.integer;
                        if (val_int > 0) {
                            self.security_max_exec_timeout_ms = @intCast(@as(u64, @bitCast(val_int)));
                        }
                    }
                }
            }
        }
    }

    fn modeFromString(s: []const u8) AgentMode {
        if (std.mem.eql(u8, s, "api")) return .api;
        if (std.mem.eql(u8, s, "bridge")) return .bridge;
        if (std.mem.eql(u8, s, "offline")) return .offline;
        if (std.mem.eql(u8, s, "local")) return .local;
        return .interactive;
    }

    pub fn deinit(self: *Config) void {
        // Free all owned duplicated strings
        if (self._strings_initialized) {
            for (self._owned_strings.items) |s| {
                self.allocator.free(s);
            }
            self._owned_strings.deinit(self.allocator);
        }
        if (self._owned_json) |json| {
            self.allocator.free(json);
        }
    }
};

test "config defaults" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var cfg = Config.defaults(gpa.allocator());
    defer cfg.deinit();
    try std.testing.expectEqual(cfg.mode, .interactive);
    try std.testing.expectEqualStrings(cfg.agent_name, "micro-agent");
}
