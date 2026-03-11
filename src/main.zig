const std = @import("std");
const builtin = @import("builtin");
const config = @import("core/config.zig");
const agent = @import("core/agent.zig");
const terminal_ui = @import("ui/terminal.zig");

const version = "0.1.0";

const Mode = enum {
    api,
    bridge,
    offline,
    interactive,
    help,
    version_cmd,
};

const CliArgs = struct {
    mode: Mode = .interactive,
    config_path: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    model: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    serial_port: ?[]const u8 = null,
    // FIX 7: Optional baud rate — only override config if explicitly passed via CLI
    baud_rate: ?u32 = null,
    inbox: ?[]const u8 = null,
    outbox: ?[]const u8 = null,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const result = mainInner(allocator) catch |err| {
        std.debug.print("Error: {any}\n", .{err});
        if (builtin.os.tag == .windows) {
            std.os.windows.kernel32.ExitProcess(1);
        }
        return err;
    };

    if (builtin.os.tag == .windows) {
        std.os.windows.kernel32.ExitProcess(result);
    }
}

fn mainInner(allocator: std.mem.Allocator) !u8 {
    var arg_iter = try std.process.argsWithAllocator(allocator);
    defer arg_iter.deinit();

    const args = try parseArgs(&arg_iter);

    return switch (args.mode) {
        .help => blk: {
            printHelp();
            break :blk 0;
        },
        .version_cmd => blk: {
            printVersion();
            break :blk 0;
        },
        .interactive => try runInteractive(allocator, args),
        .api => try runAgent(allocator, args),
        .bridge => try runAgent(allocator, args),
        .offline => try runAgent(allocator, args),
    };
}

fn runInteractive(allocator: std.mem.Allocator, args: CliArgs) !u8 {
    try std.fs.File.stdout().writeAll("Initializing micro-agent...\n");

    // Load config if path provided (or default config.json exists)
    var cfg = if (args.config_path) |path| blk: {
        var file_found = true;
        std.fs.cwd().access(path, .{}) catch {
            file_found = false;
        };

        if (file_found) {
            var msg_buf: [1024]u8 = undefined;
            const msg = try std.fmt.bufPrint(&msg_buf, "Loading configuration from: {s}\n", .{path});
            try std.fs.File.stdout().writeAll(msg);
            break :blk try config.Config.loadFromFile(allocator, path);
        } else {
            if (!std.mem.eql(u8, path, "config.json")) {
                var msg_buf: [1024]u8 = undefined;
                const msg = try std.fmt.bufPrint(&msg_buf, "Warning: Config file '{s}' not found. Using defaults.\n", .{path});
                try std.fs.File.stdout().writeAll(msg);
            }
            break :blk config.Config.defaults(allocator);
        }
    } else config.Config.defaults(allocator);
    defer cfg.deinit();

    // Override config with CLI args
    applyCliOverrides(&cfg, args);

    // Start terminal UI
    try terminal_ui.run(allocator, &cfg);
    return 0;
}

fn runAgent(allocator: std.mem.Allocator, args: CliArgs) !u8 {
    var cfg = if (args.config_path) |path| blk: {
        var file_found = true;
        std.fs.cwd().access(path, .{}) catch {
            file_found = false;
        };

        if (file_found) {
            break :blk try config.Config.loadFromFile(allocator, path);
        } else {
            break :blk config.Config.defaults(allocator);
        }
    } else config.Config.defaults(allocator);
    defer cfg.deinit();

    applyCliOverrides(&cfg, args);

    // Start agent loop (daemon mode)
    var ag = try agent.Agent.init(allocator, &cfg);
    defer ag.deinit();
    try ag.run();
    return 0;
}

fn applyCliOverrides(cfg: *config.Config, args: CliArgs) void {
    // Duplicate CLI strings to ensure proper ownership
    if (args.provider) |p| {
        cfg.transport_api_provider = cfg.dupeAndOwn(p) catch p;
    }
    if (args.api_key) |k| {
        cfg.transport_api_key = cfg.dupeAndOwn(k) catch k;
    }
    if (args.model) |m| {
        cfg.transport_api_model = cfg.dupeAndOwn(m) catch m;
    }
    if (args.base_url) |u| {
        cfg.transport_api_base_url = cfg.dupeAndOwn(u) catch u;
    }
    if (args.serial_port) |s| {
        cfg.transport_serial_port = cfg.dupeAndOwn(s) catch s;
    }
    // FIX 7: Only override baud rate if explicitly set via CLI
    if (args.baud_rate) |b| {
        cfg.transport_serial_baud = b;
    }
    if (args.inbox) |i| {
        cfg.transport_file_inbox = cfg.dupeAndOwn(i) catch i;
    }
    if (args.outbox) |o| {
        cfg.transport_file_outbox = cfg.dupeAndOwn(o) catch o;
    }

    cfg.mode = switch (args.mode) {
        .api => .api,
        .bridge => .bridge,
        .offline => .offline,
        .interactive => .interactive,
        else => .interactive,
    };
}

