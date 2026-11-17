pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const win32_mod = b.dependency("win32", .{}).module("win32");
    const wintrace_mod = b.dependency("wintrace", .{}).module("wintrace");

    // std patched with staticio: std.Io dispatch is static, so only reachable Io operations
    // are compiled in (see std_options.io_vtable in src/win32.zig).
    const patched_std = b.dependency("patch", .{
        .std_patches = &[_]std.Build.LazyPath{
            b.dependency("staticio", .{}).namedLazyPath("std.patch"),
        },
    }).module("std");

    // The icon: a PNG drawn for each size (src/icon), packed into an .ico by appicon and
    // embedded as resource 1 (src/win32.rc).
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

    // Every build is for both architectures Windows runs on, each a cross build: for that
    // architecture's baseline CPU, never the build machine's (native), whose instructions a
    // user's CPU might not have. Installed to zig-out/ARCH; install, run and test use the
    // build machine's architecture.
    const host_arch = b.graph.host.result.cpu.arch;
    var host: ?Arch = null;
    for ([_]std.Target.Cpu.Arch{ .x86_64, .aarch64 }) |cpu_arch| {
        const arch = addArch(b, cpu_arch, .{
            .optimize = optimize,
            .win32 = win32_mod,
            .wintrace = wintrace_mod,
            .std = patched_std,
            .ico = ico,
        });
        if (cpu_arch == host_arch) host = arch;
    }
    const install_step = b.getInstallStep();
    const run_step = b.step("run", "Build and run the GUI for this machine's architecture");
    const cli_step = b.step("cli", "Build and run the command line for this machine's architecture (zig build cli -- ARGS)");
    const test_step = b.step("test", "Run unit tests on this machine's architecture");
    const arch = host orelse {
        const fail = b.addFail(b.fmt("Black Box builds for x86_64 and aarch64, this machine is {t}: use the install-x86_64 or install-aarch64 step", .{host_arch}));
        for ([_]*std.Build.Step{ install_step, run_step, cli_step, test_step }) |s| s.dependOn(&fail.step);
        return;
    };
    install_step.dependOn(arch.install);
    run_step.dependOn(arch.run);
    cli_step.dependOn(arch.cli_run);

    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = arch.gui.root_module })).step);
    // Drift correction's scenarios: platform-independent, and heavy (minutes of audio through
    // the resampler), so optimized even in a debug build.
    const resample_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/resample_test.zig"),
        .target = arch.target,
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
        const run = b.addRunArtifact(arch.cli);
        run.addArgs(t.args);
        if (t.folder) |f| run.addDirectoryArg(b.path(f));
        run.expectExitCode(t.code);
        if (t.stdout) |s| run.addCheck(.{ .expect_stdout_match = s });
        if (t.stderr) |s| run.addCheck(.{ .expect_stderr_match = s });
        test_step.dependOn(&run.step);
    }
}

const Shared = struct {
    optimize: std.builtin.OptimizeMode,
    win32: *std.Build.Module,
    wintrace: *std.Build.Module,
    std: *std.Build.Module,
    ico: std.Build.LazyPath,
};

const Arch = struct {
    target: std.Build.ResolvedTarget,
    gui: *std.Build.Step.Compile,
    cli: *std.Build.Step.Compile,
    install: *std.Build.Step,
    run: *std.Build.Step,
    cli_run: *std.Build.Step,
};

/// The GUI and the command line for one architecture, installed to zig-out/ARCH/appdata, with
/// install-ARCH, run-ARCH and cli-ARCH steps.
fn addArch(b: *std.Build, cpu_arch: std.Target.Cpu.Arch, shared: Shared) Arch {
    const name = @tagName(cpu_arch);
    const target = b.resolveTargetQuery(.{ .cpu_arch = cpu_arch, .os_tag = .windows });
    const install = b.step(b.fmt("install-{s}", .{name}), b.fmt("Build for {s} into zig-out/{s}", .{ name, name }));

    const gui_mod = b.createModule(.{
        .root_source_file = b.path("src/win32.zig"),
        .target = target,
        .optimize = shared.optimize,
        .imports = &.{
            .{ .name = "std", .module = shared.std },
            .{ .name = "win32", .module = shared.win32 },
            .{ .name = "wintrace", .module = shared.wintrace },
        },
    });
    gui_mod.addWin32ResourceFile(.{
        .file = b.path("src/win32.rc"),
        .include_paths = &.{shared.ico.dirname()},
    });
    const gui = b.addExecutable(.{
        .name = "BlackBox",
        .root_module = gui_mod,
        .win32_manifest = b.path("src/win32.manifest"),
    });
    gui.subsystem = .windows;
    const gui_install = b.addInstallArtifact(gui, .{
        .dest_dir = .{ .override = .{ .custom = b.fmt("{s}/appdata", .{name}) } },
    });
    install.dependOn(&gui_install.step);
    const run = b.addRunArtifact(gui);
    run.step.dependOn(&gui_install.step);
    run.addPassthruArgs();
    b.step(b.fmt("run-{s}", .{name}), b.fmt("Build and run the GUI for {s}", .{name})).dependOn(&run.step);

    // The command line, in a bin folder beside the GUI: Windows file names ignore case, so
    // blackbox.exe and BlackBox.exe can't share one.
    const cli = b.addExecutable(.{
        .name = "blackbox",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = shared.optimize,
            .imports = &.{
                .{ .name = "win32", .module = shared.win32 },
                .{ .name = "wintrace", .module = shared.wintrace },
            },
        }),
    });
    const cli_install = b.addInstallArtifact(cli, .{
        .dest_dir = .{ .override = .{ .custom = b.fmt("{s}/appdata/bin", .{name}) } },
    });
    install.dependOn(&cli_install.step);
    const cli_run = b.addRunArtifact(cli);
    cli_run.step.dependOn(&cli_install.step);
    cli_run.addPassthruArgs();
    b.step(b.fmt("cli-{s}", .{name}), b.fmt("Build and run the command line for {s} (zig build cli-{s} -- ARGS)", .{ name, name })).dependOn(&cli_run.step);

    return .{ .target = target, .gui = gui, .cli = cli, .install = install, .run = &run.step, .cli_run = &cli_run.step };
}

const std = @import("std");
const appicon = @import("appicon");
