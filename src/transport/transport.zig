const std = @import("std");
const config = @import("../core/config.zig");
const agent = @import("../core/agent.zig");

// ─────────────────────────────────────────────
// Transport: API (HTTP calls to OpenAI-compatible providers)
// FIX 1: Removed all Anthropic support — Ollama/OpenAI-compatible only
// ─────────────────────────────────────────────

pub fn apiCall(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    history: []const agent.Message,
    tool_defs: ?[]const ToolDef,
) !agent.AgentResponse {
    // Build request JSON
    const body = try buildApiRequestBody(allocator, cfg, history, tool_defs);
    defer allocator.free(body);

    // Determine endpoint — always OpenAI-compatible
    const url = try buildApiUrl(allocator, cfg);
    defer allocator.free(url);

    // Make HTTP request
    const response_body = httpPost(allocator, url, body, cfg) catch {
        const msg = try allocator.dupe(u8, "Error: could not reach the AI provider. Check your connection and API key.");
        return agent.AgentResponse{
            .text = msg,
            .done = true,
        };
    };
    defer allocator.free(response_body);

    // Parse response
    return try parseApiResponse(allocator, cfg, response_body);
}

// FIX 1: Simplified — always use /v1/chat/completions (OpenAI-compatible)
fn buildApiUrl(allocator: std.mem.Allocator, cfg: *config.Config) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}/v1/chat/completions", .{cfg.transport_api_base_url});
}

// FIX 1: Simplified — always build OpenAI body directly
fn buildApiRequestBody(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    history: []const agent.Message,
    tool_defs: ?[]const ToolDef,
) ![]const u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try buildOpenAIBody(writer, cfg, history, tool_defs);

    return try buf.toOwnedSlice(allocator);
}

fn buildOpenAIBody(
    writer: anytype,
    cfg: *config.Config,
    history: []const agent.Message,
    tool_defs: ?[]const ToolDef,
) !void {
    try writer.writeAll("{");
    try writer.writeAll("\"model\":");
    try writeJsonString(writer, cfg.transport_api_model);
    try writer.writeAll(",");

    try writer.writeAll("\"messages\":[");
    for (history, 0..) |msg, i| {
        if (i > 0) try writer.writeAll(",");
        const role_str = switch (msg.role) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
            .tool_call => "assistant",
            .tool_result => "tool",
        };
        
        try writer.print("{{\"role\":\"{s}\"", .{role_str});
        
        if (msg.role == .tool_call) {
            try writer.writeAll(",\"content\":\"\",\"tool_calls\":[{\"id\":");
            try writeJsonString(writer, msg.tool_id.?);
            try writer.print(",\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"arguments\":", .{msg.tool_name.?});
            try writeJsonString(writer, msg.content);
            try writer.writeAll("}}]");
        } else if (msg.role == .tool_result) {
            try writer.writeAll(",\"tool_call_id\":");
            try writeJsonString(writer, msg.tool_id.?);
            try writer.writeAll(",\"content\":");
            try writeJsonString(writer, msg.content);
        } else {
            try writer.writeAll(",\"content\":");
            try writeJsonString(writer, msg.content);
        }
        
        try writer.writeAll("}");
    }
    try writer.writeAll("]");

    // Tools
    if (tool_defs) |td| {
        if (td.len > 0) {
            try writer.writeAll(",\"tools\":[");
            for (td, 0..) |tool, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("{{\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"description\":\"{s}\",\"parameters\":{s}}}}}", .{
                    tool.name,
                    tool.description,
                    tool.parameters_json,
                });
            }
            try writer.writeAll("]");
        }
    }
    try writer.writeAll("}");
}

