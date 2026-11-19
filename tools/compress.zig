//! compress IN OUT: zlib, for the installer's payload.

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer if (debug_allocator.deinit() == .leak) std.debug.panic("compress leaked memory", .{});
    const gpa = debug_allocator.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{ .environ = init.environ, .argv0 = .init(init.args) });
    defer threaded.deinit();
    const io = threaded.io();

    var args = try init.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip();
    const in_path = args.next() orelse std.debug.panic("usage: compress IN OUT", .{});
    const out_path = args.next() orelse std.debug.panic("usage: compress IN OUT", .{});
    if (args.next()) |extra| std.debug.panic("compress takes IN and OUT, then got '{s}'", .{extra});

    const cwd = std.Io.Dir.cwd();
    const in = cwd.openFile(io, in_path, .{}) catch |e| std.debug.panic("opening '{s}': {t}", .{ in_path, e });
    defer in.close(io);
    const out = cwd.createFile(io, out_path, .{}) catch |e| std.debug.panic("creating '{s}': {t}", .{ out_path, e });
    defer out.close(io);

    var in_buf: [64 * 1024]u8 = undefined;
    var in_reader = in.reader(io, &in_buf);
    var out_buf: [64 * 1024]u8 = undefined;
    var out_writer = out.writer(io, &out_buf);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    compress(&in_reader.interface, &out_writer.interface, &window) catch |e| switch (e) {
        error.ReadFailed => return in_reader.err.?,
        error.WriteFailed => return out_writer.err.?,
    };
}

fn compress(in: *std.Io.Reader, out: *std.Io.Writer, window: []u8) error{ ReadFailed, WriteFailed }!void {
    var c = try std.compress.flate.Compress.init(out, window, .zlib, .best);
    _ = try in.streamRemaining(&c.writer);
    try c.finish();
    try out.flush();
}

const std = @import("std");
