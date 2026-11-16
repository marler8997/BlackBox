//! Recording, part of the Windows platform layer: a ring per source, the journal writer, and
//! the compressor that turns the journal into the final files. See journal.zig for the format.
//!
//!   capture thread ──records──▶ its ring ◀──┐
//!   capture thread ──records──▶ its ring ◀──┼── writer thread (every 50ms) ──▶ journal segments
//!                                           │                                  │
//!                                ring memory from one AudioPool                     ▼
//!       compressor thread (background priority, follows the journal) ──▶ FLAC per track
//!                                                                         (its details as tags)
//!
//! Each source writes its packets as records into its own ring and never waits or locks. The
//! writer copies each ring's new records into the journal straight from ring memory. When a
//! record doesn't fit, the source moves to a ring twice the size, linked after the old one;
//! the writer drains the old ring, then returns it to the pool. A source's ring settles at a
//! size the writer keeps up with, so memory stabilizes, and nothing is allocated per packet.
//!
//! The writer only gets data out of memory: raw, flushed every second, so a crash or a power
//! cut loses little. Compressing is slower and can wait: the compressor reads the journal back
//! behind the writer at background priority and deletes each segment once done with it. If it
//! falls behind, the backlog is on disk, not in memory.
//!
//! The folder is recoverable whenever the power goes: the compressor only reads journal the
//! writer has flushed, its checkpoints (checkpoint.bin, replaced in one step) are on the disk
//! before the journal they cover may be overwritten or deleted, and at the end the files are
//! complete on the disk before the checkpoint and journal go. A recovery finishes the files
//! from the last checkpoint and the journal after it.

/// Posted to the window when part of a recording fails, or has a problem. wparam is the
/// source id, or 0 for the recording as a whole; lparam is the *Recording (there may be one
/// being finished besides the one recording). See Recording.failure.
pub const failed_msg = win32.WM_APP + 3;
/// Posted to the window when a stopped recording's files are complete. lparam is the
/// *Recording, to destroy.
pub const finished_msg = win32.WM_APP + 4;

/// The pool's limit: how far behind the writer can fall before recording fails.
const pool_max_bytes = 256 << 20;
/// How often the writer moves rings' records to the journal.
const write_interval_ms = 50;
/// A journal chunk holds at most this much of a ring.
const chunk_max_bytes = 1 << 20;
/// The journal is flushed to the disk this often, bounding what a power cut loses.
const flush_interval_hns = 1000 * 10_000;
/// A recording's first journal file's data area. Later ones double, see journal.zig. At
/// 48 kHz stereo float, about 3 minutes of audio.
const journal_initial_capacity = 64 << 20;
/// The compressor saves where it is this often, see checkpoint. The writer may only overwrite
/// journal data before the last checkpoint, so the journal must hold about this much.
const checkpoint_interval_hns = 2000 * 10_000;

/// The audio sources being recorded, and their rings' memory: power-of-two size classes from
/// Windows' allocation granularity (usually 64 KB) up. Each ring is its own allocation, so each can go back to
/// Windows on its own: a ring returned to a class no source uses any more is released right
/// away, and otherwise at most one spare per class is kept for the next source that needs
/// that size. Only ring growth (rare) touches the pool, so a lock is enough.
const AudioPool = struct {
    /// The sources, for the writer. Added and closed from the window's thread. Pointers: the
    /// capture threads hold theirs while the list grows. A lock of its own: the writer holds
    /// it while writing, and ring growth (on capture threads) mustn't wait for the disk.
    sources_lock: Lock = .{},
    sources: std.ArrayList(*AudioPoolSource) = .empty,
    /// For classes and allocated.
    lock: Lock = .{},
    classes: [class_count]Class = @splat(.{}),
    /// Bytes allocated: in use and spare.
    allocated: u64 = 0,

    const class_count = 9;
    const spares_per_class = 1;
    var granularity: usize = 0;

    const Class = struct {
        /// Rings in use.
        in_use: u32 = 0,
        /// Spare allocations, linked through their first bytes.
        spare: ?*Spare = null,
        spare_count: u32 = 0,
    };
    const Spare = struct { next: ?*Spare };

    fn init() void {
        if (granularity != 0) return;
        var info: win32.SYSTEM_INFO = undefined;
        win32.GetSystemInfo(&info);
        granularity = info.dwAllocationGranularity;
        if (!std.math.isPowerOfTwo(granularity) or granularity < info.dwPageSize)
            std.debug.panic("unexpected allocation granularity {d} (page size {d})", .{ granularity, info.dwPageSize });
    }

    fn classSize(class: u8) usize {
        return granularity << @intCast(class);
    }

    /// Memory of `class`'s size: a spare, or newly allocated. Null at the pool's limit.
    fn get(p: *AudioPool, class: u8) ?[*]align(std.heap.page_size_min) u8 {
        p.lock.lock();
        defer p.lock.unlock();
        const c = &p.classes[class];
        if (c.spare) |s| {
            c.spare = s.next;
            c.spare_count -= 1;
            c.in_use += 1;
            return @ptrCast(@alignCast(s));
        }
        const size = classSize(class);
        if (p.allocated + size > pool_max_bytes) return null;
        const mem = win32.VirtualAlloc(null, size, .{ .COMMIT = 1, .RESERVE = 1 }, .{ .PAGE_READWRITE = 1 }) orelse
            win32.panicWin32("VirtualAlloc(recording ring)", win32.GetLastError());
        p.allocated += size;
        c.in_use += 1;
        return @ptrCast(@alignCast(mem));
    }

    fn put(p: *AudioPool, class: u8, mem: [*]align(std.heap.page_size_min) u8) void {
        p.lock.lock();
        defer p.lock.unlock();
        const c = &p.classes[class];
        c.in_use -= 1;
        if (c.in_use > 0 and c.spare_count < spares_per_class) {
            const s: *Spare = @ptrCast(mem);
            s.* = .{ .next = c.spare };
            c.spare = s;
            c.spare_count += 1;
            return;
        }
        release(p, class, mem);
    }

    fn release(p: *AudioPool, class: u8, mem: *anyopaque) void {
        if (0 == win32.VirtualFree(mem, 0, .RELEASE)) win32.panicWin32("VirtualFree(recording ring)", win32.GetLastError());
        p.allocated -= classSize(class);
    }

    /// Every source must be gone and every ring back.
    fn deinit(p: *AudioPool, gpa: std.mem.Allocator) void {
        std.debug.assert(p.sources.items.len == 0);
        p.sources.deinit(gpa);
        for (&p.classes, 0..) |*c, class| {
            if (c.in_use != 0) std.debug.panic("{d} recording rings of class {d} weren't returned", .{ c.in_use, class });
            while (c.spare) |s| {
                c.spare = s.next;
                release(p, @intCast(class), s);
            }
        }
        std.debug.assert(p.allocated == 0);
    }
};

/// A source's ring: this header at the start of a pool allocation, then the data. The source
/// writes records (journal.Record and its samples) and advances `written`; the writer copies
/// them to the journal and advances `read`. Records may wrap around the end.
const Ring = struct {
    class: u8,
    /// Set by the source when it moved to a bigger ring: once this one is drained, the writer
    /// returns it to the pool and carries on with `next`.
    next: std.atomic.Value(?*Ring) = .init(null),
    /// Bytes ever written and read. Their difference is what the ring holds.
    written: std.atomic.Value(u64) = .init(0),
    read: std.atomic.Value(u64) = .init(0),

    const header_size = 64;
    comptime {
        std.debug.assert(@sizeOf(Ring) <= header_size);
    }

    fn create(pool: *AudioPool, class: u8) ?*Ring {
        const mem = pool.get(class) orelse return null;
        const r: *Ring = @ptrCast(mem);
        r.* = .{ .class = class };
        return r;
    }

    fn destroy(r: *Ring, pool: *AudioPool) void {
        pool.put(r.class, @ptrCast(@alignCast(r)));
    }

    fn data(r: *Ring) [*]u8 {
        return @as([*]u8, @ptrCast(r)) + header_size;
    }

    fn capacity(r: *const Ring) usize {
        return AudioPool.classSize(r.class) - header_size;
    }

    /// The bytes at [offset, offset + len), in up to two pieces where they wrap.
    fn pieces(r: *Ring, offset: u64, len: usize) [2][]const u8 {
        const cap = r.capacity();
        const start: usize = @intCast(offset % cap);
        const first = @min(len, cap - start);
        return .{ r.data()[start..][0..first], r.data()[0 .. len - first] };
    }

    fn copyOut(r: *Ring, offset: u64, out: []u8) void {
        const p = r.pieces(offset, out.len);
        @memcpy(out[0..p[0].len], p[0]);
        @memcpy(out[p[0].len..], p[1]);
    }

    fn copyIn(r: *Ring, offset: u64, bytes: []const u8) void {
        const cap = r.capacity();
        const start: usize = @intCast(offset % cap);
        const first = @min(bytes.len, cap - start);
        @memcpy(r.data()[start..][0..first], bytes[0..first]);
        @memcpy(r.data()[0 .. bytes.len - first], bytes[first..]);
    }
};

/// Track details for the journal (journal.TrackStart).
pub const TrackInfo = struct {
    input: Input,
    /// Windows' id for the device: adding the same device again continues its file.
    device_id: []const u8,
    device_name: []const u8,
    device_format: ?bb.AudioFormat,
    raw: bool,
};

/// The samples a capture pushes, in Windows' format.
pub const Input = struct {
    sample: wasapi.SampleType,
    channels: u8,
    rate: u32,
    /// Bytes per frame.
    block_align: u16,
};

/// What's wrong with a recording, as data. format renders it, at whatever length the place
/// showing it allows: the window cuts it to fit its top bar, a file's ERROR tag or a console
/// takes it whole.
pub const Problem = union(enum) {
    // The recording stops:
    /// The writer fell behind and no more ring memory could be had.
    out_of_memory,
    /// The writer fell behind past what a ring can hold.
    disk_too_slow,
    disk_full,
    /// Writing, or flushing, the journal failed (a Windows error).
    journal_write: u32,
    journal_flush: u32,
    /// Making the next journal file failed.
    next_journal: anyerror,
    // The recording carries on:
    /// Saving progress (checkpoint.bin) failed: the journal grows until it works.
    checkpoint_save: u32,
    /// A file that's done with couldn't be deleted (a recovery can tidy it up).
    delete_file: struct { file: DoneFile, err: u32 },
    // A track:
    track_file: FileProblem,
    // The journal or checkpoint isn't as the compressor wrote it.
    corrupt: Corruption,

    pub const DoneFile = union(enum) { checkpoint, checkpoint_tmp, journal: u32, journal_list };

    pub fn format(p: Problem, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (p) {
            .out_of_memory => try w.writeAll("Recording stopped: out of recording memory"),
            .disk_too_slow => try w.writeAll("Recording stopped: the disk couldn't keep up"),
            .disk_full => try w.writeAll("Recording stopped: the disk is full"),
            .journal_write => |err| try w.print("Recording stopped: writing the journal failed, error {d}", .{err}),
            .journal_flush => |err| try w.print("Recording stopped: flushing the journal failed, error {d}", .{err}),
            .next_journal => |err| try w.print("Recording stopped: creating the next journal file failed: {t}", .{err}),
            .checkpoint_save => |err| try w.print("Saving the recording's progress failed, error {d}", .{err}),
            .delete_file => |d| switch (d.file) {
                .checkpoint => try w.print("Deleting checkpoint.bin failed, error {d}", .{d.err}),
                .checkpoint_tmp => try w.print("Deleting checkpoint.tmp failed, error {d}", .{d.err}),
                .journal => |i| try w.print("Deleting journal file {d} failed, error {d}", .{ i, d.err }),
                .journal_list => try w.print("Listing the journal files failed, error {d}", .{d.err}),
            },
            .track_file => |f| try f.format(w),
            .corrupt => |c| try w.print("Recording stopped: {f}", .{c}),
        }
    }
};

/// A track's file couldn't be made, written, finished or recovered. Small and plain: it's
/// kept with the track in checkpoint.bin.
pub const FileProblem = struct {
    action: Action,
    /// The Windows error.
    err: u32,

    pub const Action = enum(u8) { create = 1, write, finish, recover };

    pub fn format(f: FileProblem, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (f.err == @backingInt(win32.ERROR_DISK_FULL) or f.err == @backingInt(win32.ERROR_HANDLE_DISK_FULL))
            return w.writeAll("Writing the recording file failed: the disk is full");
        try w.print("{s} the recording file failed, error {d}", .{ switch (f.action) {
            .create => "Creating",
            .write => "Writing",
            .finish => "Finishing",
            .recover => "Recovering",
        }, f.err });
    }
};

/// How the journal or checkpoint isn't as the compressor wrote it (see Corrupt): damage, or
/// files that aren't a recording's.
pub const Corruption = union(enum) {
    checkpoint_open: u32,
    checkpoint_read: u32,
    checkpoint_short,
    checkpoint_crc,
    checkpoint_version: struct { magic: u32, version: u32 },
    checkpoint_failure: struct { track: u32 },
    checkpoint_staged: struct { track: u32, staged: u32 },
    checkpoint_timing: struct { track: u32 },
    journal_open: struct { file: u32, err: u32 },
    journal_header: struct { file: u32 },
    journal_damaged: struct { file: u32, at: u64, chunk: u64, expected: u64 },
    journal_crc: struct { file: u32, chunk: u64 },
    journal_read: struct { file: u32, err: u32 },
    journal_short: struct { file: u32, at: u64 },
    packet_missing: struct { track: u32, frame: u64, chunk: u64 },
    packet_mismatch: struct { track: u32, chunk: u64, record: u32 },
    audio_after_end: struct { track: u32 },
    unknown_chunk: struct { kind: u8 },
    unknown_track: struct { track: u32 },
    record_cut,
    record_size: struct { track: u32, bytes: u32, frames: u32 },
    track_start_size: struct { track: u32, bytes: u32 },
    track_format: struct { track: u32, sample: u8, channels: u8, rate: u32, block_align: u16 },
    track_names: struct { track: u32 },
    track_reuse: struct { track: u32 },

    pub fn format(c: Corruption, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (c) {
            .checkpoint_open => |err| try w.print("opening checkpoint.bin failed, error {d}", .{err}),
            .checkpoint_read => |err| try w.print("reading checkpoint.bin failed, error {d}", .{err}),
            .checkpoint_short => try w.writeAll("checkpoint.bin is cut short"),
            .checkpoint_crc => try w.writeAll("checkpoint.bin is damaged (its checksum doesn't match)"),
            .checkpoint_version => |v| try w.print("checkpoint.bin isn't a version {d} checkpoint (magic 0x{X}, version {d})", .{ checkpoint_version, v.magic, v.version }),
            .checkpoint_failure => |t| try w.print("checkpoint.bin: track {d}'s failure isn't one", .{t.track}),
            .checkpoint_staged => |t| try w.print("checkpoint.bin: track {d} has {d} staged samples, more than a block", .{ t.track, t.staged }),
            .checkpoint_timing => |t| try w.print("checkpoint.bin: track {d}'s timing state doesn't fit it", .{t.track}),
            .journal_open => |j| try w.print("opening journal file {d} failed, error {d}", .{ j.file, j.err }),
            .journal_header => |j| try w.print("journal file {d} has a bad header", .{j.file}),
            .journal_damaged => |j| try w.print("journal file {d} is damaged at {d}: chunk {d} where {d} should be", .{ j.file, j.at, j.chunk, j.expected }),
            .journal_crc => |j| try w.print("journal file {d}: chunk {d} fails its CRC", .{ j.file, j.chunk }),
            .journal_read => |j| try w.print("reading journal file {d} failed, error {d}", .{ j.file, j.err }),
            .journal_short => |j| try w.print("journal file {d} ends at {d}, inside a chunk", .{ j.file, j.at }),
            .packet_missing => |p| try w.print("track {d}'s packet at frame {d} (journal chunk {d}) isn't in the journal", .{ p.track, p.frame, p.chunk }),
            .packet_mismatch => |p| try w.print("track {d}: journal chunk {d} record {d} isn't the packet the checkpoint says", .{ p.track, p.chunk, p.record }),
            .audio_after_end => |t| try w.print("journal: audio for track {d} after it ended", .{t.track}),
            .unknown_chunk => |k| try w.print("journal: unknown chunk kind {d}", .{k.kind}),
            .unknown_track => |t| try w.print("journal: a chunk for track {d}, which never started", .{t.track}),
            .record_cut => try w.writeAll("journal: an audio record runs past its chunk"),
            .record_size => |r| try w.print("journal: track {d} has an audio record of {d} bytes for {d} frames", .{ r.track, r.bytes, r.frames }),
            .track_start_size => |t| try w.print("journal: track {d}'s start is {d} bytes", .{ t.track, t.bytes }),
            .track_format => |t| try w.print("track {d} has sample type {d}, {d} channels at {d} Hz, {d} bytes a frame", .{ t.track, t.sample, t.channels, t.rate, t.block_align }),
            .track_names => |t| try w.print("track {d}'s device or file name isn't one", .{t.track}),
            .track_reuse => |t| try w.print("journal: track {d} carries on a file that isn't an ended track of its format", .{t.track}),
        }
    }
};