/// Minimal HTTP POST using Zig's std.http.Client
/// FIX 1: Removed Anthropic headers — always uses Bearer auth
fn httpPost(
    allocator: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
    cfg: *config.Config,
) ![]const u8 {
    // Debug logging
    if (cfg.debug_mode) {
        std.debug.print("\n[DEBUG] HTTP POST to: {s}\n", .{url});
        std.debug.print("[DEBUG] Request body length: {d} bytes\n", .{body.len});
        if (body.len < 2000) {
            std.debug.print("[DEBUG] Request body: {s}\n", .{body});
        }
    }
    
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    
    // Crucial for Windows/HTTPS: initialize CA bundle
    if (std.mem.startsWith(u8, url, "https://")) {
        client.ca_bundle.rescan(allocator) catch {
            std.log.err("TLS/HTTPS not available on this system. Use HTTP base_url or upgrade OS.", .{});
            std.log.err("Windows XP only supports TLS 1.0. Modern APIs require TLS 1.2+.", .{});
            std.log.err("Solution: Use a local proxy with TLS 1.2+ support.", .{});
            return error.TlsNotAvailable;
        };
    }

    const uri = try std.Uri.parse(url);

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{cfg.transport_api_key});
    defer allocator.free(auth_header);

    var req = try client.request(.POST, uri, .{
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Authorization", .value = auth_header },
        },
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    
    var req_write_buf: [1024]u8 = undefined;
    var req_body = try req.sendBodyUnflushed(&req_write_buf);
    try req_body.writer.writeAll(body);
    try req_body.end();
    try req.connection.?.flush();

    var redirect_buf: [4096]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    // Debug logging
    if (cfg.debug_mode) {
        std.debug.print("[DEBUG] Response status: {}\n", .{response.head.status});
    }

    if (response.head.status != .ok) {
        std.log.err("API returned error status: {}", .{response.head.status});
        return error.ApiError;
    }

    var response_transfer_buf: [4096]u8 = undefined;
    const response_body = try response.reader(&response_transfer_buf).allocRemaining(allocator, .unlimited);
    
    // Debug logging
    if (cfg.debug_mode) {
        std.debug.print("[DEBUG] Response body length: {d} bytes\n", .{response_body.len});
        if (response_body.len < 2000) {
            std.debug.print("[DEBUG] Response body: {s}\n", .{response_body});
        }
    }
    
    return response_body;
}

// FIX 1: Simplified parseApiResponse — OpenAI format only, no Anthropic brace-matching hack
pub fn parseApiResponse(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    body: []const u8,
) !agent.AgentResponse {
    _ = cfg;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        const msg = try allocator.dupe(u8, "Error: could not parse API response.");
        return agent.AgentResponse{
            .text = msg,
            .done = true,
        };
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        const msg = try allocator.dupe(u8, "Error: unexpected response format.");
        return agent.AgentResponse{ .text = msg, .done = true };
    }

    // OpenAI format: choices[0].message.content or tool_calls
    if (root.object.get("choices")) |choices| {
        if (choices == .array and choices.array.items.len > 0) {
            const first = choices.array.items[0];
            if (first == .object) {
                if (first.object.get("message")) |msg| {
                    if (msg == .object) {
                        // Check for tool_calls first
                        if (msg.object.get("tool_calls")) |tc| {
                            if (tc == .array and tc.array.items.len > 0) {
                                var calls = std.ArrayList(agent.ToolCall).initCapacity(allocator, 0) catch unreachable;
                                for (tc.array.items) |item| {
                                    if (item == .object) {
                                        const id = item.object.get("id").?.string;
                                        const func = item.object.get("function").?.object;
                                        const name = func.get("name").?.string;
                                        const args = func.get("arguments").?.string;

                                        try calls.append(allocator, .{
                                            .id = try allocator.dupe(u8, id),
                                            .name = try allocator.dupe(u8, name),
                                            .arguments = try allocator.dupe(u8, args),
                                        });
                                    }
                                }
                                return agent.AgentResponse{
                                    .tool_calls = try calls.toOwnedSlice(allocator),
                                    .done = false,
                                };
                            }
                        }

                        // Check for text content (handle null content for tool_calls-only responses)
                        if (msg.object.get("content")) |c| {
                            if (c == .string) {
                                const duplicated_text = try allocator.dupe(u8, c.string);
                                return agent.AgentResponse{
                                    .text = duplicated_text,
                                    .done = true,
                                };
                            }
                            // FIX 9: content:null is valid when tool_calls are present (Ollama does this)
                        }
                    }
                }
            }
        }
    }

    const msg = try allocator.dupe(u8, "Error: could not extract response text.");
    return agent.AgentResponse{ .text = msg, .done = true };
}

// ─────────────────────────────────────────────
// Transport: Bridge (serial communication)
// ─────────────────────────────────────────────

pub fn bridgeCall(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    history: []const agent.Message,
) !agent.AgentResponse {
    _ = allocator;
    _ = cfg;
    _ = history;
    return agent.AgentResponse{
        .text = "Bridge transport not yet implemented.",
        .done = true,
    };
}

// ─────────────────────────────────────────────
// Transport: File Queue (offline/sneakernet)
// ─────────────────────────────────────────────

