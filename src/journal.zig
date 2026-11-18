//! The recording journal: the format of the raw files a recording is written to first.
//!
//! While recording, every source's data is appended to the journal as chunks, in the order it
//! arrives, so data captured around the same time sits close together on disk. Each source's
//! chunks are in order; different sources' chunks interleave. A background thread reads the
//! chunks back and writes the final per-track files (FLAC for audio, MP4 for video).
//!
//! A journal file is a ring on disk, like the audio rings in memory: a FileHeader, then a data
//! area of `capacity` bytes that the writer fills and the compressor frees, wrapping around.
//! Chunks never straddle the end: a padding chunk fills the rest of the area and the next chunk
//! starts at its beginning. When the writer would overwrite what the compressor hasn't read,
//! it ends the file with a segment_end chunk and continues in a new file twice the size; the
//! compressor deletes the old file once it's past that chunk and recovery can't need it.
//!
//! The journal describes itself (tracks are announced by a track_start chunk) and every chunk
//! has a sequence number and a CRC, so the final files can be rebuilt from it alone after a
//! crash: a scan stops at the first chunk that fails its CRC or breaks the sequence, which is
//! where new data ends and the previous lap's stale data begins.
//!
//! All fields are little-endian.

pub const magic: u32 = std.mem.readInt(u32, "BBCH", .little);

/// Chunks start and end on this boundary, so the room left before the end of the data area is
/// always a whole number of chunk headers.
pub const chunk_align = 64;

/// A journal file's first bytes; the data area starts at `data_start`.
pub const FileHeader = extern struct {
    magic: u32 = file_magic,
    version: u32 = 1,
    /// Its place in the recording's journal files: journal-000000.bbj is 0.
    index: u32,
    reserved: u32 = 0,
    /// Bytes in the data area: a multiple of chunk_align.
    capacity: u64,
    /// The journal_seq of the file's first chunk.
    first_seq: u64,
    /// When the recording started, QPC in 100ns units: for recording.json, also after a crash.
    start_qpc: u64,
    /// And in local time: year, month, day of week, day, hour, minute, second, milliseconds
    /// (Windows' SYSTEMTIME).
    started: [8]u16,

    pub const data_start = 4096;
};

pub const file_magic: u32 = std.mem.readInt(u32, "BBJF", .little);

pub const Kind = enum(u8) {
    /// A track's first chunk. Payload: TrackStart then its strings.
    track_start = 1,
    /// Audio, as the capture delivered it: the payload is Records, each followed by its
    /// samples. The header's frames, first_frame and capture_qpc sum up the records.
    audio = 2,
    /// The track ends: nothing more comes for it. No payload.
    track_end = 3,
    /// The recording ends: the journal's last chunk. No payload.
    recording_end = 4,
    /// Fills the rest of the data area: the next chunk is at its start. `len` covers the rest;
    /// the bytes there aren't part of the journal (and aren't in the CRC).
    padding = 5,
    /// The file's last chunk: the journal continues in the next file. No payload.
    segment_end = 6,
    /// A video track's first chunk. Payload: VideoTrackStart then its strings.
    video_track_start = 7,
    /// Encoded video, as the encoder delivered it: the payload is Records (`frames` 1, see
    /// Record), each followed by its frame. The header's frames, first_frame and capture_qpc
    /// sum up the records, as for audio.
    video = 8,
    _,
};

pub const Flags = packed struct(u8) {
    /// track_end: the track ended because the recording did, its source still going (not
    /// removed, not failed): a webcam's file shows no "NO VIDEO" after its last frame.
    recording_end: bool = false,
    _: u7 = 0,
};

/// One packet of audio in an audio chunk, followed by `len` bytes of samples in TrackStart's
/// format (none when silent). Or one frame of video in a video chunk, as the encoder gave it,
/// followed by `len` bytes: a VideoFrame, then the H.264 (Annex B: NAL units after start
/// codes). For video, `frames` is 1, `first_frame` the frame's number in the order the encoder
/// gave them (from the capture's first, each one more than the last), and `capture_qpc` when
/// it's shown.
pub const Record = extern struct {
    frames: u32,
    flags: RecordFlags,
    /// Bytes of samples after this record.
    len: u32,
    reserved: u32 = 0,
    /// The device's position (in frames) of the first frame. Positions that never came are
    /// gaps, filled with silence in the final file.
    first_frame: u64,
    /// When the first frame was captured, QPC in 100ns units, as WASAPI reports it.
    capture_qpc: u64,

    comptime {
        std.debug.assert(@sizeOf(Record) == 32);
    }
};

