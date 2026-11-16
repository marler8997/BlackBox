pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const win32_mod = b.dependency("win32", .{}).module("win32");

    // std patched with staticio: std.Io dispatch is static, so only reachable Io operations
    // are compiled in (see std_options.io_vtable in src/win32.zig).
    const patched_std = b.dependency("patch", .{
        .std_patches = &[_]std.Build.LazyPath{
            b.dependency("staticio", .{}).namedLazyPath("std.patch"),
        },
    }).module("std");

    const gui_mod = b.createModule(.{
        .root_source_file = b.path("src/win32.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "std", .module = patched_std },
            .{ .name = "win32", .module = win32_mod },
            .{ .name = "wintrace", .module = b.dependency("wintrace", .{}).module("wintrace") },
        },
    });

    // The icon: a PNG drawn for each size (src/icon), packed into an .ico by appicon and
    // embedded as resource 1 (src/win32.rc).
    {
        const ico = appicon.createWindowsIco(b, b.dependency("appicon", .{}), "blackbox.ico", &.{
            .{ .source = b.path("src/icon/black_box_16.png"), .sizes = &.{16}, .enforce_size = 16 },
            .{ .source = b.path("src/icon/black_box_20.png"), .sizes = &.{20}, .enforce_size = 20 },
            .{ .source = b.path("src/icon/black_box_24.png"), .sizes = &.{24}, .enforce_size = 24 },
            .{ .source = b.path("src/icon/black_box_32.png"), .sizes = &.{32}, .enforce_size = 32 },
            .{ .source = b.path("src/icon/black_box_40.png"), .sizes = &.{40}, .enforce_size = 40 },
            .{ .source = b.path("src/icon/black_box_48.png"), .sizes = &.{48}, .enforce_size = 48 },
            .{ .source = b.path("src/icon/black_box_64.png"), .sizes = &.{64}, .enforce_size = 64 },
            .{ .source = b.path("src/icon/black_box_256.png"), .sizes = &.{256}, .enforce_size = 256 },
        });
        gui_mod.addWin32ResourceFile(.{
            .file = b.path("src/win32.rc"),
            .include_paths = &.{ico.dirname()},
        });
    }

    const gui = b.addExecutable(.{
        .name = "BlackBox",
        .root_module = gui_mod,
        .win32_manifest = b.path("src/win32.manifest"),
    });
    gui.subsystem = .windows;
    {
        const install = b.addInstallArtifact(gui, .{
            .dest_dir = .{ .override = .{ .custom = "appdata" } },
        });
        b.step("install-gui", "").dependOn(&install.step);
        b.getInstallStep().dependOn(&install.step);
        const run = b.addRunArtifact(gui);
        run.step.dependOn(&install.step);
        run.addPassthruArgs();
        b.step("run", "Build and run the GUI").dependOn(&run.step);
    }

    // The command line, in a bin folder beside the GUI: Windows file names ignore case, so
    // blackbox.exe and BlackBox.exe can't share one.
    const cli = b.addExecutable(.{
        .name = "blackbox",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "win32", .module = win32_mod },
                .{ .name = "wintrace", .module = b.dependency("wintrace", .{}).module("wintrace") },
            },
        }),
    });
    {
        const install = b.addInstallArtifact(cli, .{
            .dest_dir = .{ .override = .{ .custom = "appdata/bin" } },
        });
        b.getInstallStep().dependOn(&install.step);
        b.step("install-cli", "").dependOn(&install.step);
        const run = b.addRunArtifact(cli);
        run.step.dependOn(&install.step);
        run.addPassthruArgs();
        b.step("cli", "Build and run the command line (zig build cli -- ARGS)").dependOn(&run.step);
    }

    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{ .root_module = gui_mod });
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // Drift correction's scenarios: platform-independent, and heavy (minutes of audio through
    // the resampler), so optimized even in a debug build.
    const resample_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/resample_test.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    }) });
    test_step.dependOn(&b.addRunArtifact(resample_tests).step);

    // The command line as it's used: what it says, and its exit code. (Recovery itself is
    // tested through record.recover, which `blackbox recover` calls.)
    const CliTest = struct {
        args: []const []const u8,
        /// A folder of the repository, after args.
        folder: ?[]const u8 = null,
        code: u8,
        stdout: ?[]const u8 = null,
        stderr: ?[]const u8 = null,
    };
    const cli_tests = [_]CliTest{
        .{ .args = &.{}, .code = 1, .stderr = "usage: blackbox COMMAND" },
        .{ .args = &.{"frobnicate"}, .code = 1, .stderr = "unknown command 'frobnicate'" },
        .{ .args = &.{"recover"}, .code = 1, .stderr = "blackbox recover takes the recording's folder" },
        .{ .args = &.{ "recover", "a", "b" }, .code = 1, .stderr = "takes just the recording's folder" },
        .{ .args = &.{ "recover", "no such recording folder" }, .code = 1, .stderr = "no such recording folder: no such folder" },
        // A folder that isn't an unfinished recording: nothing done, and that's fine.
        .{ .args = &.{"recover"}, .folder = "src/icon", .code = 0, .stdout = "nothing to recover" },
    };
    for (cli_tests) |t| {
        const run = b.addRunArtifact(cli);
        run.addArgs(t.args);
        if (t.folder) |f| run.addDirectoryArg(b.path(f));
        run.expectExitCode(t.code);
        if (t.stdout) |s| run.addCheck(.{ .expect_stdout_match = s });
        if (t.stderr) |s| run.addCheck(.{ .expect_stderr_match = s });
        test_step.dependOn(&run.step);
    }
}

const std = @import("std");
const appicon = @import("appicon");