pub const Recording = struct {
    /// Everything the recording allocates. Its own allocator in debug builds, so a leak
    /// shows when the recording is destroyed instead of when the program exits.
    debug_allocator: std.heap.DebugAllocator(.{}) = .init,
    /// Where failed_msg and finished_msg go. Null in tests, which drive a recording directly.
    hwnd: ?win32.HWND,
    /// The recording's folder: its journal segments while recording (each deleted once
    /// compressed), and the final files.
    dir: [:0]const u16,
    /// When it started: local time (in the folder names and the files' tags) and QPC in 100ns
    /// units, WASAPI's timestamps' unit.
    started: win32.SYSTEMTIME,
    start_qpc: u64,
    pool: AudioPool = .{},
    stop_event: win32.HANDLE,
    stopping: std.atomic.Value(bool) = .init(false),
    /// Not while recovering: there's no writer.
    writer_thread: ?std.Thread = null,
    compressor_event: win32.HANDLE,
    compressor_thread: std.Thread = undefined,
    /// The writer's progress, for the compressor: the journal file it's writing (high 24 bits)
    /// and the bytes ever written to its data area (low 40), always at a chunk boundary. Only
    /// what's flushed to the disk (see flushSegment): the compressor's checkpoints must never
    /// be ahead of the journal on the disk, or a power cut would leave a checkpoint whose
    /// packets recovery can't find.
    progress: std.atomic.Value(u64) = .init(0),
    /// The compressor's last checkpoint, for the writer: the journal file and the bytes of its
    /// data area before it. The writer may overwrite those: recovery doesn't need them.
    compressor_progress: std.atomic.Value(u64) = .init(0),
    /// Finishing the files of a recording a crash interrupted: there's no writer, and the
    /// journal ends at its first chunk that doesn't check out.
    recovering: bool = false,
    /// Held while the recording is being written or finished, so a recovery (in another Black
    /// Box, or after a crash) only takes recordings nobody is working on. Deleted on close.
    lock_file: win32.HANDLE,
    /// The writer is done, recording_end written or not (it isn't after a write failed).
    writer_exited: std.atomic.Value(bool) = .init(false),

    // The window's thread only.
    /// Tracks added, for unique file names and adding each source once.
    added: std.ArrayList(Added) = .empty,

    // The writer only.
    /// The journal file being written.
    segment: win32.HANDLE,
    segment_index: u32 = 0,
    /// Its data area's size.
    segment_capacity: u64 = journal_initial_capacity,
    /// Bytes ever written to its data area: the next chunk goes there, modulo the capacity.
    segment_written: u64 = 0,
    /// The next chunk's journal_seq.
    journal_seq: u64 = 0,
    last_flush_qpc: u64 = 0,
    /// The journal on the disk, as progress encodes it: what a power cut leaves.
    flushed: u64 = 0,
    write_failed: bool = false,

    failures_lock: Lock = .{},
    failures: std.ArrayList(Failure) = .empty,

    /// A failure (fail) or a problem (warn), see failure.
    pub const Failure = struct {
        /// The track's source, or 0 for the recording as a whole.
        id: u32,
        problem: Problem,
        /// The track, or (id 0) the recording, stopped. Otherwise it's carrying on.
        stops: bool,
    };

    /// A track added to the recording: its file, and what it was recorded from.
    const Added = struct {
        /// The source recording to the file now, or last.
        id: u32,
        file_name: []const u8,
        device_id: []const u8,
        input: Input,
        /// Its source is gone: the same device added again carries on in this file.
        closed: bool = false,
    };

    fn allocator(r: *Recording) std.mem.Allocator {
        return if (builtin.mode == .debug) r.debug_allocator.allocator() else global_gpa;
    }

    /// Creates the recording's folder in `rec_dir` and starts its threads. Returns why it
    /// couldn't, for the user.
    pub fn create(hwnd: win32.HWND, rec_dir: []const u16) union(enum) { ok: *Recording, failed: bb.Message } {
        AudioPool.init();
        const r = global_gpa.create(Recording) catch @panic("out of memory");
        r.* = .{
            .hwnd = hwnd,
            .dir = undefined,
            .started = undefined,
            .start_qpc = qpc100ns(),
            .stop_event = win32.CreateEventW(null, 1, 0, null) orelse win32.panicWin32("CreateEvent", win32.GetLastError()),
            .compressor_event = win32.CreateEventW(null, 0, 0, null) orelse win32.panicWin32("CreateEvent", win32.GetLastError()),
            .segment = undefined,
            .lock_file = undefined,
        };
        win32.GetLocalTime(&r.started);
        const fail_message: bb.Message = blk: {
            r.dir = createDir(r.allocator(), rec_dir, r.started) catch |e|
                break :blk .init("Couldn't create a folder for the recording: {t}", .{e});
            r.lock_file = lockRecording(r.dir) orelse {
                // Before anything else can change it.
                const err = win32.GetLastError();
                removeEmptyDir(r.dir);
                r.allocator().free(r.dir);
                break :blk .init("Couldn't lock the recording's folder, error {d}", .{@backingInt(err)});
            };
            r.segment = r.openSegment(0, journal_initial_capacity, 0) catch |e| {
                // The lock file goes with its handle, leaving the folder empty.
                win32.closeHandle(r.lock_file);
                removeEmptyDir(r.dir);
                r.allocator().free(r.dir);
                break :blk .init("Couldn't create the recording's journal: {t}", .{e});
            };
            r.writer_thread = std.Thread.spawn(.{}, writerMain, .{r}) catch |e| std.debug.panic("spawning the recording writer failed: {t}", .{e});
            r.compressor_thread = std.Thread.spawn(.{}, compressorMain, .{r}) catch |e| std.debug.panic("spawning the recording compressor failed: {t}", .{e});
            return .{ .ok = r };
        };
        win32.closeHandle(r.stop_event);
        win32.closeHandle(r.compressor_event);
        if (builtin.mode == .debug) _ = r.debug_allocator.deinit();
        global_gpa.destroy(r);
        return .{ .failed = fail_message };
    }

    /// From the window's thread: a writer for a source's track, or null if the source was
    /// already added to this recording (each is recorded once), or its ring couldn't be had.
    pub fn addTrack(r: *Recording, id: u32, info: TrackInfo) ?*AudioPoolSource {
        for (r.added.items) |a| if (a.id == id and !a.closed) return null;
        const gpa = r.allocator();
        // The same device with the same format, added again: the compressor carries its file
        // on, with silence for the time it was gone.
        const file_name = for (r.added.items) |*a| {
            if (a.closed and std.mem.eql(u8, a.device_id, info.device_id) and std.meta.eql(a.input, info.input)) {
                a.id = id;
                a.closed = false;
                break a.file_name;
            }
        } else blk: {
            const name = r.uniqueFileName(info.device_name);
            r.added.append(gpa, .{
                .id = id,
                .file_name = name,
                .device_id = gpa.dupe(u8, info.device_id) catch @panic("out of memory"),
                .input = info.input,
            }) catch @panic("out of memory");
            break :blk name;
        };
        const ring = Ring.create(&r.pool, 0) orelse {
            // Not started after all: the entry is free for the source to try again later, or
            // for the device's next track.
            for (r.added.items) |*a| if (a.id == id) {
                a.closed = true;
            };
            r.fail(id, .out_of_memory);
            return null;
        };
        const tw = gpa.create(AudioPoolSource) catch @panic("out of memory");
        tw.* = .{
            .recording = r,
            .id = id,
            .info = info,
            .device_name = gpa.dupe(u8, info.device_name) catch @panic("out of memory"),
            .file_name = file_name,
            .ring = ring,
            .writer_ring = ring,
            .ring_capacity = .init(ring.capacity()),
        };
        tw.info.device_name = tw.device_name;
        // The window's; only needed above.
        tw.info.device_id = "";
        r.pool.sources_lock.lock();
        defer r.pool.sources_lock.unlock();
        r.pool.sources.append(gpa, tw) catch @panic("out of memory");
        return tw;
    }

    /// From the window's thread, after every track was closed: the writer finishes the
    /// journal and exits. The compressor carries on until the files are complete, then posts
    /// finished_msg.
    pub fn stop(r: *Recording) void {
        r.stopping.store(true, .release);
        if (0 == win32.SetEvent(r.stop_event)) win32.panicWin32("SetEvent", win32.GetLastError());
    }

    /// From the window's thread, after finished_msg (or to wait for it). `checkLeaks` checks
    /// the recording's allocator in debug builds.
    pub fn destroy(r: *Recording, comptime checkLeaks: fn (*std.heap.DebugAllocator(.{})) void) void {
        // The compressor joins the writer before it finishes.
        r.compressor_thread.join();
        win32.closeHandle(r.lock_file);
        win32.closeHandle(r.stop_event);
        win32.closeHandle(r.compressor_event);
        const gpa = r.allocator();
        r.pool.deinit(gpa);
        for (r.added.items) |a| {
            gpa.free(a.file_name);
            gpa.free(a.device_id);
        }
        r.added.deinit(gpa);
        r.failures.deinit(gpa);
        gpa.free(r.dir);
        if (builtin.mode == .debug) checkLeaks(&r.debug_allocator);
        global_gpa.destroy(r);
    }

    /// The latest failure for a source (or 0, the whole recording), for the window's thread
    /// after failed_msg.
    pub fn failure(r: *Recording, id: u32) ?Failure {
        r.failures_lock.lock();
        defer r.failures_lock.unlock();
        var i = r.failures.items.len;
        while (i > 0) {
            i -= 1;
            if (r.failures.items[i].id == id) return r.failures.items[i];
        }
        return null;
    }

    /// Something stopped: the track (or with id 0, the recording).
    fn fail(r: *Recording, id: u32, problem: Problem) void {
        r.report(.{ .id = id, .problem = problem, .stops = true });
    }

    /// A problem with the recording that stops nothing.
    fn warn(r: *Recording, problem: Problem) void {
        r.report(.{ .id = 0, .problem = problem, .stops = false });
    }

    fn report(r: *Recording, f: Failure) void {
        {
            r.failures_lock.lock();
            defer r.failures_lock.unlock();
            r.failures.append(r.allocator(), f) catch @panic("out of memory");
        }
        // Which recording: there may be one being finished besides the one being recorded.
        if (r.hwnd) |hwnd| if (0 == win32.PostMessageW(hwnd, failed_msg, f.id, @bitCast(@intFromPtr(r))))
            win32.panicWin32("PostMessage(recording failed)", win32.GetLastError());
    }

    /// The source's name made safe for a file name, with ".flac", unique in the recording.
    /// Allocated.
    fn uniqueFileName(r: *Recording, name: []const u8) []const u8 {
        var safe_buf: [128]u8 = undefined;
        const cut = truncateUtf8(name, safe_buf.len);
        for (safe_buf[0..cut.len], cut) |*o, ch| o.* = switch (ch) {
            0...31, '<', '>', ':', '"', '/', '\\', '|', '?', '*' => '_',
            else => ch,
        };
        // Windows drops trailing dots and spaces from file names.
        const base = std.mem.trimEnd(u8, safe_buf[0..cut.len], ". ");
        var n: u32 = 1;
        while (true) : (n += 1) {
            var candidate_buf: [safe_buf.len + 32]u8 = undefined;
            const candidate = if (n == 1)
                std.fmt.bufPrint(&candidate_buf, "{s}.flac", .{base}) catch unreachable
            else
                std.fmt.bufPrint(&candidate_buf, "{s} ({d}).flac", .{ base, n }) catch unreachable;
            const taken = for (r.added.items) |a| {
                if (std.ascii.eqlIgnoreCase(a.file_name, candidate)) break true;
            } else false;
            if (!taken) return r.allocator().dupe(u8, candidate) catch @panic("out of memory");
        }
    }

    fn segmentPath(r: *Recording, buf: *PathBuf, index: u32) [:0]const u16 {
        var name_buf: [32]u8 = undefined;
        return joinPath(buf, r.dir, std.fmt.bufPrint(&name_buf, "journal-{d:0>6}.bbj", .{index}) catch unreachable);
    }

    /// Creates journal file `index` with its header, its data area allocated up front: the
    /// file doesn't grow (or fragment) as it's written.
    fn openSegment(r: *Recording, index: u32, capacity: u64, first_seq: u64) error{ AccessDenied, DiskFull, Unexpected }!win32.HANDLE {
        var path_buf: PathBuf = undefined;
        const path = r.segmentPath(&path_buf, index);
        // Shared for the compressor to read and delete.
        const h = win32.CreateFileW(path, .{ .FILE_WRITE_DATA = 1 }, .{ .READ = 1, .WRITE = 1, .DELETE = 1 }, null, .CREATE_NEW, .{ .FILE_ATTRIBUTE_NORMAL = 1 }, null);
        if (h == win32.INVALID_HANDLE_VALUE) return fileError();
        errdefer {
            win32.closeHandle(h);
            _ = win32.DeleteFileW(path);
        }
        const header: journal.FileHeader = .{
            .index = index,
            .capacity = capacity,
            .first_seq = first_seq,
            .start_qpc = r.start_qpc,
            .started = timeWords(r.started),
        };
        if (!writeAt(h, 0, std.mem.asBytes(&header))) return fileError();
        if (0 == win32.SetFilePointerEx(h, .{ .QuadPart = @intCast(journal.FileHeader.data_start + capacity) }, null, win32.FILE_BEGIN) or
            0 == win32.SetEndOfFile(h)) return fileError();
        return h;
    }
};

/// An audio source being recorded, one of AudioPool.sources. The capture thread pushes packets into its ring (push);
/// the writer takes them from the ring it's reading (writer_ring, which trails `ring` while an
/// outgrown ring is drained). Closed from the window's thread, then finished and freed by the
/// writer.
pub const AudioPoolSource = struct {
    recording: *Recording,
    id: u32,
    info: TrackInfo,
    device_name: []const u8,
    file_name: []const u8,
    /// The ring the source writes to. The capture thread only.
    ring: *Ring,
    /// `ring`'s capacity, for the window's thread (debug info).
    ring_capacity: std.atomic.Value(usize),
    failed: bool = false,
    /// The ring the writer reads from. The writer only.
    writer_ring: *Ring,
    /// Set when the capture no longer pushes: the writer drains the ring, ends the track and
    /// frees it.
    closed: std.atomic.Value(bool) = .init(false),
    // The writer only.
    started: bool = false,
    seq: u32 = 0,

    /// From the capture thread: a packet of `frames` frames, `bytes` in Input's format, or null
    /// for silence. `device_position`, `qpc` and `flags` (silent aside) are from GetBuffer.
    pub fn push(tw: *AudioPoolSource, bytes: ?[]const u8, frames: u32, device_position: u64, qpc: u64, flags: journal.RecordFlags) void {
        if (tw.failed) return;
        const len: u32 = if (bytes) |b| @intCast(b.len) else 0;
        const record: journal.Record = .{
            .frames = frames,
            .flags = .{ .silent = bytes == null, .timestamp_error = flags.timestamp_error, .discontinuity = flags.discontinuity },
            .len = len,
            .first_frame = device_position,
            .capture_qpc = qpc,
        };
        const need = @sizeOf(journal.Record) + len;
        var ring = tw.ring;
        var written = ring.written.raw;
        if (ring.capacity() - (written - ring.read.load(.acquire)) < need) {
            // The writer is behind: a ring twice the size (or more, until the record fits),
            // linked after this one for the writer to carry on with.
            var class = ring.class + 1;
            while (class < AudioPool.class_count and AudioPool.classSize(class) - Ring.header_size < need) class += 1;
            const bigger = if (class < AudioPool.class_count) Ring.create(&tw.recording.pool, class) else null;
            ring = bigger orelse {
                tw.failed = true;
                tw.recording.fail(tw.id, .disk_too_slow);
                return;
            };
            tw.ring.next.store(ring, .release);
            tw.ring = ring;
            tw.ring_capacity.store(ring.capacity(), .monotonic);
            written = 0;
        }
        ring.copyIn(written, std.mem.asBytes(&record));
        if (bytes) |b| ring.copyIn(written + @sizeOf(journal.Record), b);
        ring.written.store(written + need, .release);
    }

    /// From the window's thread (debug info): the ring's size and the audio it holds.
    pub fn buffer(tw: *AudioPoolSource) bb.Buffer {
        const capacity = tw.ring_capacity.load(.monotonic);
        const per_second = @as(u64, tw.info.input.rate) * tw.info.input.block_align;
        // The allocation's size; the audio it holds is less its header.
        return .{ .bytes = capacity + Ring.header_size, .ms = @intCast(capacity * 1000 / per_second) };
    }

    /// From the window's thread, after the capture stopped pushing. The writer ends the track
    /// and frees the writer: don't use it after this.
    pub fn close(tw: *AudioPoolSource) void {
        for (tw.recording.added.items) |*a| if (a.id == tw.id) {
            a.closed = true;
        };
        tw.closed.store(true, .release);
    }
};

// ---------------------------------------------------------------------------
// Writer
// ---------------------------------------------------------------------------