fn parseArgs(arg_iter: *std.process.ArgIterator) !CliArgs {
    var args = CliArgs{
        .config_path = "config.json",
    };
    _ = arg_iter.next(); // skip executable name

    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            args.mode = .help;
            return args;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            args.mode = .version_cmd;
            return args;
        } else if (std.mem.eql(u8, arg, "--mode")) {
            if (arg_iter.next()) |mode_str| {
                if (std.mem.eql(u8, mode_str, "api")) {
                    args.mode = .api;
                } else if (std.mem.eql(u8, mode_str, "bridge")) {
                    args.mode = .bridge;
                } else if (std.mem.eql(u8, mode_str, "offline")) {
                    args.mode = .offline;
                } else if (std.mem.eql(u8, mode_str, "interactive")) {
                    args.mode = .interactive;
                }
            }
        } else if (std.mem.eql(u8, arg, "--config")) {
            args.config_path = arg_iter.next();
        } else if (std.mem.eql(u8, arg, "--provider")) {
            args.provider = arg_iter.next();
        } else if (std.mem.eql(u8, arg, "--key")) {
            args.api_key = arg_iter.next();
        } else if (std.mem.eql(u8, arg, "--model")) {
            args.model = arg_iter.next();
        } else if (std.mem.eql(u8, arg, "--url")) {
            args.base_url = arg_iter.next();
        } else if (std.mem.eql(u8, arg, "--serial")) {
            args.serial_port = arg_iter.next();
        } else if (std.mem.eql(u8, arg, "--inbox")) {
            args.inbox = arg_iter.next();
        } else if (std.mem.eql(u8, arg, "--outbox")) {
            args.outbox = arg_iter.next();
        // FIX 7: Parse --baud argument
        } else if (std.mem.eql(u8, arg, "--baud")) {
            if (arg_iter.next()) |baud_str| {
                args.baud_rate = std.fmt.parseInt(u32, baud_str, 10) catch null;
            }
        } else if (std.mem.eql(u8, arg, "--interactive") or std.mem.eql(u8, arg, "-i")) {
            args.mode = .interactive;
        }
    }

    return args;
}

fn printVersion() void {
    std.debug.print("retro-agent v{s}\n", .{version});
}

fn printHelp() void {
    std.fs.File.stdout().writeAll(
        \\micro-agent — AI agent for legacy hardware
        \\
        \\USAGE:
        \\  micro-agent [OPTIONS]
        \\
        \\MODES:
        \\  --mode api         Connect to AI provider (OpenAI-compatible / Ollama)
        \\  --mode bridge      Serial bridge to external device
        \\  --mode offline     File queue (USB sneakernet)
        \\  --interactive, -i  Interactive terminal (default)
        \\
        \\OPTIONS:
        \\  --config <path>    Path to config.json
        \\  --provider <name>  API provider (openai, ollama)
        \\  --key <key>        API key
        \\  --model <name>     Model name
        \\  --url <url>        Ollama/API base URL (e.g. http://192.168.1.100:11434)
        \\  --serial <port>    Serial port for bridge mode
        \\  --baud <rate>      Baud rate for serial port
        \\  --inbox <path>     Inbox directory for offline mode
        \\  --outbox <path>    Outbox directory for offline mode
        \\  --help, -h         Show this help
        \\  --version, -v      Show version
        \\
        \\EXAMPLES:
        \\  micro-agent --url http://192.168.1.100:11434 --model llama3
        \\  micro-agent --mode api --provider openai --model llama3
        \\  micro-agent --mode bridge --serial /dev/ttyUSB0 --baud 9600
        \\  micro-agent --mode offline --inbox /mnt/usb/in --outbox /mnt/usb/out
        \\  micro-agent -i --config /etc/micro-agent/config.json
        \\
    ) catch {};
}

test "parse args defaults" {
    const args = CliArgs{};
    try std.testing.expectEqual(args.mode, .interactive);
    try std.testing.expectEqual(args.baud_rate, null); // FIX 7: now optional
}

// Windows XP Compatibility Overrides
// RtlGetSystemTimePrecise is only available on Windows 8+.
// We redirect it to GetSystemTimeAsFileTime for legacy support.
comptime {
    if (builtin.os.tag == .windows) {
        @export(&RtlGetSystemTimePrecise, .{ .name = "RtlGetSystemTimePrecise", .linkage = .strong });
    }
}

fn RtlGetSystemTimePrecise() callconv(.winapi) i64 {
    const FILETIME = extern struct {
        dwLowDateTime: u32,
        dwHighDateTime: u32,
    };
    const kernel32 = struct {
        extern "kernel32" fn GetSystemTimeAsFileTime(lpSystemTimeAsFileTime: *FILETIME) callconv(.winapi) void;
    };

    var ft: FILETIME = undefined;
    kernel32.GetSystemTimeAsFileTime(&ft);
    return @bitCast(ft);
}
