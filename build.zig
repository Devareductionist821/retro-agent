const std = @import("std");

pub fn build(b: *std.Build) void {
    // Allow user to override target for cross-compilation
    const target = b.standardTargetOptions(.{
        .default_target = .{},
    });

    const optimize = b.standardOptimizeOption(.{});

    var target_query = target.query;
    if (target_query.os_tag == .windows and target_query.cpu_arch == .x86) {
        target_query.os_version_min = .{ .windows = .xp };
        target_query.os_version_max = .{ .windows = .latest };
    }
    const final_target = b.resolveTargetQuery(target_query);

    // ── Main executable ──
    const exe = b.addExecutable(.{
        .name = "micro-agent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = final_target,
            .optimize = optimize,
            .strip = if (optimize == .ReleaseSmall) true else false,
            .single_threaded = true,
        }),
    });
    if (final_target.result.os.tag == .windows) {
        // We avoid linking libc for now to prevent UCRT dependencies on XP
        // exe.linkLibC();
    }
    exe.stack_size = 16 * 1024 * 1024;
    exe.subsystem = .Console;

    b.installArtifact(exe);

    // ── Run step ──
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run micro-agent");
    run_step.dependOn(&run_cmd.step);

    // ── Tests ──
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // ── Cross-compilation convenience targets ──
    const cross_step = b.step("cross", "Build for all supported targets");

    const cross_targets = [_]CrossTarget{
        .{ .name = "x86-linux", .arch = .x86, .os = .linux, .abi = .musl },
        .{ .name = "x86_64-linux", .arch = .x86_64, .os = .linux, .abi = .musl },
        .{ .name = "arm-linux", .arch = .arm, .os = .linux, .abi = .musleabihf },
        .{ .name = "aarch64-linux", .arch = .aarch64, .os = .linux, .abi = .musl },
        .{ .name = "x86-windows", .arch = .x86, .os = .windows, .abi = .gnu },
        .{ .name = "x86_64-windows", .arch = .x86_64, .os = .windows, .abi = .gnu },
    };

    for (cross_targets) |ct| {
        const cross_target = b.resolveTargetQuery(.{
            .cpu_arch = ct.arch,
            .os_tag = ct.os,
            .os_version_min = if (ct.os == .windows and ct.arch == .x86) .{ .windows = .xp } else null,
            .os_version_max = if (ct.os == .windows and ct.arch == .x86) .{ .windows = .latest } else null,
            .abi = ct.abi,
        });
        const cross_exe = b.addExecutable(.{
            .name = b.fmt("micro-agent-{s}", .{ct.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = cross_target,
                .optimize = .ReleaseSmall,
                .strip = true,
                .single_threaded = true,
            }),
        });
        if (cross_target.result.os.tag == .windows) {
            // cross_exe.linkLibC();
        }
        const install = b.addInstallArtifact(cross_exe, .{});
        cross_step.dependOn(&install.step);
    }
}

const CrossTarget = struct {
    name: []const u8,
    arch: std.Target.Cpu.Arch,
    os: std.Target.Os.Tag,
    abi: std.Target.Abi,
};
