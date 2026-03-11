// FIX 5: Shared JSON utility module — extracted from registry.zig
// Provides dynamic allocation-based JSON field extraction to replace fixed buffers.

const std = @import("std");

/// Extract a string field from a JSON object. Returns an owned (duped) string, or null if missing/wrong type.
/// Caller must free the returned string with allocator.free().
pub fn extractJsonString(allocator: std.mem.Allocator, json: []const u8, key: []const u8) !?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const val = parsed.value.object.get(key) orelse return null;
    if (val != .string) return null;

    // Dupe because parsed will be freed
    return try allocator.dupe(u8, val.string);
}

/// Extract an integer field from a JSON object. Returns null if missing or wrong type.
pub fn extractJsonInt(allocator: std.mem.Allocator, json: []const u8, key: []const u8) !?i64 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const val = parsed.value.object.get(key) orelse return null;
    if (val != .integer) return null;
    return val.integer;
}

test "extractJsonString basic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const result = try extractJsonString(alloc, "{\"name\":\"hello\"}", "name");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("hello", result.?);
    alloc.free(result.?);
}

test "extractJsonString missing key" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const result = try extractJsonString(gpa.allocator(), "{\"name\":\"hello\"}", "missing");
    try std.testing.expect(result == null);
}

test "extractJsonInt basic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const result = try extractJsonInt(gpa.allocator(), "{\"count\":42}", "count");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i64, 42), result.?);
}
