const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("zerial", .{
        .root_source_file = b.path("src/zerial.zig"),
        .target = target,
        .optimize = optimize,
    });
}
