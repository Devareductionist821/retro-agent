const std = @import("std");

pub fn build(b: *std.Build) void {
    // Windows XP x86 target
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86,
        .os_tag = .windows,
        .os_version_min = .{ .windows = .xp },
        .os_version_max = .{ .windows = .latest },
        .abi = .gnu,
    });

    const exe = b.addExecutable(.{
        .name = "agentxp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
            .strip = true,
            .single_threaded = true,
        }),
    });
    
    exe.stack_size = 16 * 1024 * 1024;
    exe.subsystem = .Console;

    b.installArtifact(exe);
}
