//! blackbox: Black Box's command line, for what doesn't need the window. Installed in a bin
//! folder beside BlackBox.exe (Windows file names ignore case, so the two can't share one).
//! Its own parts are cross-platform; recording is Windows only for now, so is `recover`.

const usage =
    \\usage: blackbox COMMAND ...
    \\
    \\  blackbox recover FOLDER   finish the files of a recording a crash or power cut
    \\                            interrupted, from its checkpoint and journal. If those are
    \\                            damaged, says how and removes nothing.
    \\
;

pub const wintrace_options: wintrace.Options = .{ .mode = .symbolize };
pub const std_options: std.Options = .{
    // On Windows, wintrace.unhandledExceptionFilter reports unhandled exceptions.
    .enable_segfault_handler = native_os != .windows,
};
pub const panic = if (native_os == .windows) wintrace.panic else std.debug.FullPanic(std.debug.defaultPanic);

pub fn main(init: std.process.Init.Minimal) noreturn {
    if (native_os == .windows) {
        // wintrace reports crashes and errors (as anyzig does).
        if (wintrace.SetUnhandledExceptionFilter(&wintrace.unhandledExceptionFilter) != null) unreachable;
        var guarantee: u32 = wintrace.stack_guarantee;
        if (wintrace.SetThreadStackGuarantee(&guarantee) == 0)
            std.debug.panic("SetThreadStackGuarantee failed, error {d}", .{@intFromEnum(std.os.windows.GetLastError())});
        const code = run(init) catch |err| wintrace.exitWithErrorTrace(err, @errorReturnTrace());
        std.process.exit(code);
    } else {
        const code = run(init) catch |err| {
            std.debug.print("error: {t}\n", .{err});
            if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace);
            std.process.exit(1);
        };
        std.process.exit(code);
    }
}

fn run(init: std.process.Init.Minimal) !u8 {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer if (builtin.mode == .debug and debug_allocator.deinit() == .leak) std.debug.panic("blackbox leaked memory", .{});
    const gpa = if (builtin.mode == .debug) debug_allocator.allocator() else std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{ .environ = init.environ, .argv0 = .init(init.args) });
    defer threaded.deinit();
    const io = threaded.io();

    var args = try init.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip(); // our own exe
    const command = args.next() orelse {
        try print(io, .stderr(), usage, .{});
        return 1;
    };
    if (std.mem.eql(u8, command, "recover")) {
        const dir = args.next() orelse {
            try print(io, .stderr(), "blackbox recover takes the recording's folder\n\n" ++ usage, .{});
            return 1;
        };
        if (args.next() != null) {
            try print(io, .stderr(), "blackbox recover takes just the recording's folder\n\n" ++ usage, .{});
            return 1;
        }
        return recover(gpa, io, dir);
    }
    try print(io, .stderr(), "blackbox: unknown command '{s}'\n\n" ++ usage, .{command});
    return 1;
}

fn recover(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) !u8 {
    if (native_os != .windows) {
        try print(io, .stderr(), "blackbox recover: recordings are Windows only for now\n", .{});
        return 1;
    }
    record.global_gpa = gpa;
    const dir_wide = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, dir);
    defer gpa.free(dir_wide);
    var failures: std.ArrayList(record.Recording.Failure) = .empty;
    defer failures.deinit(gpa);
    const recovery = record.recover(dir_wide, &failures, gpa);
    for (failures.items) |f| try print(io, .stderr(), "{f}\n", .{f.problem});
    switch (recovery) {
        .finished => try print(io, .stdout(), "{s}: finished\n", .{dir}),
        .not_found => {
            try print(io, .stderr(), "{s}: no such folder\n", .{dir});
            return 1;
        },
        .nothing_to_recover => try print(io, .stdout(), "{s}: nothing to recover (no checkpoint or journal)\n", .{dir}),
        .busy => {
            try print(io, .stderr(), "{s}: it's being recorded or recovered right now\n", .{dir});
            return 1;
        },
        .corrupt => |c| {
            try print(io, .stderr(), "{s}: can't be recovered: {f}. Nothing was removed.\n", .{ dir, c });
            return 1;
        },
    }
    return if (failures.items.len == 0) 0 else 1;
}

/// Prints to stdout or stderr. A failed write is the file's own error (WriteFailed only
/// says that one happened).
fn print(io: std.Io, file: std.Io.File, comptime fmt: []const u8, args: anytype) std.Io.File.Writer.Error!void {
    var buf: [1024]u8 = undefined;
    var file_writer = file.writerStreaming(io, &buf);
    file_writer.interface.print(fmt, args) catch return file_writer.err.?;
    file_writer.interface.flush() catch return file_writer.err.?;
}

const builtin = @import("builtin");
const native_os = builtin.os.tag;
const std = @import("std");
const wintrace = @import("wintrace");
const record = if (native_os == .windows) @import("record.zig") else struct {};