fn writerMain(r: *Recording) void {
    var guarantee: u32 = wintrace.stack_guarantee;
    if (0 == wintrace.SetThreadStackGuarantee(&guarantee)) win32.panicWin32("SetThreadStackGuarantee", win32.GetLastError());
    // Above whatever else is busy (a game's threads): if this falls behind, the capture rings
    // fill and audio is lost. It mostly waits on the disk, so it costs little. Still below
    // the capture threads (MMCSS), which must never wait for it.
    if (0 == win32.SetThreadPriority(win32.GetCurrentThread(), win32.THREAD_PRIORITY_HIGHEST))
        win32.panicWin32("SetThreadPriority(writer)", win32.GetLastError());
    r.last_flush_qpc = qpc100ns();
    const gpa = r.allocator();
    // The sources, copied out of the pool's list each pass: the disk work is done without its
    // lock, so the window adding a track never waits on the disk (a write, or a new journal
    // file being made). Only this thread removes and frees sources, so the copies stay good.
    var sources: std.ArrayList(*AudioPoolSource) = .empty;
    defer sources.deinit(gpa);
    while (true) {
        // Read before draining: stop comes after every track was closed, so once it's seen,
        // this pass finishes every track.
        const stopping = r.stopping.load(.acquire);
        var wrote = false;
        {
            r.pool.sources_lock.lock();
            defer r.pool.sources_lock.unlock();
            sources.clearRetainingCapacity();
            sources.appendSlice(gpa, r.pool.sources.items) catch @panic("out of memory");
        }
        for (sources.items) |tw| {
            // Read before draining: once closed, nothing more comes.
            const closed = tw.closed.load(.acquire);
            if (!tw.started) {
                writeTrackStart(r, tw);
                tw.started = true;
                wrote = true;
            }
            wrote = drain(r, tw) or wrote;
            if (closed) {
                writeChunk(r, .{ .len = 0, .track = tw.id, .seq = tw.seq, .kind = .track_end, .capture_qpc = qpc100ns() }, &.{});
                {
                    r.pool.sources_lock.lock();
                    defer r.pool.sources_lock.unlock();
                    const i = std.mem.indexOfScalar(*AudioPoolSource, r.pool.sources.items, tw).?;
                    _ = r.pool.sources.orderedRemove(i);
                }
                tw.writer_ring.destroy(&r.pool);
                gpa.free(tw.device_name);
                gpa.destroy(tw);
                wrote = true;
            }
        }
        if (stopping) {
            if (std.debug.runtime_safety) {
                r.pool.sources_lock.lock();
                defer r.pool.sources_lock.unlock();
                std.debug.assert(r.pool.sources.items.len == 0);
            }
            writeChunk(r, .{ .len = 0, .track = 0, .seq = 0, .kind = .recording_end, .capture_qpc = qpc100ns() }, &.{});
            wrote = true;
        }
        if (wrote) {
            if (0 == win32.SetEvent(r.compressor_event)) win32.panicWin32("SetEvent", win32.GetLastError());
        }
        const now = qpc100ns();
        if (stopping or now -| r.last_flush_qpc >= flush_interval_hns) {
            r.last_flush_qpc = now;
            flushSegment(r);
        }
        if (stopping) break;
        switch (@backingInt(win32.WaitForSingleObject(r.stop_event, write_interval_ms))) {
            0, @backingInt(win32.WAIT_TIMEOUT) => {},
            else => win32.panicWin32("WaitForSingleObject", win32.GetLastError()),
        }
    }
    win32.closeHandle(r.segment);
    r.writer_exited.store(true, .release);
    if (0 == win32.SetEvent(r.compressor_event)) win32.panicWin32("SetEvent", win32.GetLastError());
}

fn writeTrackStart(r: *Recording, tw: *AudioPoolSource) void {
    const info = tw.info;
    const df = info.device_format;
    const name = truncateUtf8(info.device_name, 1024);
    const start: journal.TrackStart = .{
        .sample = switch (info.input.sample) {
            .f32 => .f32,
            .i16 => .i16,
            .i24 => .i24,
            .i32 => .i32,
        },
        .channels = info.input.channels,
        .block_align = info.input.block_align,
        .rate = info.input.rate,
        .device_format_known = @intFromBool(df != null),
        .device_sample = if (df) |d| @backingInt(d.sample) else 0,
        .device_bits = if (df) |d| d.bits else 0,
        .device_rate = if (df) |d| d.rate else 0,
        .device_channels = if (df) |d| d.channels else 0,
        .raw = @intFromBool(info.raw),
        .device_name_len = @intCast(name.len),
        .file_name_len = @intCast(tw.file_name.len),
    };
    const payload = [_][]const u8{ std.mem.asBytes(&start), name, tw.file_name };
    var len: u32 = 0;
    for (payload) |p| len += @intCast(p.len);
    writeChunk(r, .{ .len = len, .track = tw.id, .seq = tw.seq, .kind = .track_start, .capture_qpc = qpc100ns() }, &payload);
    tw.seq += 1;
}

/// Writes the track's new records to the journal, in chunks of whole records, and moves past
/// outgrown rings. Returns whether it wrote anything.
fn drain(r: *Recording, tw: *AudioPoolSource) bool {
    var wrote = false;
    while (true) {
        const ring = tw.writer_ring;
        // `next` before `written`: if the source moved on, everything it wrote here is seen.
        const next = ring.next.load(.acquire);
        const written = ring.written.load(.acquire);
        var read = ring.read.raw;
        while (read < written) {
            // As many whole records as fit in a chunk (at least one).
            var end = read;
            var frames: u64 = 0;
            var first: journal.Record = undefined;
            while (end < written) {
                var record: journal.Record = undefined;
                ring.copyOut(end, std.mem.asBytes(&record));
                const len = @sizeOf(journal.Record) + record.len;
                if (end > read and end - read + len > chunk_max_bytes) break;
                if (end == read) first = record;
                frames += record.frames;
                end += len;
            }
            const p = ring.pieces(read, @intCast(end - read));
            writeChunk(r, .{
                .len = @intCast(end - read),
                .track = tw.id,
                .seq = tw.seq,
                .kind = .audio,
                .frames = @intCast(frames),
                .first_frame = first.first_frame,
                .capture_qpc = first.capture_qpc,
            }, &p);
            tw.seq += 1;
            read = end;
            ring.read.store(read, .release);
            wrote = true;
        }
        const outgrown = next orelse return wrote;
        ring.destroy(&r.pool);
        tw.writer_ring = outgrown;
    }
}

/// Writes a chunk (`header` and its payload pieces) to the journal: wrapping around the data
/// area, or continuing in a new file twice the size when it would overwrite what the
/// compressor hasn't read.
fn writeChunk(r: *Recording, header: journal.Header, payload: []const []const u8) void {
    if (r.write_failed) return;
    const size = header.size();
    while (true) {
        // The chunk doesn't straddle the end: padding takes the rest first if it doesn't fit.
        const at = r.segment_written % r.segment_capacity;
        const pad = if (at + size > r.segment_capacity) r.segment_capacity - at else 0;
        // And room is kept after it to end the file with, should the next chunk not fit.
        if (pad + size + @sizeOf(journal.Header) <= freeSpace(r)) {
            if (pad > 0) writeRaw(r, .{ .len = @intCast(pad - @sizeOf(journal.Header)), .track = 0, .seq = 0, .kind = .padding }, &.{});
            break;
        }
        if (!nextSegment(r, size)) return;
    }
    writeRaw(r, header, payload);
}

/// The data area the compressor is done with, so free to write.
fn freeSpace(r: *Recording) u64 {
    const compressor = r.compressor_progress.load(.acquire);
    // Still on an older file, it hasn't read this one at all.
    const read = if (compressor >> 40 == r.segment_index) compressor & ((1 << 40) - 1) else 0;
    return r.segment_capacity - (r.segment_written - read);
}

/// Ends the journal file and continues in a new one at least twice the size. Returns false if
/// that failed (reported).
fn nextSegment(r: *Recording, need: u64) bool {
    writeRaw(r, .{ .len = 0, .track = 0, .seq = 0, .kind = .segment_end }, &.{});
    flushSegment(r);
    if (r.write_failed) return false;
    var capacity = r.segment_capacity * 2;
    while (capacity < need + 2 * @sizeOf(journal.Header)) capacity *= 2;
    const next = r.openSegment(r.segment_index + 1, capacity, r.journal_seq) catch |e| {
        r.write_failed = true;
        r.fail(0, .{ .next_journal = e });
        return false;
    };
    win32.closeHandle(r.segment);
    r.segment = next;
    r.segment_index += 1;
    r.segment_capacity = capacity;
    r.segment_written = 0;
    // The file has its segment_end before progress shows the next file: the compressor reads
    // up to it, then moves on.
    r.progress.store(@as(u64, r.segment_index) << 40, .release);
    return true;
}

/// Writes a chunk at the write position, which the caller made room for.
fn writeRaw(r: *Recording, header: journal.Header, payload: []const []const u8) void {
    if (r.write_failed) return;
    var h = header;
    h.journal_seq = r.journal_seq;
    h.write_qpc = qpc100ns();
    h.crc = h.computeCrc(payload);
    var offset = journal.FileHeader.data_start + r.segment_written % r.segment_capacity;
    var ok = writeAt(r.segment, offset, std.mem.asBytes(&h));
    offset += @sizeOf(journal.Header);
    for (payload) |piece| {
        ok = ok and writeAt(r.segment, offset, piece);
        offset += piece.len;
    }
    if (!ok) {
        r.write_failed = true;
        switch (win32.GetLastError()) {
            .ERROR_DISK_FULL, .ERROR_HANDLE_DISK_FULL => r.fail(0, .disk_full),
            else => |err| r.fail(0, .{ .journal_write = @backingInt(err) }),
        }
        return;
    }
    r.journal_seq += 1;
    r.segment_written += h.size();
}

/// Writes all of `bytes` at `offset`. Returns false on failure, GetLastError says why.
fn writeAt(file: win32.HANDLE, offset: u64, bytes: []const u8) bool {
    var done: usize = 0;
    while (done < bytes.len) {
        var ov: win32.OVERLAPPED = std.mem.zeroes(win32.OVERLAPPED);
        const at = offset + done;
        ov.Anonymous.Anonymous.Offset = @truncate(at);
        ov.Anonymous.Anonymous.OffsetHigh = @truncate(at >> 32);
        var n: u32 = undefined;
        if (0 == win32.WriteFile(file, bytes[done..].ptr, @intCast(bytes.len - done), &n, &ov)) return false;
        done += n;
    }
    return true;
}

/// A std.Io.Writer that writes to a file handle at its file pointer, through the caller's
/// buffer: to batch the checkpoint's many small pieces into few writes. When a write fails, `err` says why (GetLastError).
///
/// Windows has no writev for ordinary files (WriteFileGather needs unbuffered, overlapped
/// handles and whole aligned pages), so the buffer is what keeps kernel calls few: drain
/// writes out the buffer and puts what it was given back in it, writing directly only what's
/// bigger than the whole buffer. Sized past the output, everything goes in one WriteFile.
const HandleWriter = struct {
    handle: win32.HANDLE,
    err: ?win32.WIN32_ERROR = null,
    /// Of everything written.
    crc: std.hash.Crc32 = .init(),
    interface: std.Io.Writer,

    fn init(handle: win32.HANDLE, buffer: []u8) HandleWriter {
        return .{ .handle = handle, .interface = .{ .vtable = &.{ .drain = drainBuffer }, .buffer = buffer } };
    }

    fn drainBuffer(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const hw: *HandleWriter = @alignCast(@fieldParentPtr("interface", w));
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            try hw.put(d);
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            try hw.put(last);
            n += last.len;
        }
        // flush (data is one empty slice): out with what's buffered.
        if (n == 0) {
            try hw.writeAll(w.buffered());
            w.end = 0;
        }
        return n;
    }

    /// Into the buffer, writing it out first if it won't fit; straight to the file if it's
    /// bigger than the whole buffer.
    fn put(hw: *HandleWriter, bytes: []const u8) std.Io.Writer.Error!void {
        const w = &hw.interface;
        if (bytes.len > w.buffer.len - w.end) {
            try hw.writeAll(w.buffered());
            w.end = 0;
        }
        if (bytes.len > w.buffer.len) return hw.writeAll(bytes);
        @memcpy(w.buffer[w.end..][0..bytes.len], bytes);
        w.end += bytes.len;
    }

    fn writeAll(hw: *HandleWriter, bytes: []const u8) std.Io.Writer.Error!void {
        var done: usize = 0;
        while (done < bytes.len) {
            var n: u32 = undefined;
            const len: u32 = @intCast(@min(bytes.len - done, std.math.maxInt(u32)));
            if (0 == win32.WriteFile(hw.handle, bytes[done..].ptr, len, &n, null)) {
                hw.err = win32.GetLastError();
                return error.WriteFailed;
            }
            hw.crc.update(bytes[done..][0..n]);
            done += n;
        }
    }
};

fn fileError() error{ AccessDenied, DiskFull, Unexpected } {
    return switch (win32.GetLastError()) {
        .ERROR_ACCESS_DENIED => error.AccessDenied,
        .ERROR_DISK_FULL, .ERROR_HANDLE_DISK_FULL => error.DiskFull,
        else => error.Unexpected,
    };
}

/// Flushes the journal file to the disk, then lets the compressor have what was written:
/// only now can its checkpoints depend on it (see Recording.progress).
fn flushSegment(r: *Recording) void {
    if (r.write_failed) return;
    if (0 == win32.FlushFileBuffers(r.segment)) {
        r.write_failed = true;
        r.fail(0, .{ .journal_flush = @backingInt(win32.GetLastError()) });
        return;
    }
    r.flushed = @as(u64, r.segment_index) << 40 | r.segment_written;
    r.progress.store(r.flushed, .release);
}

// ---------------------------------------------------------------------------
// Compressor
// ---------------------------------------------------------------------------

/// One track's final file, being written by the compressor.
const OutTrack = struct {
    id: u32,
    start: journal.TrackStart,
    device_name: []const u8,
    file_name: []const u8,
    file: ?win32.HANDLE,
    encoder: *flac.Encoder,
    /// One block of 24-bit samples being collected for the encoder.
    samples: []i32,
    staged: usize = 0,
    out: []u8,
    out_len: usize = 0,
    /// Bytes written to the file so far.
    file_len: u64 = 0,
    /// Puts the device's audio on the recording's timeline, correcting its clock's drift.
    aligner: resample.Aligner,
    /// When its first frame with a good timestamp was captured (0: none yet).
    first_frame_qpc: u64 = 0,
    /// Output samples past full scale, clamped (the resampling filter can overshoot a
    /// little on audio already at full scale).
    clipped_samples: u64 = 0,
    /// Float samples that weren't numbers (NaN, infinite): silenced.
    invalid_samples: u64 = 0,
    failure: ?FileProblem = null,
    /// Its source is gone (for now: it may be added again, see startTrack). The file stays
    /// open until the recording ends, then is padded with silence to its end.
    ended: bool = false,
};

/// Where the aligner's output goes: 24-bit samples into the track's encoder.
const TrackSink = struct {
    c: *Compressor,
    t: *OutTrack,

    pub fn write(s: TrackSink, frames: []const f32) void {
        const t = s.t;
        const block_samples = flac.block_size * @as(usize, t.start.channels);
        var rest = frames;
        while (rest.len > 0) {
            const n = @min(rest.len, block_samples - t.staged);
            for (t.samples[t.staged..][0..n], rest[0..n]) |*o, v| {
                const x = @round(v * 8388608.0);
                const clamped = std.math.clamp(x, -8388608.0, 8388607.0);
                if (clamped != x) t.clipped_samples += 1;
                o.* = @intFromFloat(clamped);
            }
            t.staged += n;
            rest = rest[n..];
            if (t.staged == block_samples) encodeStaged(s.c, t);
        }
    }
};

const write_buffer_len = 1 << 20;

const Compressor = struct {
    recording: *Recording,
    /// The journal file being read.
    segment_index: u32 = 0,
    segment: win32.HANDLE = undefined,
    /// Its data area's size.
    capacity: u64 = 0,
    /// Bytes ever read from its data area.
    offset: u64 = 0,
    /// The next chunk's journal_seq.
    next_seq: u64 = 0,
    /// Its segment_end was read: the journal continues in the next file.
    segment_ended: bool = false,
    segment_open: bool = false,
    last_checkpoint_qpc: u64 = 0,
    /// When the recording ended, from recording_end: every track is padded to it.
    end_qpc: ?u64 = null,
    /// The last checkpoint failed (reported once, see checkpoint).
    checkpoint_failing: bool = false,
    /// What's wrong with the journal or checkpoint, once something is (see Corrupt).
    problem: ?Corruption = null,
    /// The latest write_qpc of the chunks read: when the writer last wrote.
    last_write_qpc: u64 = 0,
    /// A chunk read back, grown to the biggest one seen.
    chunk: []align(16) u8,
    kernel: *const resample.Kernel,
    tracks: std.ArrayList(OutTrack) = .empty,
    done: bool = false,
    /// The oldest journal file still kept: recovery may need it (see checkpoint).
    oldest_segment: u32 = 0,
    /// Recovering: chunks before this were processed before the crash (the checkpoint has
    /// their effect). They're read again only for the samples of the packets the tracks'
    /// aligners still had queued (see refillRecord).
    processed_seq: u64 = 0,

    fn allocator(c: *Compressor) std.mem.Allocator {
        return c.recording.allocator();
    }

    /// Says what's wrong (the first thing found), for Corrupt.
    fn corrupt(c: *Compressor, what: Corruption) error{Corrupt} {
        c.note(what);
        return error.Corrupt;
    }

    fn note(c: *Compressor, what: Corruption) void {
        if (c.problem == null) c.problem = what;
    }
};

fn compressorMain(r: *Recording) void {
    var guarantee: u32 = wintrace.stack_guarantee;
    if (0 == wintrace.SetThreadStackGuarantee(&guarantee)) win32.panicWin32("SetThreadStackGuarantee", win32.GetLastError());
    // Lower CPU, disk and memory priority: it must never compete with capturing or writing.
    if (0 == win32.SetThreadPriority(win32.GetCurrentThread(), win32.THREAD_MODE_BACKGROUND_BEGIN))
        win32.panicWin32("SetThreadPriority(background)", win32.GetLastError());

    const gpa = r.allocator();
    // 66 KB: on this thread's stack (std.Thread's default, 16 MB).
    var kernel: resample.Kernel = undefined;
    kernel.init();
    var c: Compressor = .{
        .recording = r,
        .chunk = gpa.alignedAlloc(u8, .@"16", @sizeOf(journal.Header)) catch @panic("out of memory"),
        .kernel = &kernel,
    };
    defer gpa.free(c.chunk);
    follow(&c) catch |e| switch (e) {
        error.Corrupt => {
            r.fail(0, .{ .corrupt = c.problem.? });
            abandon(&c);
        },
    };
}