pub fn fileQueueCall(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    history: []const agent.Message,
) !agent.AgentResponse {
    _ = allocator;
    _ = cfg;
    _ = history;
    return agent.AgentResponse{
        .text = "File queue transport not yet implemented.",
        .done = true,
    };
}

// ─────────────────────────────────────────────
// Transport: Local inference (GGUF models)
// ─────────────────────────────────────────────

pub fn localCall(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    history: []const agent.Message,
) !agent.AgentResponse {
    _ = allocator;
    _ = cfg;
    _ = history;
    return agent.AgentResponse{
        .text = "Local inference not yet implemented.",
        .done = true,
    };
}

// ─────────────────────────────────────────────
// Tool definition for API tool_use
// ─────────────────────────────────────────────

pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8, // raw JSON schema
};

// ─────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────

fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

// ─────────────────────────────────────────────
// FIX 9: Tests for parseApiResponse (OpenAI format only)
// ─────────────────────────────────────────────

test "parseApiResponse: simple text response" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var cfg = config.Config.defaults(alloc);
    defer cfg.deinit();

    const json_str =
        \\{"choices":[{"message":{"role":"assistant","content":"Hello world"}}]}
    ;
    const resp = try parseApiResponse(alloc, &cfg, json_str);
    try std.testing.expect(resp.text != null);
    try std.testing.expectEqualStrings("Hello world", resp.text.?);
    try std.testing.expect(resp.tool_calls == null);
    alloc.free(resp.text.?);
}

test "parseApiResponse: single tool_call" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var cfg = config.Config.defaults(alloc);
    defer cfg.deinit();

    const json_str =
        \\{"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"call_123","type":"function","function":{"name":"exec","arguments":"{\"command\":\"dir\"}"}}]}}]}
    ;
    const resp = try parseApiResponse(alloc, &cfg, json_str);
    try std.testing.expect(resp.tool_calls != null);
    const tc = resp.tool_calls.?;
    try std.testing.expectEqual(@as(usize, 1), tc.len);
    try std.testing.expectEqualStrings("exec", tc[0].name);
    try std.testing.expectEqualStrings("call_123", tc[0].id);
    for (tc) |c| {
        alloc.free(c.id);
        alloc.free(c.name);
        alloc.free(c.arguments);
    }
    alloc.free(tc);
}

test "parseApiResponse: multiple tool_calls" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var cfg = config.Config.defaults(alloc);
    defer cfg.deinit();

    const json_str =
        \\{"choices":[{"message":{"tool_calls":[{"id":"c1","type":"function","function":{"name":"ping_host","arguments":"{}"}},{"id":"c2","type":"function","function":{"name":"system_info","arguments":"{}"}}]}}]}
    ;
    const resp = try parseApiResponse(alloc, &cfg, json_str);
    try std.testing.expect(resp.tool_calls != null);
    try std.testing.expectEqual(@as(usize, 2), resp.tool_calls.?.len);
    for (resp.tool_calls.?) |c| {
        alloc.free(c.id);
        alloc.free(c.name);
        alloc.free(c.arguments);
    }
    alloc.free(resp.tool_calls.?);
}

test "parseApiResponse: malformed JSON" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var cfg = config.Config.defaults(alloc);
    defer cfg.deinit();

    const resp = try parseApiResponse(alloc, &cfg, "not json at all");
    try std.testing.expect(resp.text != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.text.?, "Error") != null);
    alloc.free(resp.text.?);
}

test "parseApiResponse: empty JSON object" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var cfg = config.Config.defaults(alloc);
    defer cfg.deinit();

    const resp = try parseApiResponse(alloc, &cfg, "{}");
    try std.testing.expect(resp.text != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.text.?, "Error") != null);
    alloc.free(resp.text.?);
}

test "parseApiResponse: content null with tool_calls" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var cfg = config.Config.defaults(alloc);
    defer cfg.deinit();

    const json_str =
        \\{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"test","arguments":"{}"}}]}}]}
    ;
    const resp = try parseApiResponse(alloc, &cfg, json_str);
    try std.testing.expect(resp.tool_calls != null);
    const tc = resp.tool_calls.?;
    try std.testing.expectEqual(@as(usize, 1), tc.len);
    try std.testing.expectEqualStrings("test", tc[0].name);
    for (tc) |c| {
        alloc.free(c.id);
        alloc.free(c.name);
        alloc.free(c.arguments);
    }
    alloc.free(tc);
}
