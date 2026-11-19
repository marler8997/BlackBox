//! The files the installers carry, shared by build.zig and installer.zig.

pub const Arch = enum {
    x86_64,
    aarch64,

    pub fn cpu(a: Arch) std.Target.Cpu.Arch {
        return switch (a) {
            .x86_64 => .x86_64,
            .aarch64 => .aarch64,
        };
    }

    pub const native: Arch = switch (builtin.cpu.arch) {
        .x86_64 => .x86_64,
        .aarch64 => .aarch64,
        else => @compileError("Black Box doesn't build for " ++ @tagName(builtin.cpu.arch)),
    };

    /// The x86_64 installer also carries the ARM64 build, for when it runs emulated on ARM64.
    pub fn installerArches(comptime installer: Arch) []const Arch {
        return switch (installer) {
            .x86_64 => &.{ .x86_64, .aarch64 },
            .aarch64 => &.{.aarch64},
        };
    }
};

pub const files = [_][]const u8{
    "BlackBox.exe",
    "BlackBox.pdb",
    "bin\\blackbox.exe",
    "bin\\blackbox.pdb",
};

/// By index: module names can't have the backslashes file names do.
pub fn importName(comptime arch: Arch, comptime file_index: usize) []const u8 {
    return std.fmt.comptimePrint("{t}-{d}", .{ arch, file_index });
}

const std = @import("std");
const builtin = @import("builtin");