/// Follows the journal as the writer writes it, then finishes the files.
fn follow(c: *Compressor) Corrupt!void {
    const r = c.recording;
    if (try startCompressor(c)) while (true) {
        const progress = r.progress.load(.acquire);
        const step = try advance(c, progress);
        if (step == .ended) break;
        const now = qpc100ns();
        if (now -| c.last_checkpoint_qpc >= checkpoint_interval_hns) {
            c.last_checkpoint_qpc = now;
            checkpoint(c);
        }
        if (step == .progressed) continue;
        // The writer exited without recording_end (it failed): everything it wrote is read.
        if (r.writer_exited.load(.acquire) and r.progress.load(.acquire) == progress) break;
        switch (@backingInt(win32.WaitForSingleObject(r.compressor_event, 100))) {
            0, @backingInt(win32.WAIT_TIMEOUT) => {},
            else => win32.panicWin32("WaitForSingleObject", win32.GetLastError()),
        }
    };
    try finish(c);
}

/// Where the compressor starts: recovering, from the last checkpoint, or the journal's start
/// if there's none. Returns whether there's a journal file to read.
fn startCompressor(c: *Compressor) Corrupt!bool {
    const resume_offset = if (c.recording.recovering) try loadCheckpoint(c) else 0;
    c.oldest_segment = c.segment_index;
    const reading = try openSegmentForReading(c, c.segment_index, resume_offset != 0);
    c.offset = resume_offset;
    c.last_checkpoint_qpc = qpc100ns();
    return reading;
}

const Step = enum {
    progressed,
    /// Everything written so far is processed.
    idle,
    /// The journal is done: recording_end, or recovering, its end.
    ended,
};

/// Processes the journal as far as the writer has written (`progress`, see
/// Recording.progress), moving on to the next journal file at a segment_end.
fn advance(c: *Compressor, progress: u64) Corrupt!Step {
    const r = c.recording;
    // The file the writer is in: up to what it has written. An earlier one: up to its
    // segment_end, all written. Recovering: until the first chunk that doesn't check out.
    const end: u64 = if (!r.recovering and progress >> 40 == c.segment_index) progress & ((1 << 40) - 1) else std.math.maxInt(u64);
    const progressed = try readChunks(c, end);
    if (c.done) return .ended;
    if (c.segment_ended) {
        // Past this file. A checkpoint at the next file's start: it goes once recovery can't
        // need it, when no aligner still has packets from it queued (see checkpoint).
        win32.closeHandle(c.segment);
        c.segment_open = false;
        c.segment_index += 1;
        c.offset = 0;
        checkpoint(c);
        return if (try openSegmentForReading(c, c.segment_index, false)) .progressed else .ended;
    }
    return if (progressed) .progressed else .idle;
}

/// The recording ended (or, recovering, its journal did): completes the files, then removes
/// what recovery would have needed. See completeFiles and removeJournal for why in that order.
fn finish(c: *Compressor) Corrupt!void {
    try completeFiles(c);
    removeJournal(c);
}

/// The files, finished and on the disk. Nothing is removed yet: until it all is, a power cut
/// leaves the checkpoint and journal to finish them again from.
fn completeFiles(c: *Compressor) Corrupt!void {
    const r = c.recording;
    if (r.writer_thread) |t| t.join();
    closeJournal(c);
    // Recovering: the packets the checkpoint had queued must all have been read again.
    for (c.tracks.items) |*t| if (t.aligner.missing()) |p|
        return c.corrupt(.{ .packet_missing = .{ .track = t.id, .frame = p.first_frame, .chunk = p.source.seq } });
    // Recovering (or after the writer failed) there's no recording_end: the end is when the
    // journal's last chunk was written (its audio was captured before).
    const end_qpc = c.end_qpc orelse c.last_write_qpc;
    for (c.tracks.items) |*t| finalizeTrack(c, t, end_qpc);
}

/// With the files complete: the checkpoint goes first, then the journal. Interrupted between
/// them, the journal alone is left, from which recovery can't touch the finished files: its
/// start is gone (deleted, or overwritten as the journal wrapped, which starts at its start),
/// so recovery finds no track; or it's whole, and recovery makes the same files again. The
/// other way round would leave a checkpoint without its journal, and recovery would cut the
/// finished files back to it.
fn removeJournal(c: *Compressor) void {
    const r = c.recording;
    deleteIfExists(r, "checkpoint.bin", .checkpoint);
    deleteIfExists(r, "checkpoint.tmp", .checkpoint_tmp);
    deleteJournalFiles(r);
    freeTracks(c);
    postFinished(r);
}

/// The compressor can't go on (Compressor.problem says why): it stops where it is and removes
/// nothing, so the checkpoint and the journal are left as they were for a recovery to finish
/// the files from. The files are left as far as they got.
fn abandon(c: *Compressor) void {
    const r = c.recording;
    // Live, the writer stops when the window stops the recording (it got the failure).
    if (r.writer_thread) |t| t.join();
    closeJournal(c);
    for (c.tracks.items) |*t| if (t.file) |f| {
        win32.closeHandle(f);
        t.file = null;
    };
    freeTracks(c);
    postFinished(r);
}

fn closeJournal(c: *Compressor) void {
    if (!c.segment_open) return;
    win32.closeHandle(c.segment);
    c.segment_open = false;
}

fn freeTracks(c: *Compressor) void {
    const gpa = c.allocator();
    for (c.tracks.items) |*t| freeTrack(gpa, t);
    c.tracks.deinit(gpa);
}

fn freeTrack(gpa: std.mem.Allocator, t: *OutTrack) void {
    gpa.free(t.device_name);
    gpa.free(t.file_name);
    gpa.destroy(t.encoder);
    gpa.free(t.samples);
    gpa.free(t.out);
    t.aligner.buffers.deinit(gpa);
}

fn postFinished(r: *Recording) void {
    if (r.hwnd) |hwnd| if (0 == win32.PostMessageW(hwnd, finished_msg, 0, @bitCast(@intFromPtr(r))))
        win32.panicWin32("PostMessage(recording finished)", win32.GetLastError());
}

/// Deletes every journal file in the folder: those recovery read, and any after (the writer
/// may have started one a crash left empty). One that can't be is reported: a recovery can
/// tidy it up later.
fn deleteJournalFiles(r: *Recording) void {
    var pattern_buf: PathBuf = undefined;
    const pattern = joinPath(&pattern_buf, r.dir, "journal-*.bbj");
    var found: win32.WIN32_FIND_DATAW = undefined;
    const find = win32.FindFirstFileW(pattern, &found);
    if (find == -1) switch (win32.GetLastError()) {
        .ERROR_FILE_NOT_FOUND => return,
        else => |e| return r.warn(.{ .delete_file = .{ .file = .journal_list, .err = @backingInt(e) } }),
    };
    defer _ = win32.FindClose(find);
    while (true) {
        var name_utf8: [3 * max_path]u8 = undefined;
        const n = std.unicode.wtf16LeToWtf8(&name_utf8, std.mem.sliceTo(&found.cFileName, 0));
        var path_buf: PathBuf = undefined;
        if (0 == win32.DeleteFileW(joinPath(&path_buf, r.dir, name_utf8[0..n]))) {
            // journal-NNNNNN.bbj
            const index = std.fmt.parseInt(u32, name_utf8["journal-".len..@min(n, "journal-".len + 6)], 10) catch 0;
            r.warn(.{ .delete_file = .{ .file = .{ .journal = index }, .err = @backingInt(win32.GetLastError()) } });
        }
        if (0 == win32.FindNextFileW(find, &found)) switch (win32.GetLastError()) {
            .ERROR_NO_MORE_FILES => return,
            else => |e| return r.warn(.{ .delete_file = .{ .file = .journal_list, .err = @backingInt(e) } }),
        };
    }
}

/// Deletes journal file `index`, if it's there. One that can't be is reported: a recovery can
/// tidy it up later.
fn deleteJournalFile(c: *Compressor, index: u32) void {
    var path_buf: PathBuf = undefined;
    const path = c.recording.segmentPath(&path_buf, index);
    if (0 == win32.DeleteFileW(path) and win32.GetLastError() != .ERROR_FILE_NOT_FOUND)
        c.recording.warn(.{ .delete_file = .{ .file = .{ .journal = index }, .err = @backingInt(win32.GetLastError()) } });
}

fn deleteIfExists(r: *Recording, name: []const u8, file: Problem.DoneFile) void {
    var path_buf: PathBuf = undefined;
    const path = joinPath(&path_buf, r.dir, name);
    if (0 == win32.DeleteFileW(path) and win32.GetLastError() != .ERROR_FILE_NOT_FOUND)
        r.warn(.{ .delete_file = .{ .file = file, .err = @backingInt(win32.GetLastError()) } });
}

/// How a recovery went.
pub const Recovery = union(enum) {
    /// The files are finished, and the checkpoint and journal removed.
    finished,
    /// No such folder.
    not_found,
    /// Nothing to finish: no checkpoint or journal in the folder.
    nothing_to_recover,
    /// Someone's working on it: it's being recorded, or recovered elsewhere.
    busy,
    /// The checkpoint or journal is damaged: nothing was removed.
    corrupt: Corruption,
};

/// Finishes the files of a recording a crash or a power cut interrupted, from its checkpoint
/// and journal: what the compressor would have done, on this thread. Problems with the
/// tracks' files (they couldn't be written) are added to `failures`.
pub fn recover(dir: [:0]const u16, failures: *std.ArrayList(Recording.Failure), gpa: std.mem.Allocator) Recovery {
    const attributes = win32.GetFileAttributesW(dir);
    if (attributes == win32.INVALID_FILE_ATTRIBUTES or attributes & @as(u32, @bitCast(win32.FILE_ATTRIBUTE_DIRECTORY)) == 0) return .not_found;
    if (!unfinished(dir)) return .nothing_to_recover;
    const lock = lockRecording(dir) orelse return .busy;
    const r = global_gpa.create(Recording) catch @panic("out of memory");
    r.* = .{
        .hwnd = null,
        .dir = undefined,
        // From the checkpoint or the journal.
        .started = std.mem.zeroes(win32.SYSTEMTIME),
        .start_qpc = 0,
        .stop_event = undefined,
        .compressor_event = undefined,
        .segment = undefined,
        .lock_file = lock,
        .recovering = true,
    };
    r.dir = r.allocator().dupeSentinel(u16, dir, 0) catch @panic("out of memory");
    const kernel = global_gpa.create(resample.Kernel) catch @panic("out of memory");
    defer global_gpa.destroy(kernel);
    kernel.init();
    var c: Compressor = .{
        .recording = r,
        .chunk = r.allocator().alignedAlloc(u8, .@"16", @sizeOf(journal.Header)) catch @panic("out of memory"),
        .kernel = kernel,
    };
    const result: Recovery = if (recoverJournal(&c)) .finished else |e| switch (e) {
        error.Corrupt => blk: {
            abandon(&c);
            break :blk .{ .corrupt = c.problem.? };
        },
    };
    r.allocator().free(c.chunk);
    failures.appendSlice(gpa, r.failures.items) catch @panic("out of memory");
    r.failures.deinit(r.allocator());
    r.allocator().free(r.dir);
    if (builtin.mode == .debug and r.debug_allocator.deinit() == .leak) std.debug.panic("recovering a recording leaked memory", .{});
    win32.closeHandle(r.lock_file);
    global_gpa.destroy(r);
    return result;
}

fn recoverJournal(c: *Compressor) Corrupt!void {
    if (try startCompressor(c)) while (try advance(c, 0) != .ended) {};
    try finish(c);
}

/// Whether a recording folder still has a checkpoint or journal: it wasn't finished.
pub fn unfinished(dir: []const u16) bool {
    for ([_][]const u8{ "journal-*.bbj", "checkpoint.bin" }) |name| {
        var pattern_buf: PathBuf = undefined;
        var found: win32.WIN32_FIND_DATAW = undefined;
        const find = win32.FindFirstFileW(joinPath(&pattern_buf, dir, name), &found);
        if (find != -1) {
            _ = win32.FindClose(find);
            return true;
        }
    }
    return false;
}

/// What's on the disk isn't what the compressor expects: a journal or checkpoint damaged, or
/// not one it wrote. Compressor.problem says what. Never a panic: what's on the disk isn't the
/// program's own state, and the journal still holds the audio for a recovery.
const Corrupt = error{Corrupt};

/// checkpoint.bin: (then a CRC-32 of all of it, see checkpoint) where recovery picks the journal up again and everything it needs to carry
/// on from there: each track's state and its file's length, all flushed to the disk. The writer
/// may overwrite the journal before it, recovery won't need that.
///
/// The tracks' aligners hold back their last packets (look-ahead, up to about a second of
/// audio); their samples aren't saved here but read again from the journal. So recovery starts
/// at the oldest packet any aligner still has queued (segment_index, offset, next_seq), and
/// the chunks before processed_seq are only read for those samples (see refillChunk).
const CheckpointHeader = extern struct {
    magic: u32 = checkpoint_magic,
    version: u32 = checkpoint_version,
    segment_index: u32,
    track_count: u32,
    /// Bytes ever read from the journal file's data area, at the first chunk recovery reads.
    offset: u64,
    next_seq: u64,
    /// The first chunk whose effect isn't in the checkpoint.
    processed_seq: u64,
    /// The last chunk's write_qpc: the recording's end, if recovery finds no later chunk.
    last_write_qpc: u64,
    start_qpc: u64,
    started: [8]u16,
};
const checkpoint_magic: u32 = std.mem.readInt(u32, "BBCP", .little);
const checkpoint_version = 5;

/// A track in the checkpoint, followed by its device name and file name, its
/// `staged` samples (a block not yet encoded), then the aligner's (Aligner.savedSamples,
/// savedEntries).
const TrackCheckpoint = extern struct {
    id: u32,
    ended: bool,
    reserved0: u8 = 0,
    /// Its failure (FileProblem): the action, 0 for none, and the error.
    failure_action: u8,
    start: journal.TrackStart,
    staged: u32,
    failure_err: u32,
    file_len: u64,
    frame_number: u64,
    total_frames: u64,
    min_frame_len: u32,
    max_frame_len: u32,
    first_frame_qpc: u64,
    clipped_samples: u64,
    invalid_samples: u64,
    aligner: resample.Aligner.State,
};

/// Where in the journal a chunk is: its file, bytes ever read from that file's data area
/// before it, and its journal_seq.
const JournalPlace = struct {
    segment_index: u32,
    offset: u64,
    seq: u64,

    /// Packed into a packet's source (Packet.Source.position), and the writer's
    /// compressor_progress.
    fn position(p: JournalPlace) u64 {
        return @as(u64, p.segment_index) << 40 | p.offset;
    }
};

/// Saves where the compressor is: the tracks' files flushed to the disk, then checkpoint.bin
/// replaced in one step (written beside it, then renamed over it), so a crash at any point
/// leaves a complete checkpoint. Then the writer may overwrite the journal up to where recovery
/// would start, and journal files before that go.
fn checkpoint(c: *Compressor) void {
    const r = c.recording;
    for (c.tracks.items) |*t| {
        flushTrack(c, t);
        if (t.file) |f| if (0 == win32.FlushFileBuffers(f))
            trackFailed(c, t, .write, win32.GetLastError());
    }
    var replay: JournalPlace = .{ .segment_index = c.segment_index, .offset = c.offset, .seq = c.next_seq };
    for (c.tracks.items) |*t| if (t.aligner.head()) |p| if (p.source.seq < replay.seq) {
        replay = .{ .segment_index = @intCast(p.source.position >> 40), .offset = p.source.position & ((1 << 40) - 1), .seq = p.source.seq };
    };

    var tmp_buf: PathBuf = undefined;
    const tmp = joinPath(&tmp_buf, r.dir, "checkpoint.tmp");
    var final_buf: PathBuf = undefined;
    const final = joinPath(&final_buf, r.dir, "checkpoint.bin");
    const ok = blk: {
        const file = win32.CreateFileW(tmp, .{ .FILE_WRITE_DATA = 1 }, .{}, null, .CREATE_ALWAYS, .{ .FILE_ATTRIBUTE_NORMAL = 1 }, null);
        if (file == win32.INVALID_HANDLE_VALUE) break :blk false;
        defer win32.closeHandle(file);
        var buf: [64 * 1024]u8 = undefined;
        var hw: HandleWriter = .init(file, &buf);
        // Then its checksum (CRC-32 of all of it), last, so a checkpoint that's damaged in any
        // way shows before anything in it is used.
        writeCheckpoint(c, &hw.interface, replay) catch {
            win32.SetLastError(hw.err.?);
            break :blk false;
        };
        var sum: [4]u8 = undefined;
        std.mem.writeInt(u32, &sum, hw.crc.final(), .little);
        hw.writeAll(&sum) catch {
            win32.SetLastError(hw.err.?);
            break :blk false;
        };
        break :blk 0 != win32.FlushFileBuffers(file);
    } and 0 != win32.MoveFileExW(tmp, final, .{ .REPLACE_EXISTING = 1, .WRITE_THROUGH = 1 });
    if (!ok) {
        // The recording carries on: the writer keeps the journal until a checkpoint works (it
        // grows instead). Said once, not every try.
        if (!c.checkpoint_failing) r.warn(.{ .checkpoint_save = @backingInt(win32.GetLastError()) });
        c.checkpoint_failing = true;
        return;
    }
    c.checkpoint_failing = false;
    r.compressor_progress.store(replay.position(), .release);
    while (c.oldest_segment < replay.segment_index) : (c.oldest_segment += 1) {
        deleteJournalFile(c, c.oldest_segment);
    }
}