/// What a video record says beyond Record, before its H.264.
pub const VideoFrame = extern struct {
    /// When the frame is decoded, QPC in 100ns units, as the encoder gave it: frames shown
    /// ahead of others (B-frames) are decoded after them.
    decode_qpc: u64,
    /// Frames the encoder refused (it was busy) since the capture started: dropped.
    refused: u64,

    comptime {
        std.debug.assert(@sizeOf(VideoFrame) == 16);
    }
};

pub const RecordFlags = packed struct(u32) {
    /// Digital silence: `frames` of zeros, not stored.
    silent: bool = false,
    /// Windows said capture_qpc is wrong (AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR).
    timestamp_error: bool = false,
    /// Windows said audio was lost before this (AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY).
    /// first_frame says how much.
    discontinuity: bool = false,
    /// Video: a keyframe (an IDR picture, with its SPS and PPS), which decodes on its own.
    keyframe: bool = false,
    _: u28 = 0,
};

pub const Header = extern struct {
    magic: u32 = magic,
    /// CRC-32 of the rest of the header and the payload.
    crc: u32 = 0,
    /// Payload bytes.
    len: u32,
    /// The source's id. 0 for recording_end.
    track: u32,
    /// Counts each track's chunks from 0, so a missing or repeated chunk shows.
    seq: u32,
    kind: Kind,
    flags: Flags = .{},
    reserved0: u16 = 0,
    /// audio: how many frames, in all its records.
    frames: u32 = 0,
    reserved1: u32 = 0,
    /// audio: the first record's first_frame.
    first_frame: u64 = 0,
    /// audio: the first record's capture_qpc.
    capture_qpc: u64 = 0,
    /// When the writer wrote the chunk, QPC in 100ns units: how far behind capture it was.
    write_qpc: u64 = 0,
    /// Counts every chunk in the journal, across its files, from 0.
    journal_seq: u64 = 0,

    comptime {
        std.debug.assert(@sizeOf(Header) == 64);
    }

    /// Bytes the chunk takes in the data area, its alignment padding included.
    pub fn size(h: *const Header) u64 {
        return std.mem.alignForward(u64, @as(u64, @sizeOf(Header)) + h.len, chunk_align);
    }

    /// The CRC for this header and a payload in one or more pieces.
    pub fn computeCrc(h: *const Header, payload: []const []const u8) u32 {
        var c: std.hash.Crc32 = .init();
        c.update(std.mem.asBytes(h)[8..]);
        for (payload) |piece| c.update(piece);
        return c.final();
    }
};

/// A track_start chunk's payload starts with this, then `device_name_len` bytes of the
/// device's name and `file_name_len` bytes of the final file's name (UTF-8).
pub const TrackStart = extern struct {
    /// The samples, as captured.
    sample: SampleType,
    channels: u8,
    block_align: u16,
    rate: u32,
    /// The device's own format, if known (Sound settings' "Default Format").
    device_format_known: u8,
    device_sample: u8,
    device_bits: u16,
    device_rate: u32,
    device_channels: u16,
    /// Windows' audio effects were bypassed.
    raw: u8,
    reserved: u8 = 0,
    device_name_len: u16,
    file_name_len: u16,

    comptime {
        std.debug.assert(@sizeOf(TrackStart) == 24);
    }
};

pub const SampleType = enum(u8) { f32 = 1, i16 = 2, i24 = 3, i32 = 4, _ };

/// A video_track_start chunk's payload starts with this, then `device_name_len` bytes of the
/// device's name, `file_name_len` bytes of the final file's name and `encoder_name_len`
/// bytes of the encoder's name (UTF-8), then `novideo_len` bytes of what its file shows while
/// there's no video from the webcam: an mp4.NoVideoRun, frames the webcam's encoder made of
/// novideo.zig's picture, so whatever decodes the webcam's frames decodes them.
pub const VideoTrackStart = extern struct {
    /// Always h264 so far.
    codec: Codec,
    /// The encoder is the GPU's.
    hardware: u8,
    reserved0: u16 = 0,
    width: u32,
    height: u32,
    /// Frames per second, as a fraction, as the camera was asked for. Frames are timed by
    /// their capture times, not this.
    fps_num: u32,
    fps_den: u32,
    /// The encoder's target, bits per second.
    bitrate: u32,
    device_name_len: u16,
    file_name_len: u16,
    encoder_name_len: u16,
    reserved1: u16 = 0,
    novideo_len: u32,

    pub const Codec = enum(u8) { h264 = 1, _ };

    comptime {
        std.debug.assert(@sizeOf(VideoTrackStart) == 36);
    }
};

