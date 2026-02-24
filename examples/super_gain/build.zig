const std = @import("std");
const z_plug = @import("z_plug");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("z_plug", .{ .target = target, .optimize = optimize });

    z_plug.addPlugin(b, dep, .{
        .name = "ZigSuperGain",
        .root_source_file = b.path("src/plugin.zig"),
        .target = target,
        .optimize = optimize,
        .formats = .{ .clap = true, .vst3 = true },
    });
}