fn writeCheckpoint(c: *Compressor, w: *std.Io.Writer, replay: JournalPlace) error{WriteFailed}!void {
    const r = c.recording;
    const header: CheckpointHeader = .{
        .segment_index = replay.segment_index,
        .track_count = @intCast(c.tracks.items.len),
        .offset = replay.offset,
        .next_seq = replay.seq,
        .processed_seq = @max(c.next_seq, c.processed_seq),
        .last_write_qpc = c.last_write_qpc,
        .start_qpc = r.start_qpc,
        .started = timeWords(r.started),
    };
    try w.writeAll(std.mem.asBytes(&header));
    for (c.tracks.items) |*t| {
        const tc: TrackCheckpoint = .{
            .id = t.id,
            .ended = t.ended,
            .failure_action = if (t.failure) |f| @intFromEnum(f.action) else 0,
            .failure_err = if (t.failure) |f| f.err else 0,
            .start = t.start,
            .staged = @intCast(t.staged),
            .file_len = t.file_len,
            .frame_number = t.encoder.frame_number,
            .total_frames = t.encoder.info.total_frames,
            .min_frame_len = t.encoder.info.min_frame_len,
            .max_frame_len = t.encoder.info.max_frame_len,
            .first_frame_qpc = t.first_frame_qpc,
            .clipped_samples = t.clipped_samples,
            .invalid_samples = t.invalid_samples,
            .aligner = t.aligner.save(),
        };
        try w.writeAll(std.mem.asBytes(&tc));
        try w.writeAll(t.device_name);
        try w.writeAll(t.file_name);
        try w.writeAll(std.mem.sliceAsBytes(t.samples[0..t.staged]));
        for (t.aligner.savedSamples()) |s| try w.writeAll(std.mem.sliceAsBytes(s));
        for (t.aligner.savedEntries()) |e| try w.writeAll(std.mem.sliceAsBytes(e));
    }
    try w.flush();
}

/// checkpoint.bin, read piece by piece straight into where each piece goes, checksummed on
/// the way (see verify). A read that comes up short says why in the compressor's problem.
const CheckpointFile = struct {
    handle: win32.HANDLE,
    c: *Compressor,
    crc: std.hash.Crc32 = .init(),

    /// Also Aligner.restore's source.
    pub fn read(f: *CheckpointFile, dest: []u8) error{Invalid}!void {
        try f.readRaw(dest);
        f.crc.update(dest);
    }

    fn readRaw(f: *CheckpointFile, dest: []u8) error{Invalid}!void {
        var done: usize = 0;
        while (done < dest.len) {
            var n: u32 = undefined;
            if (0 == win32.ReadFile(f.handle, dest[done..].ptr, @intCast(dest.len - done), &n, null)) {
                f.c.note(.{ .checkpoint_read = @backingInt(win32.GetLastError()) });
                return error.Invalid;
            }
            if (n == 0) {
                f.c.note(.checkpoint_short);
                return error.Invalid;
            }
            done += n;
        }
    }

    fn need(f: *CheckpointFile, dest: []u8) Corrupt!void {
        f.read(dest) catch return error.Corrupt;
    }

    fn value(f: *CheckpointFile, comptime T: type) Corrupt!T {
        var v: T = undefined;
        try f.need(std.mem.asBytes(&v));
        return v;
    }

    /// Everything read is what was written: the checksum after it matches.
    fn verify(f: *CheckpointFile) Corrupt!void {
        var sum: [4]u8 = undefined;
        f.readRaw(&sum) catch return error.Corrupt;
        if (std.mem.readInt(u32, &sum, .little) != f.crc.final()) return f.c.corrupt(.checkpoint_crc);
    }
};

/// Recovering: restores the compressor and its tracks from checkpoint.bin, if there is one.
/// Returns the offset to carry on from in journal file c.segment_index (0 without one).
fn loadCheckpoint(c: *Compressor) Corrupt!u64 {
    const r = c.recording;
    const gpa = c.allocator();
    var path_buf: PathBuf = undefined;
    const path = joinPath(&path_buf, r.dir, "checkpoint.bin");
    const handle = win32.CreateFileW(path, .{ .FILE_READ_DATA = 1 }, .{ .READ = 1 }, null, .OPEN_EXISTING, .{ .FILE_ATTRIBUTE_NORMAL = 1 }, null);
    if (handle == win32.INVALID_HANDLE_VALUE) {
        if (win32.GetLastError() == .ERROR_FILE_NOT_FOUND) return 0;
        return c.corrupt(.{ .checkpoint_open = @backingInt(win32.GetLastError()) });
    }
    defer win32.closeHandle(handle);
    var file: CheckpointFile = .{ .handle = handle, .c = c };

    const header = try file.value(CheckpointHeader);
    if (header.magic != checkpoint_magic or header.version != checkpoint_version)
        return c.corrupt(.{ .checkpoint_version = .{ .magic = header.magic, .version = header.version } });
    c.segment_index = header.segment_index;
    c.next_seq = header.next_seq;
    c.processed_seq = header.processed_seq;
    c.last_write_qpc = header.last_write_qpc;
    r.start_qpc = header.start_qpc;
    r.started = wordsTime(header.started);
    for (0..header.track_count) |_| {
        const tc = try file.value(TrackCheckpoint);
        const start = tc.start;
        try checkTrackStart(c, tc.id, start);
        const failure: ?FileProblem = if (tc.failure_action == 0) null else .{
            .action = std.enums.fromInt(FileProblem.Action, tc.failure_action) orelse return c.corrupt(.{ .checkpoint_failure = .{ .track = tc.id } }),
            .err = tc.failure_err,
        };
        const device_name = gpa.alloc(u8, start.device_name_len) catch @panic("out of memory");
        errdefer gpa.free(device_name);
        try file.need(device_name);
        const file_name = gpa.alloc(u8, start.file_name_len) catch @panic("out of memory");
        errdefer gpa.free(file_name);
        try file.need(file_name);
        try checkFileName(c, tc.id, file_name);
        const format: flac.Format = .{ .sample_rate = start.rate, .channels = start.channels, .bits = 24 };
        const block_samples = @as(usize, flac.block_size) * start.channels;
        if (tc.staged > block_samples) return c.corrupt(.{ .checkpoint_staged = .{ .track = tc.id, .staged = tc.staged } });
        const s = tc.aligner;
        if (s.channels != start.channels or s.rate != start.rate)
            return c.corrupt(.{ .checkpoint_timing = .{ .track = tc.id } });
        const encoder = gpa.create(flac.Encoder) catch @panic("out of memory");
        errdefer gpa.destroy(encoder);
        const samples = gpa.alloc(i32, block_samples) catch @panic("out of memory");
        errdefer gpa.free(samples);
        const out = gpa.alloc(u8, write_buffer_len + flac.Encoder.maxFrameLen(format)) catch @panic("out of memory");
        errdefer gpa.free(out);
        try file.need(std.mem.sliceAsBytes(samples[0..tc.staged]));
        const buffers = resample.Aligner.Buffers.init(gpa, start.channels, start.rate) catch @panic("out of memory");
        errdefer buffers.deinit(gpa);
        const aligner = resample.Aligner.restore(s, buffers, &file) catch
            return c.corrupt(.{ .checkpoint_timing = .{ .track = tc.id } });
        var t: OutTrack = .{
            .id = tc.id,
            .start = start,
            .device_name = device_name,
            .file_name = file_name,
            .file = null,
            .encoder = encoder,
            .samples = samples,
            .out = out,
            .staged = tc.staged,
            .file_len = tc.file_len,
            .aligner = aligner,
            .first_frame_qpc = tc.first_frame_qpc,
            .clipped_samples = tc.clipped_samples,
            .invalid_samples = tc.invalid_samples,
            .failure = failure,
            .ended = tc.ended,
        };
        t.encoder.* = .init(format);
        t.encoder.frame_number = tc.frame_number;
        t.encoder.info = .{ .min_frame_len = @intCast(tc.min_frame_len), .max_frame_len = @intCast(tc.max_frame_len), .total_frames = @intCast(tc.total_frames) };
        if (t.failure == null) {
            // Back to what was checkpointed: what was written after it is redone.
            var out_path_buf: PathBuf = undefined;
            const out_path = joinPath(&out_path_buf, r.dir, t.file_name);
            const h = win32.CreateFileW(out_path, .{ .FILE_WRITE_DATA = 1 }, .{ .READ = 1 }, null, .OPEN_EXISTING, .{ .FILE_ATTRIBUTE_NORMAL = 1 }, null);
            if (h == win32.INVALID_HANDLE_VALUE or
                0 == win32.SetFilePointerEx(h, .{ .QuadPart = @intCast(t.file_len) }, null, win32.FILE_BEGIN) or
                0 == win32.SetEndOfFile(h))
            {
                trackFailed(c, &t, .recover, win32.GetLastError());
                if (h != win32.INVALID_HANDLE_VALUE) win32.closeHandle(h);
            } else {
                t.file = h;
            }
        }
        c.tracks.append(gpa, t) catch @panic("out of memory");
    }
    // Only now is anything restored known to be what was saved.
    try file.verify();
    return header.offset;
}

/// Opens journal file `index` and checks its header follows on from the last file (or, when
/// resuming partway through it, that it starts at or before the next chunk). Recovering,
/// returns false if it's missing or doesn't follow: the journal ended before it.
fn openSegmentForReading(c: *Compressor, index: u32, resuming: bool) Corrupt!bool {
    var path_buf: PathBuf = undefined;
    const path = c.recording.segmentPath(&path_buf, index);
    const h = win32.CreateFileW(path, .{ .FILE_READ_DATA = 1 }, .{ .READ = 1, .WRITE = 1, .DELETE = 1 }, null, .OPEN_EXISTING, .{ .FILE_ATTRIBUTE_NORMAL = 1 }, null);
    if (h == win32.INVALID_HANDLE_VALUE) {
        if (c.recording.recovering and win32.GetLastError() == .ERROR_FILE_NOT_FOUND) return false;
        return c.corrupt(.{ .journal_open = .{ .file = index, .err = @backingInt(win32.GetLastError()) } });
    }
    c.segment = h;
    c.segment_open = true;
    var header: journal.FileHeader = undefined;
    const read = try readAt(c, std.mem.asBytes(&header), 0);
    const follows = if (resuming) header.first_seq <= c.next_seq else header.first_seq == c.next_seq;
    const ok = read and header.magic == journal.file_magic and header.index == index and
        follows and header.capacity != 0 and header.capacity % journal.chunk_align == 0;
    if (!ok) {
        if (c.recording.recovering) {
            closeJournal(c);
            return false;
        }
        return c.corrupt(.{ .journal_header = .{ .file = index } });
    }
    if (c.recording.recovering and c.recording.start_qpc == 0) {
        c.recording.start_qpc = header.start_qpc;
        c.recording.started = wordsTime(header.started);
    }
    c.capacity = header.capacity;
    c.offset = 0;
    c.segment_ended = false;
    return true;
}

/// Processes whole chunks up to `end` (bytes ever written to the data area), or the file's
/// segment_end. Returns whether any were.
fn readChunks(c: *Compressor, end: u64) Corrupt!bool {
    const header_len = @sizeOf(journal.Header);
    var any = false;
    while (!c.done and !c.segment_ended and c.offset < end) {
        const at = journal.FileHeader.data_start + c.offset % c.capacity;
        const header_read = try readAt(c, c.chunk[0..header_len], at);
        const h: journal.Header = std.mem.bytesToValue(journal.Header, c.chunk[0..header_len]);
        if (!header_read or h.magic != journal.magic or h.journal_seq != c.next_seq or h.size() > c.capacity - c.offset % c.capacity) {
            // Recovering, that's where the writer stopped (what follows is the last lap's).
            if (c.recording.recovering) {
                c.done = true;
                break;
            }
            return c.corrupt(.{ .journal_damaged = .{ .file = c.segment_index, .at = c.offset, .chunk = h.journal_seq, .expected = c.next_seq } });
        }
        // Padding's bytes aren't part of the journal.
        const payload_len: usize = if (h.kind == .padding) 0 else h.len;
        if (header_len + payload_len > c.chunk.len) {
            const gpa = c.allocator();
            gpa.free(c.chunk);
            c.chunk = gpa.alignedAlloc(u8, .@"16", header_len + payload_len) catch @panic("out of memory");
        }
        const payload = c.chunk[header_len..][0..payload_len];
        if (!try readAt(c, payload, at + header_len) or h.computeCrc(&.{payload}) != h.crc) {
            if (c.recording.recovering) {
                c.done = true;
                break;
            }
            return c.corrupt(.{ .journal_crc = .{ .file = c.segment_index, .chunk = h.journal_seq } });
        }
        c.next_seq += 1;
        switch (h.kind) {
            .padding => {},
            .segment_end => c.segment_ended = true,
            else => try processChunk(c, h, payload, .{ .segment_index = c.segment_index, .offset = c.offset, .seq = h.journal_seq }),
        }
        c.offset += h.size();
        any = true;
    }
    return any;
}

/// Reads all of `buf` at `offset`. Returns false if the file ends first, which only happens
/// when recovering (the writer extends nothing; its files are allocated up front).
fn readAt(c: *Compressor, buf: []u8, offset: u64) Corrupt!bool {
    var ov: win32.OVERLAPPED = std.mem.zeroes(win32.OVERLAPPED);
    ov.Anonymous.Anonymous.Offset = @truncate(offset);
    ov.Anonymous.Anonymous.OffsetHigh = @truncate(offset >> 32);
    var n: u32 = undefined;
    if (0 == win32.ReadFile(c.segment, buf.ptr, @intCast(buf.len), &n, &ov)) switch (win32.GetLastError()) {
        .ERROR_HANDLE_EOF => n = 0,
        else => |err| return c.corrupt(.{ .journal_read = .{ .file = c.segment_index, .err = @backingInt(err) } }),
    };
    if (n == buf.len) return true;
    if (c.recording.recovering) return false;
    return c.corrupt(.{ .journal_short = .{ .file = c.segment_index, .at = offset } });
}

fn processChunk(c: *Compressor, h: journal.Header, payload: []const u8, place: JournalPlace) Corrupt!void {
    c.last_write_qpc = @max(c.last_write_qpc, h.write_qpc);
    // Recovering, before where the checkpoint was: read again only for the samples of the
    // packets the aligners still had queued.
    if (h.journal_seq < c.processed_seq) {
        if (h.kind == .audio) try refillChunk(c, h, payload);
        return;
    }
    if (c.processed_seq != 0) {
        for (c.tracks.items) |*t| if (t.aligner.missing()) |p|
            return c.corrupt(.{ .packet_missing = .{ .track = t.id, .frame = p.first_frame, .chunk = p.source.seq } });
        c.processed_seq = 0;
    }
    switch (h.kind) {
        .track_start => try startTrack(c, h, payload),
        .audio => {
            const t = try findTrack(c, h.track);
            if (t.ended) return c.corrupt(.{ .audio_after_end = .{ .track = h.track } });
            var records: RecordIterator = .{ .c = c, .payload = payload };
            var index: u32 = 0;
            while (try records.next()) |rec| : (index += 1) {
                try pushRecord(c, t, rec, .{ .position = place.position(), .seq = h.journal_seq, .index = index });
            }
        },
        .track_end => {
            const t = try findTrack(c, h.track);
            t.ended = true;
            // Everything it gave out to the file; its return (or the end) fills the time after.
            t.aligner.endSegment(c.kernel, TrackSink{ .c = c, .t = t });
        },
        .recording_end => {
            c.end_qpc = h.capture_qpc;
            c.done = true;
        },
        .padding, .segment_end => unreachable, // readChunks
        _ => return c.corrupt(.{ .unknown_chunk = .{ .kind = @backingInt(h.kind) } }),
    }
}

/// An audio chunk's records, each with its samples (null when silent).
const RecordIterator = struct {
    c: *Compressor,
    payload: []const u8,
    offset: usize = 0,

    const Item = struct { record: journal.Record, samples: ?[]const u8 };

    fn next(it: *RecordIterator) Corrupt!?Item {
        if (it.offset == it.payload.len) return null;
        if (it.payload.len - it.offset < @sizeOf(journal.Record)) return it.c.corrupt(.record_cut);
        const record = std.mem.bytesToValue(journal.Record, it.payload[it.offset..][0..@sizeOf(journal.Record)]);
        it.offset += @sizeOf(journal.Record);
        if (it.payload.len - it.offset < record.len) return it.c.corrupt(.record_cut);
        const samples = it.payload[it.offset..][0..record.len];
        it.offset += record.len;
        return .{ .record = record, .samples = if (record.flags.silent) null else samples };
    }
};

/// One packet of the device's audio, to its aligner: in pieces if it's bigger than the
/// aligner takes, each timed from the packet's capture time at the nominal rate.
fn pushRecord(c: *Compressor, t: *OutTrack, rec: RecordIterator.Item, source: resample.Packet.Source) Corrupt!void {
    const h = rec.record;
    const rate = t.start.rate;
    const block_align: usize = t.start.block_align;
    try checkRecordSamples(c, t, rec);
    const sink: TrackSink = .{ .c = c, .t = t };
    const max = resample.Aligner.maxPacketFrames(rate);
    var offset: u32 = 0;
    while (offset < h.frames) {
        const n = @min(max, h.frames - offset);
        const slots = t.aligner.reserve(c.kernel, n, sink);
        if (rec.samples) |bytes| t.invalid_samples += toFloats(t, n, bytes[offset * block_align ..][0 .. n * block_align], slots);
        var piece_source = source;
        piece_source.offset = offset;
        t.aligner.push(c.kernel, .{
            .first_frame = h.first_frame + offset,
            .capture_qpc = h.capture_qpc + @as(u64, offset) * 10_000_000 / rate,
            .source = piece_source,
            .frames = n,
            .silent = rec.samples == null,
            .timestamp_error = h.flags.timestamp_error,
            .discontinuity = h.flags.discontinuity and offset == 0,
        }, sink);
        offset += n;
    }
    if (!h.flags.timestamp_error and t.first_frame_qpc == 0) t.first_frame_qpc = h.capture_qpc;
}

