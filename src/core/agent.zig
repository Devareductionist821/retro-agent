const std = @import("std");
const config = @import("config.zig");
const transport = @import("../transport/transport.zig");
const tools = @import("../tools/registry.zig");

/// A single message in conversation history
pub const Message = struct {
    role: Role,
    content: []const u8,
    tool_id: ?[]const u8 = null, // Used for tool_call and tool_result
    tool_name: ?[]const u8 = null, // Name of the tool being called/reported

    pub const Role = enum { system, user, assistant, tool_call, tool_result };
};

/// Function call request from the model
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8, // JSON string
};

/// Result of processing a model response
pub const AgentResponse = struct {
    text: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    done: bool = true,
};

pub const Agent = struct {
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    history: std.ArrayList(Message),
    tool_registry: tools.ToolRegistry,
    running: bool = false,

    pub fn init(allocator: std.mem.Allocator, cfg: *config.Config) !Agent {
        var self = Agent{
            .allocator = allocator,
            .cfg = cfg,
            .history = std.ArrayList(Message).initCapacity(allocator, 0) catch unreachable,
            .tool_registry = tools.ToolRegistry.init(allocator, cfg),
        };

        // Register built-in tools
        try self.tool_registry.registerBuiltins();

        // Add system prompt
        const owned_system_prompt = try self.allocator.dupe(u8, cfg.system_prompt);
        try self.history.append(self.allocator, .{
            .role = .system,
            .content = owned_system_prompt,
        });

        return self;
    }

    pub fn deinit(self: *Agent) void {
        for (self.history.items) |msg| {
            self.allocator.free(msg.content);
            if (msg.tool_id) |id| self.allocator.free(id);
            if (msg.tool_name) |name| self.allocator.free(name);
        }
        self.history.deinit(self.allocator);
        self.tool_registry.deinit();
    }

    /// Process a single user message and return the agent's response.
    /// Handles tool call loops internally.
    pub fn processMessage(self: *Agent, user_input: []const u8) ![]const u8 {
        // Add user message to history (own the string)
        const owned_user_input = try self.allocator.dupe(u8, user_input);
        try self.history.append(self.allocator, .{
            .role = .user,
            .content = owned_user_input,
        });

        // Agent loop: send to model, handle tool calls, repeat
        var iterations: u32 = 0;
        const max_iterations: u32 = 10; // prevent infinite loops

        while (iterations < max_iterations) : (iterations += 1) {
            // Send conversation to model via transport
            const response = try self.callModel();

            // If model wants to call tools
            if (response.tool_calls) |tc| {
                for (tc) |call| {
                    // Save assistant message with tool call to history (OpenAI style)
                    // Note: Ideally we'd have a specific way to represent multiple tool calls in one msg,
                    // but for now we follow the existing pattern with tool_id per message.
                    const owned_args = try self.allocator.dupe(u8, call.arguments);
                    const owned_id = try self.allocator.dupe(u8, call.id);
                    const owned_name = try self.allocator.dupe(u8, call.name);
                    try self.history.append(self.allocator, .{
                        .role = .tool_call,
                        .content = owned_args,
                        .tool_id = owned_id,
                        .tool_name = owned_name,
                    });

                    // Execute tool
                    if (self.cfg.debug_mode) {
                        std.debug.print("\n[DEBUG] Executing tool: {s}\n", .{call.name});
                        std.debug.print("[DEBUG] Arguments: {s}\n", .{call.arguments});
                    }
                    
                    const result = try self.executeTool(call);
                    defer self.allocator.free(result);
                    
                    if (self.cfg.debug_mode) {
                        std.debug.print("[DEBUG] Tool result length: {d} bytes\n", .{result.len});
                        if (result.len < 500) {
                            std.debug.print("[DEBUG] Tool result: {s}\n", .{result});
                        } else {
                            std.debug.print("[DEBUG] Tool result (first 500 chars): {s}...\n", .{result[0..500]});
                        }
                    }

                    // Add result to history
                    const owned_result = try self.allocator.dupe(u8, result);
                    const owned_id_result = try self.allocator.dupe(u8, call.id);
                    const owned_name_result = try self.allocator.dupe(u8, call.name);
                    try self.history.append(self.allocator, .{
                        .role = .tool_result,
                        .content = owned_result,
                        .tool_id = owned_id_result,
                        .tool_name = owned_name_result,
                    });
                }
                
                // Free the tool calls received from the model
                for (tc) |call| {
                    self.allocator.free(call.id);
                    self.allocator.free(call.name);
                    self.allocator.free(call.arguments);
                }
                self.allocator.free(tc);

                // Continue loop — model needs to see tool results
                continue;
            }

            // No tool calls — we have a final text response
            if (response.text) |text| {
                // history takes ownership of the response text (already duplicated by transport)
                try self.history.append(self.allocator, .{
                    .role = .assistant,
                    .content = text,
                });
                // FIX 6: Trim history to prevent unbounded memory growth
                self.trimHistory();
                return text;
            }

            break;
        }

        return try self.allocator.dupe(u8, "Error: agent loop exceeded maximum iterations.");
    }

    // FIX 6: Sliding window — trim history to max_history_messages, keeping system prompt at index 0
    fn trimHistory(self: *Agent) void {
        const max = self.cfg.max_history_messages;
        if (self.history.items.len <= max) return;

        // Keep index 0 (system prompt), remove oldest messages after it
        const to_remove = self.history.items.len - max;
        
        // Free memory for messages being removed (indices 1..1+to_remove)
        for (self.history.items[1 .. 1 + to_remove]) |msg| {
            self.allocator.free(msg.content);
            if (msg.tool_id) |id| self.allocator.free(id);
            if (msg.tool_name) |name| self.allocator.free(name);
        }

        // Shift remaining messages down
        const remaining = self.history.items[1 + to_remove ..];
        std.mem.copyForwards(Message, self.history.items[1..], remaining);
        self.history.items.len = max;
    }

    fn callModel(self: *Agent) !AgentResponse {
        return switch (self.cfg.mode) {
            .api => try transport.apiCall(self.allocator, self.cfg, self.history.items, self.tool_registry.getToolDefs()),
            .bridge => try transport.bridgeCall(self.allocator, self.cfg, self.history.items),
            .offline => try transport.fileQueueCall(self.allocator, self.cfg, self.history.items),
            .local => try transport.localCall(self.allocator, self.cfg, self.history.items),
            .interactive => try transport.apiCall(self.allocator, self.cfg, self.history.items, self.tool_registry.getToolDefs()),
        };
    }

    fn executeTool(self: *Agent, call: ToolCall) ![]const u8 {
        // Security check: require approval if configured
        if (self.cfg.security_require_approval) {
            const approved = try self.requestApproval(call);
            if (!approved) {
                return try self.allocator.dupe(u8, "Tool execution denied by user.");
            }
        }

        return try self.tool_registry.execute(call.name, call.arguments);
    }

    fn requestApproval(self: *Agent, call: ToolCall) !bool {
        _ = self;
        const stdout = std.fs.File.stdout();
        var msg_buf: [1024]u8 = undefined;
                
        try stdout.writeAll("\n⚠  Tool call requested: ");
        try stdout.writeAll(call.name);
        try stdout.writeAll("\n");
        _ = try std.fmt.bufPrint(&msg_buf, "   Args: {s}\n", .{call.arguments});
        try stdout.writeAll(msg_buf[0..std.mem.indexOf(u8, &msg_buf, "\n").? + 1]);
        try stdout.writeAll("   Approve? [y/N] ");

        var buf: [16]u8 = undefined;
        const bytes_read = std.fs.File.stdin().read(&buf) catch return false;
        if (bytes_read == 0) return false;
        const line = buf[0..bytes_read];

        return line.len > 0 and (line[0] == 'y' or line[0] == 'Y');
    }

    /// Run in daemon mode (non-interactive, for monitor/bridge)
    pub fn run(self: *Agent) !void {
        self.running = true;
        const stdout = std.fs.File.stdout();
        var msg_buf: [512]u8 = undefined;
        
        const msg = try std.fmt.bufPrint(&msg_buf, "micro-agent [{s}] starting in {s} mode...\n", .{
            self.cfg.agent_name,
            @tagName(self.cfg.mode),
        });
        try stdout.writeAll(msg);

        switch (self.cfg.mode) {
            .offline => try self.runFileQueueLoop(),
            .bridge => try self.runBridgeLoop(),
            .api => try self.runApiDaemon(),
            else => {
                try stdout.writeAll("Daemon mode not supported for this mode.\n");
            },
        }
    }

    fn runFileQueueLoop(self: *Agent) !void {
        const stdout = std.fs.File.stdout();
        var msg_buf: [1024]u8 = undefined;

        _ = try std.fmt.bufPrint(&msg_buf, "Watching inbox: {s}\n", .{self.cfg.transport_file_inbox});
        try stdout.writeAll(msg_buf[0..std.mem.indexOf(u8, &msg_buf, "\n").? + 1]);
        _ = try std.fmt.bufPrint(&msg_buf, "Writing to outbox: {s}\n", .{self.cfg.transport_file_outbox});
        try stdout.writeAll(msg_buf[0..std.mem.indexOf(u8, &msg_buf, "\n").? + 1]);

        while (self.running) {
            // Check inbox directory for new .prompt files
            const inbox_dir = std.fs.cwd().openDir(self.cfg.transport_file_inbox, .{
                .iterate = true,
            }) catch {
                std.Thread.sleep(self.cfg.transport_file_poll_ms * std.time.ns_per_ms);
                continue;
            };
            _ = inbox_dir;

            // TODO: iterate files, process prompts, write responses
            std.Thread.sleep(self.cfg.transport_file_poll_ms * std.time.ns_per_ms);
        }
    }

    fn runBridgeLoop(self: *Agent) !void {
        _ = self;
                try std.fs.File.stdout().writeAll("Bridge mode: serial transport not yet implemented.\n");
    }

    fn runApiDaemon(self: *Agent) !void {
        _ = self;
                try std.fs.File.stdout().writeAll("API daemon mode: use --interactive for now.\n");
    }
};

test "agent init" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var cfg = config.Config.defaults(gpa.allocator());
    defer cfg.deinit();
    var ag = try Agent.init(gpa.allocator(), &cfg);
    defer ag.deinit();
    try std.testing.expect(ag.history.items.len == 1); // system prompt
}
