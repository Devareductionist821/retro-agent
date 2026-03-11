const std = @import("std");
const config = @import("../core/config.zig");

/// File/log monitor that watches paths for changes and pattern matches
pub const Monitor = struct {
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    running: bool = false,

    pub fn init(allocator: std.mem.Allocator, cfg: *config.Config) Monitor {
        return .{
            .allocator = allocator,
            .cfg = cfg,
        };
    }

    pub fn deinit(self: *Monitor) void {
        _ = self;
    }

    /// Start monitoring watched paths
    /// In a full implementation this would use inotify (Linux) or
    /// polling for maximum compatibility with old kernels
    pub fn start(self: *Monitor) !void {
        self.running = true;
                try std.fs.File.stdout().writeAll("Monitor: started (polling mode)\n");

        // Polling loop — compatible with any kernel version
        while (self.running) {
            try self.pollWatchedPaths();
            std.time.sleep(5 * std.time.ns_per_s);
        }
    }

    pub fn stop(self: *Monitor) void {
        self.running = false;
    }

    fn pollWatchedPaths(self: *Monitor) !void {
        _ = self;
        // TODO: iterate config watch_paths
        // For each path:
        //   1. Check if file has been modified since last check
        //   2. Read new content (tail)
        //   3. Apply pattern matching rules
        //   4. If pattern matches, trigger action (alert, agent call)
    }
};

/// A pattern match rule
pub const PatternRule = struct {
    name: []const u8,
    regex_pattern: []const u8, // simplified pattern matching (not full regex)
    threshold: ?f64 = null,
    action: Action,

    pub const Action = enum {
        alert,
        agent_call,
        log,
        exec,
    };
};

/// Simple pattern matcher that doesn't need regex library
/// Uses basic string matching — sufficient for log monitoring
pub fn simpleMatch(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// Extract a numeric value after a prefix string
/// e.g. extractNumber("TEMP: 85.5 C", "TEMP:") => 85.5
pub fn extractNumber(line: []const u8, prefix: []const u8) ?f64 {
    const idx = std.mem.indexOf(u8, line, prefix) orelse return null;
    const after = line[idx + prefix.len ..];
    const trimmed = std.mem.trimLeft(u8, after, " ");

    // Find end of number
    var end: usize = 0;
    var has_dot = false;
    for (trimmed) |c| {
        if (c >= '0' and c <= '9') {
            end += 1;
        } else if (c == '.' and !has_dot) {
            has_dot = true;
            end += 1;
        } else {
            break;
        }
    }

    if (end == 0) return null;
    return std.fmt.parseFloat(f64, trimmed[0..end]) catch null;
}

test "simple match" {
    try std.testing.expect(simpleMatch("ERROR: temperature exceeded", "ERROR"));
    try std.testing.expect(!simpleMatch("INFO: all good", "ERROR"));
}

test "extract number" {
    const val = extractNumber("TEMP: 85.5 C", "TEMP:");
    try std.testing.expect(val != null);
    try std.testing.expectApproxEqAbs(val.?, 85.5, 0.01);
}