/// A record's samples are as many as its frames, in its track's format.
fn checkRecordSamples(c: *Compressor, t: *const OutTrack, rec: RecordIterator.Item) Corrupt!void {
    const bytes = rec.samples orelse return;
    if (bytes.len != @as(usize, rec.record.frames) * t.start.block_align)
        return c.corrupt(.{ .record_size = .{ .track = t.id, .bytes = @intCast(bytes.len), .frames = rec.record.frames } });
}

/// Recovering: the samples of the queued packets in a chunk from before the checkpoint.
fn refillChunk(c: *Compressor, h: journal.Header, payload: []const u8) Corrupt!void {
    // Its track may have been added again since (a new id), having queued nothing from here.
    const t = for (c.tracks.items) |*t| {
        if (t.id == h.track) break t;
    } else return;
    var records: RecordIterator = .{ .c = c, .payload = payload };
    var index: u32 = 0;
    const block_align: usize = t.start.block_align;
    while (try records.next()) |rec| : (index += 1) {
        // The record's pieces (see pushRecord) still queued.
        while (t.aligner.missing()) |p| {
            if (p.source.seq != h.journal_seq or p.source.index != index) break;
            const r = rec.record;
            if (@as(u64, p.source.offset) + p.frames > r.frames or p.first_frame != r.first_frame + p.source.offset)
                return c.corrupt(.{ .packet_mismatch = .{ .track = t.id, .chunk = h.journal_seq, .record = index } });
            try checkRecordSamples(c, t, rec);
            const slots = t.aligner.missingSlots();
            // Its invalid samples were counted before the crash.
            if (rec.samples) |bytes|
                _ = toFloats(t, p.frames, bytes[p.source.offset * block_align ..][0 .. p.frames * block_align], slots)
            else for (slots) |s| @memset(s, 0);
            t.aligner.refilled();
        }
        if (t.aligner.missing() == null) return;
    }
}

fn findTrack(c: *Compressor, id: u32) Corrupt!*OutTrack {
    for (c.tracks.items) |*t| if (t.id == id) return t;
    return c.corrupt(.{ .unknown_track = .{ .track = id } });
}

/// A track's format and names are ones the compressor takes (it wrote them, so anything else
/// is damage).
fn checkTrackStart(c: *Compressor, id: u32, start: journal.TrackStart) Corrupt!void {
    const size: u32 = switch (start.sample) {
        .f32, .i32 => 4,
        .i24 => 3,
        .i16 => 2,
        _ => return c.corrupt(trackFormat(id, start)),
    };
    if (start.channels == 0 or start.rate == 0 or start.rate >= 1 << 20 or start.block_align != size * start.channels)
        return c.corrupt(trackFormat(id, start));
    if (start.device_name_len > max_device_name or start.file_name_len == 0 or start.file_name_len > max_file_name)
        return c.corrupt(.{ .track_names = .{ .track = id } });
}

fn trackFormat(id: u32, start: journal.TrackStart) Corruption {
    return .{ .track_format = .{ .track = id, .sample = @backingInt(start.sample), .channels = start.channels, .rate = start.rate, .block_align = start.block_align } };
}

/// A track's file name is one uniqueFileName could have made: a name, not a path.
fn checkFileName(c: *Compressor, id: u32, name: []const u8) Corrupt!void {
    const ok = std.unicode.wtf8ValidateSlice(name) and std.mem.indexOfAny(u8, name, "\\/:") == null and
        !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..");
    if (!ok) return c.corrupt(.{ .track_names = .{ .track = id } });
}

/// The longest names a track start has: see writeTrackStart and uniqueFileName.
const max_device_name = 1024;
const max_file_name = 128 + 32;

fn startTrack(c: *Compressor, h: journal.Header, payload: []const u8) Corrupt!void {
    const gpa = c.allocator();
    if (payload.len < @sizeOf(journal.TrackStart)) return c.corrupt(.{ .track_start_size = .{ .track = h.track, .bytes = @intCast(payload.len) } });
    const start = std.mem.bytesToValue(journal.TrackStart, payload[0..@sizeOf(journal.TrackStart)]);
    try checkTrackStart(c, h.track, start);
    const strings = payload[@sizeOf(journal.TrackStart)..];
    if (strings.len != @as(usize, start.device_name_len) + start.file_name_len) return c.corrupt(.{ .track_start_size = .{ .track = h.track, .bytes = @intCast(payload.len) } });
    const file_name = strings[start.device_name_len..];
    try checkFileName(c, h.track, file_name);
    // The same device added again: its file carries on, with silence for the time it was gone
    // (the window's thread only gives the same name to the same device and format). Its
    // aligner places it by its capture times again.
    for (c.tracks.items) |*old| if (std.mem.eql(u8, old.file_name, file_name)) {
        if (!old.ended or old.start.rate != start.rate or old.start.channels != start.channels or old.start.sample != start.sample)
            return c.corrupt(.{ .track_reuse = .{ .track = h.track } });
        old.id = h.track;
        old.start = start;
        old.ended = false;
        return;
    };
    const format: flac.Format = .{ .sample_rate = start.rate, .channels = start.channels, .bits = 24 };
    var t: OutTrack = .{
        .id = h.track,
        .start = start,
        .device_name = gpa.dupe(u8, strings[0..start.device_name_len]) catch @panic("out of memory"),
        .file_name = gpa.dupe(u8, file_name) catch @panic("out of memory"),
        .file = null,
        .encoder = gpa.create(flac.Encoder) catch @panic("out of memory"),
        .samples = gpa.alloc(i32, @as(usize, flac.block_size) * start.channels) catch @panic("out of memory"),
        .out = gpa.alloc(u8, write_buffer_len + flac.Encoder.maxFrameLen(format)) catch @panic("out of memory"),
        .aligner = .init(start.channels, start.rate, resample.Aligner.Buffers.init(gpa, start.channels, start.rate) catch @panic("out of memory"), c.recording.start_qpc),
    };
    t.encoder.* = .init(format);
    // The header first, with nothing known yet, so the file decodes even if it's never
    // finished; finalizeTrack rewrites it.
    flac.writeHeader(t.out[0..flac.header_len], format, .{}, &.{});
    t.out_len = flac.header_len;
    var path_buf: PathBuf = undefined;
    const path = joinPath(&path_buf, c.recording.dir, t.file_name);
    // Recovering, a partial file from before the crash is redone: nothing of it was
    // checkpointed, or this chunk would be before the checkpoint.
    const disposition: win32.FILE_CREATION_DISPOSITION = if (c.recording.recovering) .CREATE_ALWAYS else .CREATE_NEW;
    const file = win32.CreateFileW(path, .{ .FILE_WRITE_DATA = 1 }, .{ .READ = 1 }, null, disposition, .{ .FILE_ATTRIBUTE_NORMAL = 1 }, null);
    if (file == win32.INVALID_HANDLE_VALUE) {
        trackFailed(c, &t, .create, win32.GetLastError());
    } else {
        t.file = file;
    }
    c.tracks.append(gpa, t) catch @panic("out of memory");
}

fn trackFailed(c: *Compressor, t: *OutTrack, action: FileProblem.Action, err: win32.WIN32_ERROR) void {
    if (t.failure != null) return;
    t.failure = .{ .action = action, .err = @backingInt(err) };
    c.recording.fail(t.id, .{ .track_file = t.failure.? });
}

fn encodeStaged(c: *Compressor, t: *OutTrack) void {
    if (t.staged == 0) return;
    t.out_len += t.encoder.encode(t.samples[0..t.staged], t.out[t.out_len..]);
    t.staged = 0;
    if (t.out_len >= write_buffer_len) flushTrack(c, t);
}

fn flushTrack(c: *Compressor, t: *OutTrack) void {
    const file = t.file orelse {
        t.out_len = 0;
        return;
    };
    var done: usize = 0;
    while (done < t.out_len) {
        var n: u32 = undefined;
        if (0 == win32.WriteFile(file, t.out[done..].ptr, @intCast(t.out_len - done), &n, null)) {
            trackFailed(c, t, .write, win32.GetLastError());
            win32.closeHandle(file);
            t.file = null;
            break;
        }
        done += n;
        t.file_len += n;
    }
    t.out_len = 0;
}

/// At the recording's end: everything the aligner holds out, silence to `end_qpc` so every
/// track ends with the recording, then the rest written, the header completed (lengths,
/// tags), and all of it on the disk.
fn finalizeTrack(c: *Compressor, t: *OutTrack, end_qpc: u64) void {
    t.aligner.finish(c.kernel, end_qpc, TrackSink{ .c = c, .t = t });
    encodeStaged(c, t);
    flushTrack(c, t);
    const file = t.file orelse return;
    var header: [flac.header_len]u8 = undefined;
    const tags = trackTags(c, t);
    flac.writeHeader(&header, t.encoder.format, t.encoder.info, &tags);
    var n: u32 = undefined;
    if (0 == win32.SetFilePointerEx(file, .{ .QuadPart = 0 }, null, win32.FILE_BEGIN) or
        0 == win32.WriteFile(file, &header, header.len, &n, null) or
        0 == win32.FlushFileBuffers(file))
        trackFailed(c, t, .finish, win32.GetLastError());
    win32.closeHandle(file);
    t.file = null;
}

/// A record's samples (`frames` of them, as captured) into the aligner's float slots. Returns
/// how many floats weren't numbers (silenced).
fn toFloats(t: *const OutTrack, frames: u32, bytes: []const u8, slots: [2][]f32) u64 {
    if (bytes.len != @as(usize, frames) * t.start.block_align) std.debug.panic("journal: audio record has {d} bytes for {d} frames", .{ bytes.len, frames });
    var invalid: u64 = 0;
    switch (t.start.sample) {
        inline .f32, .i16, .i24, .i32 => |st| {
            const size = switch (st) {
                .f32, .i32 => 4,
                .i16 => 2,
                .i24 => 3,
                else => comptime unreachable,
            };
            var i: usize = 0;
            for (slots) |slot| for (slot) |*o| {
                const b = bytes[i * size ..][0..size];
                i += 1;
                o.* = switch (st) {
                    .f32 => blk: {
                        const v: f32 = @bitCast(std.mem.readInt(u32, b, .little));
                        if (!std.math.isFinite(v)) {
                            invalid += 1;
                            break :blk 0;
                        }
                        break :blk v;
                    },
                    .i16 => @as(f32, @floatFromInt(std.mem.readInt(i16, b, .little))) / 32768.0,
                    .i24 => @as(f32, @floatFromInt(std.mem.readInt(i24, b, .little))) / 8388608.0,
                    .i32 => @floatCast(@as(f64, @floatFromInt(std.mem.readInt(i32, b, .little))) / 2147483648.0),
                    else => comptime unreachable,
                };
            };
        },
        _ => unreachable, // checkTrackFormat
    }
    return invalid;
}

/// A track's details, for its file's header: what's known about it beyond the audio (the
/// header has the format and length). Standard tags where there's one (TITLE, DATE), plain
/// names otherwise. Values are bounded (the device name to 1024 bytes, see writeTrackStart),
/// so they fit flac.tags_area.
fn trackTags(c: *Compressor, t: *const OutTrack) flac.Tags {
    const r = c.recording;
    const start = t.start;
    var tags: flac.Tags = .{};
    tags.add("TITLE", "{s}", .{t.device_name});
    const st = r.started;
    tags.add("DATE", "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{ st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond });
    // QPC, 100ns units: where every track's first sample is on the system clock, so tracks
    // line up (they all start there).
    tags.add("RECORDING_START_QPC", "{d}", .{r.start_qpc});
    if (start.device_format_known != 0) {
        const df: bb.AudioFormat = .{ .sample = @fromBackingInt(@intCast(start.device_sample)), .bits = start.device_bits, .rate = start.device_rate, .channels = start.device_channels };
        tags.add("DEVICE_FORMAT", "{s}", .{df.text().slice()});
    }
    const captured: bb.AudioFormat = .{
        .sample = if (start.sample == .f32) .float else .integer,
        .bits = switch (start.sample) {
            .i16 => 16,
            .i24 => 24,
            else => 32,
        },
        .rate = start.rate,
        .channels = start.channels,
    };
    tags.add("CAPTURED_AS", "{s}", .{captured.text().slice()});
    // Windows' audio effects bypassed.
    tags.add("RAW", "{d}", .{start.raw});
    if (t.first_frame_qpc != 0) tags.add("FIRST_CAPTURE_QPC", "{d}", .{t.first_frame_qpc});
    // Finished after a crash, from the journal.
    tags.add("RECOVERED", "{d}", .{@intFromBool(r.recovering)});
    // How its device's timing was corrected (see resample.Aligner).
    const stats = &t.aligner.stats;
    tags.add("GAPS", "{d}", .{stats.gaps});
    tags.add("GAP_FRAMES", "{d}", .{stats.gap_frames});
    tags.add("STALLS", "{d}", .{stats.stalls});
    tags.add("STALL_FRAMES", "{d}", .{stats.stall_frames});
    tags.add("DROPS", "{d}", .{stats.drops});
    tags.add("DROP_FRAMES", "{d}", .{stats.drop_frames});
    tags.add("RESTARTS", "{d}", .{stats.restarts});
    tags.add("TIMESTAMP_ERRORS", "{d}", .{stats.timestamp_errors});
    tags.add("DISCONTINUITIES", "{d}", .{stats.discontinuities});
    tags.add("OUTLIERS", "{d}", .{stats.outliers});
    tags.add("RESYNCS", "{d}", .{stats.resyncs});
    tags.add("CLIPPED_SAMPLES", "{d}", .{t.clipped_samples});
    tags.add("INVALID_SAMPLES", "{d}", .{t.invalid_samples});
    if (stats.drift.rate()) |hz| {
        const nominal: f64 = @floatFromInt(start.rate);
        tags.add("MEASURED_RATE_HZ", "{d:.3}", .{hz});
        tags.add("DRIFT_PPM", "{d:.2}", .{(hz / nominal - 1) * 1_000_000});
        if (stats.drift.window_rate_min <= stats.drift.window_rate_max) {
            tags.add("DRIFT_PPM_MIN", "{d:.2}", .{(stats.drift.window_rate_min / nominal - 1) * 1_000_000});
            tags.add("DRIFT_PPM_MAX", "{d:.2}", .{(stats.drift.window_rate_max / nominal - 1) * 1_000_000});
        }
        tags.add("DRIFT_CORRECTED_MS", "{d:.3}", .{(hz / nominal - 1) * stats.drift.span * 1000});
    }
    if (t.failure) |f| tags.add("ERROR", "{f}", .{f});
    return tags;
}

// ---------------------------------------------------------------------------

/// `rec_dir\2026-11-16 15-42-07`, or with " (2)" and so on if that's taken.
fn createDir(gpa: std.mem.Allocator, rec_dir: []const u16, t: win32.SYSTEMTIME) error{ AccessDenied, Unexpected }![:0]const u16 {
    var n: u32 = 1;
    while (true) : (n += 1) {
        var name_buf: [64]u8 = undefined;
        const name = if (n == 1)
            std.fmt.bufPrint(&name_buf, "{d}-{d:0>2}-{d:0>2} {d:0>2}-{d:0>2}-{d:0>2}", .{ t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond }) catch unreachable
        else
            std.fmt.bufPrint(&name_buf, "{d}-{d:0>2}-{d:0>2} {d:0>2}-{d:0>2}-{d:0>2} ({d})", .{ t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond, n }) catch unreachable;
        var dir_buf: PathBuf = undefined;
        const dir = joinPath(&dir_buf, rec_dir, name);
        // The recording keeps it.
        if (try createNewDir(dir)) {
            const kept = gpa.allocSentinel(u16, dir.len, 0) catch @panic("out of memory");
            @memcpy(kept, dir);
            return kept;
        }
    }
}

/// A recording folder that never got started: nothing to keep.
fn removeEmptyDir(dir: [:0]const u16) void {
    if (0 == win32.RemoveDirectoryW(dir)) win32.panicWin32("RemoveDirectory(recording)", win32.GetLastError());
}

/// Opens the recording folder's lock file, held while someone works on the recording (see
/// Recording.lock_file), or null if someone already is (or GetLastError says why not).
fn lockRecording(dir: []const u16) ?win32.HANDLE {
    var path_buf: PathBuf = undefined;
    const path = joinPath(&path_buf, dir, "recording.lock");
    const h = win32.CreateFileW(path, .{ .DELETE = 1, .FILE_WRITE_DATA = 1 }, .{}, null, .OPEN_ALWAYS, .{ .FILE_ATTRIBUTE_NORMAL = 1, .FILE_FLAG_DELETE_ON_CLOSE = 1 }, null);
    if (h == win32.INVALID_HANDLE_VALUE) return null;
    return h;
}

/// Whether it was created: false if it already exists.
fn createNewDir(path: [:0]const u16) error{ AccessDenied, Unexpected }!bool {
    if (0 != win32.CreateDirectoryW(path, null)) return true;
    return switch (win32.GetLastError()) {
        .ERROR_ALREADY_EXISTS => false,
        .ERROR_ACCESS_DENIED => error.AccessDenied,
        else => error.Unexpected,
    };
}

/// `dir\name`, allocated. `name` is UTF-8.
/// A path built on the stack (see joinPath).
const PathBuf = [max_path:0]u16;
const max_path = 260;

/// `dir\name` in `buf`. Paths past MAX_PATH aren't supported (they'd need the \\?\ form).
fn joinPath(buf: *PathBuf, dir: []const u16, name: []const u8) [:0]const u16 {
    if (dir.len + 1 + name.len > buf.len) std.debug.panic("path too long: {f}\\{s}", .{ std.unicode.fmtUtf16Le(dir), name });
    @memcpy(buf[0..dir.len], dir);
    buf[dir.len] = '\\';
    // WTF-16 is never longer than the WTF-8 it came from.
    const n = std.unicode.wtf8ToWtf16Le(buf[dir.len + 1 ..], name) catch std.debug.panic("invalid UTF-8 in file name '{s}'", .{name});
    buf[dir.len + 1 + n] = 0;
    return buf[0 .. dir.len + 1 + n :0];
}

/// The longest start of `s` of at most `max` bytes that doesn't end inside a character.
fn truncateUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    // Back over continuation bytes (10xxxxxx) to the start of the character cut through.
    while (end > 0 and s[end] & 0xC0 == 0x80) end -= 1;
    return s[0..end];
}