/// Fails, naming the field, unless `T.field` is at byte `offset`.
fn expectOffset(comptime T: type, comptime field: []const u8, offset: usize) !void {
    if (@offsetOf(T, field) == offset) return;
    std.debug.print("{s}.{s} is at byte {d}, version 1 has it at {d}\n", .{ @typeName(T), field, @offsetOf(T, field), offset });
    return error.TestExpectedEqual;
}

// Recovery reads journals an older or newer build wrote: a field that moves breaks every
// recording made before it. These are where version 1 has every field but the reserved ones.
test "the layout on disk" {
    try expectOffset(Header, "magic", 0);
    try expectOffset(Header, "crc", 4);
    try expectOffset(Header, "len", 8);
    try expectOffset(Header, "track", 12);
    try expectOffset(Header, "seq", 16);
    try expectOffset(Header, "kind", 20);
    try expectOffset(Header, "flags", 21);
    try expectOffset(Header, "frames", 24);
    try expectOffset(Header, "first_frame", 32);
    try expectOffset(Header, "capture_qpc", 40);
    try expectOffset(Header, "write_qpc", 48);
    try expectOffset(Header, "journal_seq", 56);

    try expectOffset(FileHeader, "magic", 0);
    try expectOffset(FileHeader, "version", 4);
    try expectOffset(FileHeader, "index", 8);
    try expectOffset(FileHeader, "capacity", 16);
    try expectOffset(FileHeader, "first_seq", 24);
    try expectOffset(FileHeader, "start_qpc", 32);
    try expectOffset(FileHeader, "started", 40);
    try std.testing.expectEqual(56, @sizeOf(FileHeader));

    try expectOffset(Record, "frames", 0);
    try expectOffset(Record, "flags", 4);
    try expectOffset(Record, "len", 8);
    try expectOffset(Record, "first_frame", 16);
    try expectOffset(Record, "capture_qpc", 24);
    try std.testing.expectEqual(0, @bitOffsetOf(RecordFlags, "silent"));
    try std.testing.expectEqual(1, @bitOffsetOf(RecordFlags, "timestamp_error"));
    try std.testing.expectEqual(2, @bitOffsetOf(RecordFlags, "discontinuity"));
    try std.testing.expectEqual(3, @bitOffsetOf(RecordFlags, "keyframe"));

    // Chunk kinds are numbers on the disk too.
    const kinds = [_]struct { Kind, u8 }{
        .{ .track_start, 1 }, .{ .audio, 2 },             .{ .track_end, 3 }, .{ .recording_end, 4 },
        .{ .padding, 5 },     .{ .segment_end, 6 },       .{ .video_track_start, 7 }, .{ .video, 8 },
    };
    for (kinds) |k| try std.testing.expectEqual(k[1], @intFromEnum(k[0]));

    try expectOffset(TrackStart, "sample", 0);
    try expectOffset(TrackStart, "channels", 1);
    try expectOffset(TrackStart, "block_align", 2);
    try expectOffset(TrackStart, "rate", 4);
    try expectOffset(TrackStart, "device_format_known", 8);
    try expectOffset(TrackStart, "device_sample", 9);
    try expectOffset(TrackStart, "device_bits", 10);
    try expectOffset(TrackStart, "device_rate", 12);
    try expectOffset(TrackStart, "device_channels", 16);
    try expectOffset(TrackStart, "raw", 18);
    try expectOffset(TrackStart, "device_name_len", 20);
    try expectOffset(TrackStart, "file_name_len", 22);

    try expectOffset(VideoTrackStart, "codec", 0);
    try expectOffset(VideoTrackStart, "hardware", 1);
    try expectOffset(VideoTrackStart, "width", 4);
    try expectOffset(VideoTrackStart, "height", 8);
    try expectOffset(VideoTrackStart, "fps_num", 12);
    try expectOffset(VideoTrackStart, "fps_den", 16);
    try expectOffset(VideoTrackStart, "bitrate", 20);
    try expectOffset(VideoTrackStart, "device_name_len", 24);
    try expectOffset(VideoTrackStart, "file_name_len", 26);
    try expectOffset(VideoTrackStart, "encoder_name_len", 28);
    try std.testing.expectEqual(1, @intFromEnum(VideoTrackStart.Codec.h264));

    const h: Header = .{ .len = 0, .track = 0, .seq = 0, .kind = .audio };
    try std.testing.expectEqualStrings("BBCH", std.mem.asBytes(&h)[0..4]);
    const f: FileHeader = .{ .index = 0, .capacity = 0, .first_seq = 0, .start_qpc = 0, .started = @splat(0) };
    try std.testing.expectEqualStrings("BBJF", std.mem.asBytes(&f)[0..4]);
    try std.testing.expect(@sizeOf(FileHeader) <= FileHeader.data_start);
    try std.testing.expectEqual(0, FileHeader.data_start % chunk_align);
}