test truncateUtf8 {
    try std.testing.expectEqualStrings("abc", truncateUtf8("abc", 5));
    try std.testing.expectEqualStrings("ab", truncateUtf8("abc", 2));
    // "é" is 2 bytes, "日" 3: never half of one.
    try std.testing.expectEqualStrings("a", truncateUtf8("a\u{e9}b", 2));
    try std.testing.expectEqualStrings("a\u{e9}", truncateUtf8("a\u{e9}b", 3));
    try std.testing.expectEqualStrings("", truncateUtf8("\u{65e5}\u{672c}", 2));
    try std.testing.expectEqualStrings("\u{65e5}", truncateUtf8("\u{65e5}\u{672c}", 5));
    try std.testing.expect(std.unicode.utf8ValidateSlice(truncateUtf8("\u{1F3A4} mic", 3)));
}

/// A SYSTEMTIME as the journal stores it (journal.FileHeader.started).
fn timeWords(t: win32.SYSTEMTIME) [8]u16 {
    return .{ t.wYear, t.wMonth, t.wDayOfWeek, t.wDay, t.wHour, t.wMinute, t.wSecond, t.wMilliseconds };
}

fn wordsTime(w: [8]u16) win32.SYSTEMTIME {
    return .{ .wYear = w[0], .wMonth = w[1], .wDayOfWeek = w[2], .wDay = w[3], .wHour = w[4], .wMinute = w[5], .wSecond = w[6], .wMilliseconds = w[7] };
}

/// QueryPerformanceCounter in 100ns units, the unit WASAPI's timestamps use.
pub fn qpc100ns() u64 {
    var count: win32.LARGE_INTEGER = undefined;
    if (0 == win32.QueryPerformanceCounter(&count)) win32.panicWin32("QueryPerformanceCounter", win32.GetLastError());
    return @intCast(@as(u128, @intCast(count.QuadPart)) * 10_000_000 / qpcFrequency());
}

/// Fixed at boot: read once (by whichever thread first needs it; they'd all read the same).
var qpc_frequency: std.atomic.Value(u64) = .init(0);

fn qpcFrequency() u64 {
    const known = qpc_frequency.load(.monotonic);
    if (known != 0) return known;
    var freq: win32.LARGE_INTEGER = undefined;
    if (0 == win32.QueryPerformanceFrequency(&freq)) win32.panicWin32("QueryPerformanceFrequency", win32.GetLastError());
    qpc_frequency.store(@intCast(freq.QuadPart), .monotonic);
    return @intCast(freq.QuadPart);
}

/// A Win32 slim reader/writer lock, used exclusively. Zero-initialized, no cleanup.
pub const Lock = struct {
    srw: win32.RTL_SRWLOCK = .{ .Ptr = null },

    pub fn lock(l: *Lock) void {
        win32.AcquireSRWLockExclusive(&l.srw);
    }
    pub fn unlock(l: *Lock) void {
        win32.ReleaseSRWLockExclusive(&l.srw);
    }
};

/// The allocator for the Recording itself, and for everything in release builds. Set once at
/// startup, before any recording.
pub var global_gpa: std.mem.Allocator = undefined;

const builtin = @import("builtin");
const std = @import("std");
const win32 = @import("win32").everything;
const wintrace = @import("wintrace");
const bb = @import("bb.zig");
const flac = @import("flac.zig");
const journal = @import("journal.zig");
const resample = @import("resample.zig");
const wasapi = @import("wasapi.zig");

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// Crash recovery: a recording interrupted at any point and recovered gives exactly the files
// the same recording would have given uninterrupted. The pipeline is deterministic, so
// "exactly" is byte for byte.
//
// A simulated session (tracks with drift, jitter, lost packets, a device restart, silence,
// wrong timestamps, a track that goes and comes back) is written to a journal by the real
// writer code and compressed by the real compressor, interleaved on one thread as the two
// threads would interleave live, with checkpoints along the way. At the crash point the
// recording's folder is copied as a crash would leave it: what's on disk, nothing the
// compressor still held in memory. The original then carries on as if the writer had stopped
// there (the journal ends at the same chunk, no recording_end) and finishes; the copy is
// recovered. Both have read the same journal, so their files must be identical.

const test_rate = 16000;
/// 10 ms, a tick of the simulation: each track captures one packet a tick.
const test_packet = 160;
const test_ticks = 800;
/// Small, so the journal wraps and moves on to new files (twice the size) many times.
const test_journal_capacity = 64 << 10;
/// Smaller than chunk_max_bytes, so a writer pass splits a track's records into chunks.
const test_chunk_bytes = 3000;
/// The writer writes every this many ticks, the compressor reads every this many, and
/// checkpoints every this many.
const writer_every = 5;
const compressor_every = 7;
const checkpoint_every = 50;
/// The journal is flushed every this many ticks (the compressor only sees what's flushed).
/// Not a multiple of checkpoint_every, so checkpoints come between flushes.
const flush_every = 30;

const SimTrack = struct {
    name: []const u8,
    file_name: []const u8,
    input: Input,
    ppm: f64,
    /// When the device is there, in ticks: [from, to). Each span is a track_start (the same
    /// file carried on) to a track_end.
    spans: []const [2]u32,
    /// Packets lost (the position skips) from this tick, for this many.
    lost_at: ?u32 = null,
    lost_count: u32 = 5,
    /// The device restarts (its position goes back to 0) at this tick.
    restart_at: ?u32 = null,
    /// Digital silence (no samples) over these ticks.
    silent: ?[2]u32 = null,
    /// Every this many packets has a timestamp Windows says is wrong.
    timestamp_error_every: ?u32 = null,
    tone_hz: f64,

    id: u32 = 0,
    seq: u32 = 0,
    position: u64 = 0,
    /// The device's own time, seconds.
    t: f64 = 0,
    packets: u32 = 0,
    lost_since: bool = false,
    pending: std.ArrayList(u8) = .empty,

    fn active(st: *const SimTrack, tick: u32) bool {
        for (st.spans) |s| if (tick >= s[0] and tick < s[1]) return true;
        return false;
    }
};

const sim_tracks = [_]SimTrack{
    .{
        .name = "Mic A",
        .file_name = "Mic A.flac",
        .input = .{ .sample = .f32, .channels = 2, .rate = test_rate, .block_align = 8 },
        .ppm = 42,
        .spans = &.{.{ 0, test_ticks }},
        .tone_hz = 440,
    },
    .{
        .name = "Mic B",
        .file_name = "Mic B.flac",
        .input = .{ .sample = .i16, .channels = 1, .rate = test_rate, .block_align = 2 },
        .ppm = -30,
        .spans = &.{.{ 0, test_ticks }},
        .lost_at = 300,
        .restart_at = 500,
        .silent = .{ 600, 650 },
        .tone_hz = 330,
    },
    .{
        .name = "Output",
        .file_name = "Output.flac",
        .input = .{ .sample = .f32, .channels = 1, .rate = test_rate, .block_align = 4 },
        .ppm = 10,
        .spans = &.{ .{ 100, 350 }, .{ 550, test_ticks } },
        .timestamp_error_every = 37,
        .tone_hz = 550,
    },
};

/// The session's writer side: the tracks, captured and written to the journal by the real
/// writer functions.
const Sim = struct {
    gpa: std.mem.Allocator,
    tracks: [sim_tracks.len]SimTrack = sim_tracks,
    /// When the session started: its captures are timed from here. In the recent past, as
    /// a live session's are by the time the writer writes them (see crashAndRecover).
    start_qpc: u64,
    next_id: u32 = 1,
    rng: std.Random.DefaultPrng = .init(7),

    fn deinit(s: *Sim) void {
        for (&s.tracks) |*st| st.pending.deinit(s.gpa);
    }

    /// Captures a tick's packets, and writes what the writer would write then.
    fn tick(s: *Sim, r: *Recording, tick_n: u32) !void {
        for (&s.tracks) |*st| {
            for (st.spans) |span| if (tick_n == span[0]) {
                // Added (again): a new id, the same file, its position from 0.
                st.id = s.next_id;
                s.next_id += 1;
                st.seq = 0;
                st.position = 0;
                st.t = @as(f64, @floatFromInt(tick_n)) / 100;
                var tw: AudioPoolSource = .{
                    .recording = r,
                    .id = st.id,
                    .info = .{ .input = st.input, .device_id = "", .device_name = st.name, .device_format = null, .raw = false },
                    .device_name = st.name,
                    .file_name = st.file_name,
                    .ring = undefined,
                    .ring_capacity = .init(0),
                    .writer_ring = undefined,
                };
                writeTrackStart(r, &tw);
                st.seq = tw.seq;
            };
            if (st.active(tick_n)) try s.capture(st, tick_n);
            for (st.spans) |span| if (tick_n + 1 == span[1]) {
                // Gone: what it gave, then its end.
                writeAudio(r, st);
                writeChunk(r, .{ .len = 0, .track = st.id, .seq = st.seq, .kind = .track_end }, &.{});
                st.seq += 1;
            };
        }
        if (tick_n % writer_every == 0) for (&s.tracks) |*st| writeAudio(r, st);
    }

    fn capture(s: *Sim, st: *SimTrack, tick_n: u32) !void {
        const gpa = s.gpa;
        if (st.restart_at == tick_n) st.position = 0;
        const lost = if (st.lost_at) |at| tick_n >= at and tick_n < at + st.lost_count else false;
        const silent = if (st.silent) |sp| tick_n >= sp[0] and tick_n < sp[1] else false;
        const jitter: f64 = (s.rng.random().float(f64) - 0.5) * 0.0006;
        // Jitter can put the very first packets a little before the start.
        const qpc: u64 = @intCast(@as(i64, @intCast(s.start_qpc)) + @as(i64, @intFromFloat((st.t + jitter) * 10_000_000)));
        const record_at = st.pending.items.len;
        if (!lost) try st.pending.appendNTimes(gpa, 0, @sizeOf(journal.Record));
        var len: u32 = 0;
        for (0..test_packet) |_| {
            const v: f32 = @floatCast(0.3 * @sin(2 * std.math.pi * st.tone_hz * st.t) + 0.01 * (s.rng.random().float(f64) - 0.5));
            st.t += 1 / (@as(f64, test_rate) * (1 + st.ppm * 1e-6));
            if (lost or silent) continue;
            for (0..st.input.channels) |_| switch (st.input.sample) {
                .f32 => {
                    var b: [4]u8 = undefined;
                    std.mem.writeInt(u32, &b, @bitCast(v), .little);
                    try st.pending.appendSlice(gpa, &b);
                    len += 4;
                },
                .i16 => {
                    var b: [2]u8 = undefined;
                    std.mem.writeInt(i16, &b, @intFromFloat(v * 32767), .little);
                    try st.pending.appendSlice(gpa, &b);
                    len += 2;
                },
                .i24, .i32 => unreachable, // not simulated
            };
        }
        st.packets += 1;
        defer st.position += test_packet;
        if (lost) {
            st.lost_since = true;
            return;
        }
        const record: journal.Record = .{
            .frames = test_packet,
            .flags = .{
                .silent = silent,
                .timestamp_error = if (st.timestamp_error_every) |e| st.packets % e == 0 else false,
                .discontinuity = st.lost_since,
            },
            .len = len,
            .first_frame = st.position,
            .capture_qpc = qpc,
        };
        st.lost_since = false;
        @memcpy(st.pending.items[record_at..][0..@sizeOf(journal.Record)], std.mem.asBytes(&record));
    }
};

/// The track's captured records into the journal, as drain does: chunks of whole records.
fn writeAudio(r: *Recording, st: *SimTrack) void {
    var at: usize = 0;
    const bytes = st.pending.items;
    while (at < bytes.len) {
        var end = at;
        var frames: u32 = 0;
        var first: journal.Record = undefined;
        while (end < bytes.len) {
            const record = std.mem.bytesToValue(journal.Record, bytes[end..][0..@sizeOf(journal.Record)]);
            const len = @sizeOf(journal.Record) + record.len;
            if (end > at and end - at + len > test_chunk_bytes) break;
            if (end == at) first = record;
            frames += record.frames;
            end += len;
        }
        writeChunk(r, .{
            .len = @intCast(end - at),
            .track = st.id,
            .seq = st.seq,
            .kind = .audio,
            .frames = frames,
            .first_frame = first.first_frame,
            .capture_qpc = first.capture_qpc,
        }, &.{bytes[at..end]});
        st.seq += 1;
        at = end;
    }
    st.pending.clearRetainingCapacity();
}

/// What a crash point can look at.
const CrashView = struct {
    tick: u32,
    writer_segment: u32,
    compressor_segment: u32,
    oldest_segment: u32,
};

const CrashPoint = struct {
    name: []const u8,
    mode: Mode = .kill,
    /// When to crash (not for .finishing).
    when: *const fn (CrashView) bool = never,

    const Mode = enum {
        /// The process dies: what it wrote is on the disk (the system has it), what it held in
        /// memory is gone.
        kill,
        /// The power goes: what the journal had since its last flush is gone too.
        power_cut,
        /// The recording ended normally, and the process dies as it finishes: after the files
        /// are complete, before the checkpoint and journal are removed.
        finishing,
    };

    fn never(_: CrashView) bool {
        return false;
    }
};

const crash_points = [_]CrashPoint{
    .{ .name = "before the first checkpoint", .when = struct {
        fn f(v: CrashView) bool {
            return v.tick == 30;
        }
    }.f },
    .{ .name = "just after a checkpoint", .when = struct {
        fn f(v: CrashView) bool {
            return v.tick == 200;
        }
    }.f },
    .{ .name = "between checkpoints", .when = struct {
        fn f(v: CrashView) bool {
            return v.tick == 333;
        }
    }.f },
    .{ .name = "the writer in a journal file the compressor hasn't reached", .when = struct {
        fn f(v: CrashView) bool {
            return v.writer_segment > v.compressor_segment;
        }
    }.f },
    .{ .name = "recovery starting in an older journal file", .when = struct {
        fn f(v: CrashView) bool {
            return v.oldest_segment < v.compressor_segment;
        }
    }.f },
    .{ .name = "just after a device restart", .when = struct {
        fn f(v: CrashView) bool {
            return v.tick == 505;
        }
    }.f },
    .{ .name = "a track gone and back", .when = struct {
        fn f(v: CrashView) bool {
            return v.tick == 560;
        }
    }.f },
    .{ .name = "near the end", .when = struct {
        fn f(v: CrashView) bool {
            return v.tick == test_ticks - 10;
        }
    }.f },
    // A checkpoint (tick 200) after the last flush (tick 180): it must not cover journal
    // that a power cut loses.
    .{ .name = "power cut after a checkpoint, before the next flush", .mode = .power_cut, .when = struct {
        fn f(v: CrashView) bool {
            return v.tick == 205;
        }
    }.f },
    .{ .name = "power cut between checkpoints", .mode = .power_cut, .when = struct {
        fn f(v: CrashView) bool {
            return v.tick == 345;
        }
    }.f },
    .{ .name = "power cut with the writer in a journal file the compressor hasn't reached", .mode = .power_cut, .when = struct {
        fn f(v: CrashView) bool {
            return v.writer_segment > v.compressor_segment;
        }
    }.f },
    .{ .name = "while finishing", .mode = .finishing },
};

test "a recovered recording's files are the uninterrupted recording's" {
    global_gpa = std.testing.allocator;
    const gpa = std.testing.allocator;
    const kernel = try gpa.create(resample.Kernel);
    defer gpa.destroy(kernel);
    kernel.init();

    var root_buf: PathBuf = undefined;
    const root = testTempDir(&root_buf);
    defer removeTestDir(root);
    for (crash_points, 0..) |cp, i| {
        errdefer std.debug.print("crash point: {s}\n", .{cp.name});
        try crashAndRecover(gpa, kernel, root, i, cp);
    }
}

fn crashAndRecover(gpa: std.mem.Allocator, kernel: *const resample.Kernel, root: []const u16, index: usize, cp: CrashPoint) !void {
    var name_buf: [16]u8 = undefined;
    var a_buf: PathBuf = undefined;
    const a_dir = joinPath(&a_buf, root, std.fmt.bufPrint(&name_buf, "live{d}", .{index}) catch unreachable);
    var b_buf: PathBuf = undefined;
    const b_dir = joinPath(&b_buf, root, std.fmt.bufPrint(&name_buf, "crashed{d}", .{index}) catch unreachable);
    try std.testing.expect(try createNewDir(a_dir));
    try std.testing.expect(try createNewDir(b_dir));

    // Live: written and compressed together, up to the crash.
    const r = testRecording(a_dir, false);
    // The journal's write times are the real clock's, and a recording without recording_end
    // ends at its last one: so the session is timed as if it had just happened, its last
    // packet a little before the first write.
    const start_qpc = qpc100ns() - (test_ticks / 100 + 1) * 10_000_000;
    r.start_qpc = start_qpc;
    r.segment_capacity = test_journal_capacity;
    r.segment = try r.openSegment(0, test_journal_capacity, 0);
    var c: Compressor = .{ .recording = r, .chunk = try r.allocator().alignedAlloc(u8, .@"16", @sizeOf(journal.Header)), .kernel = kernel };
    try std.testing.expect(try startCompressor(&c));
    var sim: Sim = .{ .gpa = gpa, .start_qpc = start_qpc };
    defer sim.deinit();
    const crashed = for (0..test_ticks) |t| {
        const tick: u32 = @intCast(t);
        try sim.tick(r, tick);
        if (tick % flush_every == 0) flushSegment(r);
        if (tick % compressor_every == 0) _ = try advance(&c, r.progress.load(.acquire));
        if (tick > 0 and tick % checkpoint_every == 0) checkpoint(&c);
        if (cp.when(.{ .tick = tick, .writer_segment = r.segment_index, .compressor_segment = c.segment_index, .oldest_segment = c.oldest_segment })) {
            copyTestDir(a_dir, b_dir);
            break true;
        }
    } else false;

    switch (cp.mode) {
        .kill, .power_cut => {
            try std.testing.expect(crashed);
            if (cp.mode == .power_cut) {
                // What the journal had since its last flush never reached the disk.
                loseUnflushed(r, b_dir);
            } else {
                // Killed, the process's writes were all with the system: the live side gets
                // them all too.
                flushSegment(r);
            }
            // Live carries on as if the writer had stopped there (the journal ends where the
            // crash left it): the compressor reads the rest and finishes.
            win32.closeHandle(r.segment);
            while (try advance(&c, r.progress.load(.acquire)) == .progressed) {}
            try finish(&c);
        },
        .finishing => {
            try std.testing.expect(!crashed);
            writeChunk(r, .{ .len = 0, .track = 0, .seq = 0, .kind = .recording_end }, &.{});
            flushSegment(r);
            win32.closeHandle(r.segment);
            while (try advance(&c, r.progress.load(.acquire)) != .ended) {}
            try completeFiles(&c);
            copyTestDir(a_dir, b_dir);
            removeJournal(&c);
        },
    }
    r.allocator().free(c.chunk);
    try destroyTestRecording(r);

    // Crashed: recovered, as `blackbox recover` does.
    var failures: std.ArrayList(Recording.Failure) = .empty;
    defer failures.deinit(gpa);
    const recovery = recover(b_dir, &failures, gpa);
    for (failures.items) |f| std.debug.print("recovery failure (track {d}): {f}\n", .{ f.id, f.problem });
    try std.testing.expectEqual(@as(usize, 0), failures.items.len);
    if (recovery != .finished) std.debug.print("recovery: {any}\n", .{recovery});
    try std.testing.expect(recovery == .finished);

    try expectSameFiles(gpa, a_dir, b_dir);
}

/// In the crashed copy, the journal written since the last flush is gone, as after a power
/// cut: zeros where it was (on the disk, a sector is old or new, and either way it doesn't
/// carry on the chunk sequence).
fn loseUnflushed(r: *Recording, b_dir: [:0]const u16) void {
    const flushed_segment: u32 = @intCast(r.flushed >> 40);
    const zeros: [4096]u8 = @splat(0);
    // Journal files made since the last flush (nextSegment flushes the last file, then
    // starts the next): none of it reached the disk, its header included.
    var index = flushed_segment + 1;
    while (index <= r.segment_index) : (index += 1) {
        const h = openJournalCopy(b_dir, index);
        defer win32.closeHandle(h);
        if (!writeAt(h, 0, &zeros)) win32.panicWin32("WriteFile(journal copy)", win32.GetLastError());
    }
    // The flushed file, past what was flushed, when it's the one the writer was in.
    if (flushed_segment != r.segment_index) return;
    const h = openJournalCopy(b_dir, r.segment_index);
    defer win32.closeHandle(h);
    var at = r.flushed & ((1 << 40) - 1);
    while (at < r.segment_written) {
        const in_area = at % r.segment_capacity;
        const n = @min(r.segment_written - at, r.segment_capacity - in_area, zeros.len);
        if (!writeAt(h, journal.FileHeader.data_start + in_area, zeros[0..@intCast(n)])) win32.panicWin32("WriteFile(journal copy)", win32.GetLastError());
        at += n;
    }
}

fn openJournalCopy(dir: [:0]const u16, index: u32) win32.HANDLE {
    var name_buf: [32]u8 = undefined;
    var path_buf: PathBuf = undefined;
    const path = joinPath(&path_buf, dir, std.fmt.bufPrint(&name_buf, "journal-{d:0>6}.bbj", .{index}) catch unreachable);
    const h = win32.CreateFileW(path, .{ .FILE_WRITE_DATA = 1 }, .{}, null, .OPEN_EXISTING, .{ .FILE_ATTRIBUTE_NORMAL = 1 }, null);
    if (h == win32.INVALID_HANDLE_VALUE) win32.panicWin32("CreateFile(journal copy)", win32.GetLastError());
    return h;
}

/// A recording for a test to drive: no window, no threads, no lock.
fn testRecording(dir: [:0]const u16, recovering: bool) *Recording {
    const r = std.testing.allocator.create(Recording) catch @panic("out of memory");
    r.* = .{
        .hwnd = null,
        .dir = undefined,
        .started = std.mem.zeroes(win32.SYSTEMTIME),
        .start_qpc = 0,
        .stop_event = undefined,
        .compressor_event = undefined,
        .segment = undefined,
        .lock_file = undefined,
        .recovering = recovering,
    };
    r.dir = r.allocator().dupeSentinel(u16, dir, 0) catch @panic("out of memory");
    return r;
}

fn destroyTestRecording(r: *Recording) !void {
    for (r.failures.items) |f| std.debug.print("recording failure (track {d}): {f}\n", .{ f.id, f.problem });
    try std.testing.expectEqual(@as(usize, 0), r.failures.items.len);
    const gpa = r.allocator();
    r.failures.deinit(gpa);
    gpa.free(r.dir);
    if (builtin.mode == .debug) try std.testing.expect(r.debug_allocator.deinit() == .ok);
    std.testing.allocator.destroy(r);
}

/// Both folders hold the same FLAC files, byte for byte (aside from the crashed one's
/// RECOVERED tag), and nothing else: no journal or checkpoint left.
fn expectSameFiles(gpa: std.mem.Allocator, a_dir: [:0]const u16, b_dir: [:0]const u16) !void {
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    try listTestDir(gpa, a_dir, &names);
    var b_names: std.ArrayList([]u8) = .empty;
    defer {
        for (b_names.items) |n| gpa.free(n);
        b_names.deinit(gpa);
    }
    try listTestDir(gpa, b_dir, &b_names);
    try std.testing.expectEqual(names.items.len, b_names.items.len);
    try std.testing.expect(names.items.len > 0);
    for (names.items) |name| {
        errdefer std.debug.print("file: {s}\n", .{name});
        try std.testing.expect(std.mem.endsWith(u8, name, ".flac"));
        var pa: PathBuf = undefined;
        var pb: PathBuf = undefined;
        const a = readTestFile(gpa, joinPath(&pa, a_dir, name));
        defer gpa.free(a);
        const b = readTestFile(gpa, joinPath(&pb, b_dir, name));
        defer gpa.free(b);
        // The same length either way, so nothing after it moves.
        try std.testing.expect(std.mem.indexOf(u8, a, "RECOVERED=0") != null);
        const at = std.mem.indexOf(u8, b, "RECOVERED=1") orelse return error.TestNotRecovered;
        b[at + "RECOVERED=".len] = '0';
        errdefer std.debug.print("{d} bytes live, {d} recovered\n", .{ a.len, b.len });
        try std.testing.expect(std.mem.eql(u8, a, b));
    }
}

test "a damaged checkpoint is reported, not crashed on, and nothing is removed" {
    global_gpa = std.testing.allocator;
    const gpa = std.testing.allocator;
    var root_buf: PathBuf = undefined;
    const root = testTempDir(&root_buf);
    defer removeTestDir(root);
    var dir_buf: PathBuf = undefined;
    const dir = joinPath(&dir_buf, root, "damaged");
    try std.testing.expect(try createNewDir(dir));
    for ([_][]const u8{ "checkpoint.bin", "journal-000000.bbj" }) |name| {
        var path_buf: PathBuf = undefined;
        const h = win32.CreateFileW(joinPath(&path_buf, dir, name), .{ .FILE_WRITE_DATA = 1 }, .{}, null, .CREATE_NEW, .{ .FILE_ATTRIBUTE_NORMAL = 1 }, null);
        if (h == win32.INVALID_HANDLE_VALUE) win32.panicWin32("CreateFile(test)", win32.GetLastError());
        defer win32.closeHandle(h);
        const junk: [100]u8 = @splat(0xAB);
        try std.testing.expect(writeAt(h, 0, &junk));
    }
    var failures: std.ArrayList(Recording.Failure) = .empty;
    defer failures.deinit(gpa);
    const recovery = recover(dir, &failures, gpa);
    try std.testing.expect(recovery == .corrupt);
    try std.testing.expect(recovery.corrupt == .checkpoint_version);
    try std.testing.expect(unfinished(dir));
}

var test_dirs: u32 = 0;

fn testTempDir(buf: *PathBuf) [:0]const u16 {
    var tmp: [max_path]u16 = undefined;
    const n = win32.GetTempPathW(tmp.len, @ptrCast(&tmp));
    if (n == 0 or n >= tmp.len) win32.panicWin32("GetTempPath", win32.GetLastError());
    var name_buf: [64]u8 = undefined;
    // GetTempPath ends with a backslash.
    test_dirs += 1;
    const dir = joinPath(buf, tmp[0 .. n - 1], std.fmt.bufPrint(&name_buf, "BlackBoxTest-{d}-{d}", .{ win32.GetCurrentProcessId(), test_dirs }) catch unreachable);
    if (!(createNewDir(dir) catch |e| std.debug.panic("creating the test folder failed: {t}", .{e})))
        std.debug.panic("the test folder already exists", .{});
    return dir;
}

/// Calls `f(ctx, name)` for each file (not folder) in `dir`.
fn eachTestFile(dir: []const u16, ctx: anytype, comptime f: fn (@TypeOf(ctx), []const u16) void) void {
    var pattern_buf: PathBuf = undefined;
    const pattern = joinPath(&pattern_buf, dir, "*");
    var data: win32.WIN32_FIND_DATAW = undefined;
    const find = win32.FindFirstFileW(pattern, &data);
    // FindFileHandle: INVALID_HANDLE_VALUE as an integer.
    if (find == -1) win32.panicWin32("FindFirstFile", win32.GetLastError());
    defer _ = win32.FindClose(find);
    while (true) {
        if (data.dwFileAttributes & @as(u32, @bitCast(win32.FILE_ATTRIBUTE_DIRECTORY)) == 0)
            f(ctx, std.mem.sliceTo(&data.cFileName, 0));
        if (0 == win32.FindNextFileW(find, &data)) {
            if (win32.GetLastError() == .ERROR_NO_MORE_FILES) break;
            win32.panicWin32("FindNextFile", win32.GetLastError());
        }
    }
}

fn listTestDir(gpa: std.mem.Allocator, dir: []const u16, names: *std.ArrayList([]u8)) !void {
    const Ctx = struct {
        gpa: std.mem.Allocator,
        names: *std.ArrayList([]u8),
        fn add(ctx: @This(), name: []const u16) void {
            const utf8 = std.unicode.wtf16LeToWtf8Alloc(ctx.gpa, name) catch @panic("out of memory");
            ctx.names.append(ctx.gpa, utf8) catch @panic("out of memory");
        }
    };
    eachTestFile(dir, Ctx{ .gpa = gpa, .names = names }, Ctx.add);
}

/// Copies every file, as a crash leaves them: whatever's on the disk, files still open
/// included (opened sharing everything, as the recording's own handles allow).
fn copyTestDir(from: []const u16, to: []const u16) void {
    const Ctx = struct {
        from: []const u16,
        to: []const u16,
        fn copy(ctx: @This(), name: []const u16) void {
            var name_utf8: [3 * max_path]u8 = undefined;
            const n = std.unicode.wtf16LeToWtf8(&name_utf8, name);
            var src_buf: PathBuf = undefined;
            var dst_buf: PathBuf = undefined;
            const src = win32.CreateFileW(joinPath(&src_buf, ctx.from, name_utf8[0..n]), .{ .FILE_READ_DATA = 1 }, .{ .READ = 1, .WRITE = 1, .DELETE = 1 }, null, .OPEN_EXISTING, .{ .FILE_ATTRIBUTE_NORMAL = 1 }, null);
            if (src == win32.INVALID_HANDLE_VALUE) win32.panicWin32("CreateFile(copy from)", win32.GetLastError());
            defer win32.closeHandle(src);
            const dst = win32.CreateFileW(joinPath(&dst_buf, ctx.to, name_utf8[0..n]), .{ .FILE_WRITE_DATA = 1 }, .{}, null, .CREATE_NEW, .{ .FILE_ATTRIBUTE_NORMAL = 1 }, null);
            if (dst == win32.INVALID_HANDLE_VALUE) win32.panicWin32("CreateFile(copy to)", win32.GetLastError());
            defer win32.closeHandle(dst);
            var buf: [64 * 1024]u8 = undefined;
            while (true) {
                var got: u32 = undefined;
                if (0 == win32.ReadFile(src, &buf, buf.len, &got, null)) win32.panicWin32("ReadFile(copy)", win32.GetLastError());
                if (got == 0) break;
                var put: u32 = undefined;
                if (0 == win32.WriteFile(dst, &buf, got, &put, null) or put != got) win32.panicWin32("WriteFile(copy)", win32.GetLastError());
            }
        }
    };
    eachTestFile(from, Ctx{ .from = from, .to = to }, Ctx.copy);
}

/// Deletes the test folder and everything in it (folders one level down, files in those).
fn removeTestDir(dir: [:0]const u16) void {
    const Ctx = struct {
        dir: []const u16,
        fn delete(ctx: @This(), name: []const u16) void {
            var name_utf8: [3 * max_path]u8 = undefined;
            const n = std.unicode.wtf16LeToWtf8(&name_utf8, name);
            var path_buf: PathBuf = undefined;
            if (0 == win32.DeleteFileW(joinPath(&path_buf, ctx.dir, name_utf8[0..n]))) win32.panicWin32("DeleteFile(test)", win32.GetLastError());
        }
    };
    var pattern_buf: PathBuf = undefined;
    const pattern = joinPath(&pattern_buf, dir, "*");
    var data: win32.WIN32_FIND_DATAW = undefined;
    const find = win32.FindFirstFileW(pattern, &data);
    // FindFileHandle: INVALID_HANDLE_VALUE as an integer.
    if (find == -1) win32.panicWin32("FindFirstFile", win32.GetLastError());
    while (true) {
        const name = std.mem.sliceTo(&data.cFileName, 0);
        const is_dir = data.dwFileAttributes & @as(u32, @bitCast(win32.FILE_ATTRIBUTE_DIRECTORY)) != 0;
        const dot = std.mem.eql(u16, name, win32.L(".")) or std.mem.eql(u16, name, win32.L(".."));
        if (is_dir and !dot) {
            var name_utf8: [3 * max_path]u8 = undefined;
            const n = std.unicode.wtf16LeToWtf8(&name_utf8, name);
            var sub_buf: PathBuf = undefined;
            const sub = joinPath(&sub_buf, dir, name_utf8[0..n]);
            eachTestFile(sub, Ctx{ .dir = sub }, Ctx.delete);
            if (0 == win32.RemoveDirectoryW(sub)) win32.panicWin32("RemoveDirectory(test)", win32.GetLastError());
        }
        if (0 == win32.FindNextFileW(find, &data)) {
            if (win32.GetLastError() == .ERROR_NO_MORE_FILES) break;
            win32.panicWin32("FindNextFile", win32.GetLastError());
        }
    }
    _ = win32.FindClose(find);
    eachTestFile(dir, Ctx{ .dir = dir }, Ctx.delete);
    if (0 == win32.RemoveDirectoryW(dir)) win32.panicWin32("RemoveDirectory(test)", win32.GetLastError());
}

fn readTestFile(gpa: std.mem.Allocator, path: [:0]const u16) []u8 {
    const h = win32.CreateFileW(path, .{ .FILE_READ_DATA = 1 }, .{ .READ = 1 }, null, .OPEN_EXISTING, .{ .FILE_ATTRIBUTE_NORMAL = 1 }, null);
    if (h == win32.INVALID_HANDLE_VALUE) win32.panicWin32("CreateFile(read test file)", win32.GetLastError());
    defer win32.closeHandle(h);
    var size: win32.LARGE_INTEGER = undefined;
    if (0 == win32.GetFileSizeEx(h, &size)) win32.panicWin32("GetFileSizeEx", win32.GetLastError());
    const bytes = gpa.alloc(u8, @intCast(size.QuadPart)) catch @panic("out of memory");
    var got: u32 = undefined;
    if (0 == win32.ReadFile(h, bytes.ptr, @intCast(bytes.len), &got, null) or got != bytes.len) win32.panicWin32("ReadFile(test file)", win32.GetLastError());
    return bytes;
}