test "Header.size" {
    const cases = [_]struct { u32, u64 }{
        .{ 0, 64 },
        .{ 1, 128 },
        .{ 64, 128 },
        .{ 65, 192 },
        // The largest payload a header can describe: no overflow.
        .{ std.math.maxInt(u32), (1 << 32) + 64 },
    };
    for (cases) |c| {
        const h: Header = .{ .len = c[0], .track = 1, .seq = 0, .kind = .audio };
        try std.testing.expectEqual(c[1], h.size());
        try std.testing.expectEqual(0, h.size() % chunk_align);
    }
}

/// The journal_seq of testChunk's chunk.
const test_seq = 4242;

/// An audio chunk of one Record and its samples, as the writer lays it out: header, payload,
/// then alignment padding. Returns its bytes in `buf`.
fn testChunk(buf: []align(8) u8) []u8 {
    const samples = [_]i16{ 0, 1000, -1000, 32767, -32768, 7, -7, 12345 };
    const record: Record = .{ .frames = 4, .flags = .{ .discontinuity = true }, .len = @sizeOf(@TypeOf(samples)), .first_frame = 480_000, .capture_qpc = 123_456_789 };
    const payload: [2][]const u8 = .{ std.mem.asBytes(&record), std.mem.sliceAsBytes(&samples) };
    var h: Header = .{
        .len = @intCast(payload[0].len + payload[1].len),
        .track = 3,
        .seq = 17,
        .kind = .audio,
        .frames = record.frames,
        .first_frame = record.first_frame,
        .capture_qpc = record.capture_qpc,
        .write_qpc = 123_999_999,
        .journal_seq = test_seq,
    };
    h.crc = h.computeCrc(&payload);
    const chunk = buf[0..@intCast(h.size())];
    // Whatever was in the ring before: alignment padding isn't written, nor in the CRC.
    @memset(chunk, 0xA5);
    @memcpy(chunk[0..@sizeOf(Header)], std.mem.asBytes(&h));
    @memcpy(chunk[@sizeOf(Header)..][0..payload[0].len], payload[0]);
    @memcpy(chunk[@sizeOf(Header) + payload[0].len ..][0..payload[1].len], payload[1]);
    return chunk;
}

/// Whether the chunk at the start of `area` (the rest of the data area) passes the checks
/// readChunks in record.zig makes: its magic, the journal_seq expected next, that it fits in
/// the area, and its CRC, which covers no payload for padding.
fn testChunkOk(area: []const u8, next_seq: u64) bool {
    const h = std.mem.bytesToValue(Header, area[0..@sizeOf(Header)]);
    if (h.magic != magic or h.journal_seq != next_seq or h.size() > area.len) return false;
    const payload_len: usize = if (h.kind == .padding) 0 else h.len;
    return h.computeCrc(&.{area[@sizeOf(Header)..][0..payload_len]}) == h.crc;
}

test "a chunk round-trips, its CRC computed from any split of the payload" {
    var buf: [256]u8 align(8) = @splat(0x5A);
    const chunk = testChunk(&buf);
    try std.testing.expectEqual(128, chunk.len);
    try std.testing.expect(testChunkOk(&buf, test_seq));
    // The previous lap's chunk at the same place: its journal_seq is older.
    try std.testing.expect(!testChunkOk(&buf, test_seq + 1));

    const h = std.mem.bytesToValue(Header, chunk[0..@sizeOf(Header)]);
    try std.testing.expectEqual(magic, h.magic);
    try std.testing.expectEqual(Kind.audio, h.kind);
    try std.testing.expectEqual(test_seq, h.journal_seq);
    const r = std.mem.bytesToValue(Record, chunk[@sizeOf(Header)..][0..@sizeOf(Record)]);
    try std.testing.expectEqual(4, r.frames);
    try std.testing.expect(r.flags.discontinuity and !r.flags.silent and !r.flags.timestamp_error);
    try std.testing.expectEqual(480_000, r.first_frame);
    try std.testing.expectEqual(@sizeOf(Record) + r.len, h.len);

    // The writer passes the payload in pieces (records and samples straight from the ring);
    // recovery reads it whole.
    const payload = chunk[@sizeOf(Header)..][0..h.len];
    for (0..payload.len + 1) |split| {
        try std.testing.expectEqual(h.crc, h.computeCrc(&.{ payload[0..split], payload[split..] }));
    }
    try std.testing.expectEqual(h.crc, h.computeCrc(&.{ "", payload, "" }));
}

// What the checks are for: a scan must stop where the journal's new data ends, so it may never
// take damaged or half-written data for a chunk.
test "damaged and half-written chunks are caught" {
    var buf: [256]u8 align(8) = @splat(0x5A);
    const chunk = testChunk(&buf);
    const h = std.mem.bytesToValue(Header, chunk[0..@sizeOf(Header)]);
    const end = @sizeOf(Header) + h.len;

    // Every bit of the header and the payload: the magic, the CRC itself, and what it covers.
    for (0..end) |i| for (0..8) |bit| {
        chunk[i] ^= @as(u8, 1) << @intCast(bit);
        defer chunk[i] ^= @as(u8, 1) << @intCast(bit);
        if (testChunkOk(&buf, test_seq)) {
            std.debug.print("flipping bit {d} of byte {d} went unnoticed\n", .{ bit, i });
            return error.TestUnexpectedResult;
        }
    };
    // Not the alignment padding after the payload, which is never written.
    @memset(chunk[end..], 0x00);
    try std.testing.expect(testChunkOk(&buf, test_seq));

    // Torn: the write stopped partway, leaving the previous lap's bytes, or a new file's
    // zeros, after it. Wherever it stopped inside the payload.
    var torn: [256]u8 align(8) = @splat(0x5A);
    for (@sizeOf(Header)..end) |stop| {
        for ([_]u8{ 0x00, 0xA5 }) |stale| {
            @memcpy(torn[0..chunk.len], chunk);
            @memset(torn[stop..end], stale);
            // Unless the stale bytes happen to be what would've been written.
            if (std.mem.eql(u8, torn[stop..end], chunk[stop..end])) continue;
            if (testChunkOk(&torn, test_seq)) {
                std.debug.print("a write torn at byte {d} over 0x{x} went unnoticed\n", .{ stop, stale });
                return error.TestUnexpectedResult;
            }
        }
    }

    // A header claiming less payload than was written, or more: reaching into the stale bytes
    // after the chunk, or past the end of the area.
    @memcpy(torn[0..chunk.len], chunk);
    for ([_]u32{ h.len - 1, 0, h.len + 64, h.len + 128, 1 << 20 }) |len| {
        var bad = h;
        bad.len = len;
        @memcpy(torn[0..@sizeOf(Header)], std.mem.asBytes(&bad));
        if (testChunkOk(&torn, test_seq)) {
            std.debug.print("a header claiming {d} bytes of payload, not {d}, went unnoticed\n", .{ len, h.len });
            return error.TestUnexpectedResult;
        }
    }
}

// Padding fills the rest of the data area with bytes that aren't the journal's: its CRC is
// the header's alone, so whatever the bytes are, it passes.
test "a padding chunk's CRC is its header's" {
    var area: [256]u8 align(8) = @splat(0x5A);
    var h: Header = .{ .len = area.len - @sizeOf(Header), .track = 0, .seq = 0, .kind = .padding, .journal_seq = test_seq };
    h.crc = h.computeCrc(&.{});
    @memcpy(area[0..@sizeOf(Header)], std.mem.asBytes(&h));
    try std.testing.expect(testChunkOk(&area, test_seq));
    @memset(area[@sizeOf(Header)..], 0xA5);
    try std.testing.expect(testChunkOk(&area, test_seq));
    // Its header is still checked.
    area[@offsetOf(Header, "len")] ^= 0x40;
    try std.testing.expect(!testChunkOk(&area, test_seq));
}

const std = @import("std");
