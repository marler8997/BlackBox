//! Fragmented MP4 (ISO/IEC 14496-12, H.264 per 14496-15) for recorded video: an init segment
//! (ftyp, moov) when the first keyframe arrives, then a fragment (moof, mdat) at a time, and at
//! the end a seek index (mfra) with the durations and tags filled in. A fragment is complete on
//! its own, so a file cut short after any fragment plays up to there. Fragments start at
//! keyframes (and a few limits), never at the caller's whim, so the same frames always make the
//! same file: the compressor's checkpoints save the muxer as it was when the fragment being
//! made started (Muxer.checkpoint), and recovery adds that fragment's frames again from the
//! journal.
//!
//! Times are QPC in 100ns units (timescale 10 MHz), counted from the recording's start: no
//! edit list, each frame is shown at the time the encoder gave it, so video lines up with the
//! recording's FLAC tracks, which start at its start.
//!
//! Frames are stored in the order the encoder gives them (decode order), whatever order they're
//! shown in (B-frames are shown after frames decoded later): each frame's duration is to the
//! next one's decode time, and its composition offset (trun, signed) is from its decode time to
//! when it's shown. Decode times are the encoder's, shifted so the first frame's is when it's
//! shown: a fragment's decode time (tfdt) can't be before the file's start.

pub const timescale = 10_000_000;
/// mvhd's, tkhd's and mehd's unit: milliseconds.
const movie_timescale = 1000;

/// The most frames a fragment holds: the muxer ends one at least this often, so its moof fits
/// moof_max_len.
pub const fragment_max_frames = 512;
pub const moof_max_len = 128 + fragment_max_frames * trun_entry_len;
/// Duration, size, flags and composition offset.
const trun_entry_len = 16;

/// The longest SPS or PPS taken: real ones are tens of bytes.
pub const max_parameter_set = 256;

/// The init segment's room for tags (moov's last box, udta), filled in when the file is
/// finished (see Muxer.patches), as a FLAC file's tags area is.
pub const tags_area = 4096;

/// What the init segment says about the video.
pub const Video = struct {
    width: u32,
    height: u32,
    sps: []const u8,
    pps: []const u8,
};

/// What a webcam's file shows while there's no video from it (see Muxer.novideo): a run of
/// frames an encoder made of one picture, a frame every `interval`, repeated for as long as
/// it's needed, so it plays as ordinary video (a frame lasting seconds is one a player may
/// never show). This header, then `frames` NoVideoFrames, each followed by its H.264 (Annex
/// B), in the order the encoder gave them: the first a keyframe, decoded and shown at the
/// run's start, then decode times increasing, every frame shown and decoded within the run.
pub const NoVideoRun = extern struct {
    /// Between frames, timescale units: the run repeats every frames * interval.
    interval: u32,
    frames: u32,

    pub const Parsed = struct {
        header: NoVideoRun,
        rest: []const u8,

        pub fn iterator(r: Parsed) Iterator {
            return .{ .bytes = r.rest };
        }
    };

    pub const Iterator = struct {
        bytes: []const u8,

        /// The next frame, checked as parse did.
        pub fn next(it: *Iterator) Error!?struct { frame: NoVideoFrame, h264: []const u8 } {
            if (it.bytes.len == 0) return null;
            if (it.bytes.len < @sizeOf(NoVideoFrame)) return error.BadStream;
            const frame = std.mem.bytesToValue(NoVideoFrame, it.bytes[0..@sizeOf(NoVideoFrame)]);
            if (it.bytes.len - @sizeOf(NoVideoFrame) < frame.len) return error.BadStream;
            const h264 = it.bytes[@sizeOf(NoVideoFrame)..][0..frame.len];
            it.bytes = it.bytes[@sizeOf(NoVideoFrame) + frame.len ..];
            return .{ .frame = frame, .h264 = h264 };
        }
    };

    /// Fails with BadStream unless `bytes` is a run as described.
    pub fn parse(bytes: []const u8) Error!Parsed {
        if (bytes.len < @sizeOf(NoVideoRun)) return error.BadStream;
        const header = std.mem.bytesToValue(NoVideoRun, bytes[0..@sizeOf(NoVideoRun)]);
        if (header.interval == 0 or header.frames == 0 or header.frames > fragment_max_frames) return error.BadStream;
        const parsed: Parsed = .{ .header = header, .rest = bytes[@sizeOf(NoVideoRun)..] };
        const cycle = @as(u64, header.interval) * header.frames;
        var it = parsed.iterator();
        var n: u32 = 0;
        var last_decode: u32 = 0;
        while (try it.next()) |f| : (n += 1) {
            if (n == 0) {
                if (f.frame.keyframe != 1 or f.frame.shown != 0 or f.frame.decode != 0) return error.BadStream;
            } else if (f.frame.decode <= last_decode or f.frame.keyframe > 1) return error.BadStream;
            if (f.frame.shown >= cycle or f.frame.decode >= cycle) return error.BadStream;
            last_decode = f.frame.decode;
        }
        if (n != header.frames) return error.BadStream;
        return parsed;
    }
};

/// A frame of a NoVideoRun, before its H.264.
pub const NoVideoFrame = extern struct {
    /// Bytes of H.264 after this.
    len: u32,
    /// 0 or 1.
    keyframe: u8,
    reserved: [3]u8 = @splat(0),
    /// From the run's start, timescale units: when it's shown, and when it's decoded.
    shown: u32,
    decode: u32,
};

/// A frame in a fragment.
pub const Sample = struct {
    /// Bytes in mdat (length-prefixed NAL units, see toLengthPrefixed).
    size: u32,
    /// Until the next frame's decode time, in timescale units.
    duration: u32,
    /// From its decode time to when it's shown.
    offset: i32,
    keyframe: bool,
};

pub const Error = error{
    /// An SPS this writer can't read (or one too short to be one).
    BadSps,
    /// NAL units that aren't Annex B, or a first parameter set longer than max_parameter_set.
    BadStream,
};

/// Where the init segment has what's filled in at the end (offsets from its start, which is
/// the file's).
pub const Layout = struct {
    mvhd_duration: usize,
    tkhd_duration: usize,
    mehd_duration: usize,
    udta: usize,
    len: usize,
};

/// The longest init segment: its fixed boxes, the parameter sets and the tags area.
pub const init_max_len = 1024 + 2 * max_parameter_set + tags_area;

/// ftyp and moov: what decodes the fragments that follow, into `buf`. `track_id` is always 1.
/// The sample entry is avc3: parameter sets are in the stream too, and may change (see
/// toLengthPrefixed); avcC has the first ones. The durations are 0 and the tags area empty
/// until the file is finished.
pub fn writeInit(buf: *[init_max_len]u8, video: Video) Error!Layout {
    const sps_info = try parseSps(video.sps);
    if (video.pps.len == 0 or video.pps.len > max_parameter_set) return error.BadStream;
    var layout: Layout = undefined;
    var b: Boxes = .{ .buf = buf };

    b.open("ftyp");
    b.bytes("isom");
    b.int(u32, 0x200);
    b.bytes("isomiso6avc1mp41");
    b.close();

    b.open("moov");
    {
        b.full("mvhd", 0, 0);
        b.int(u32, 0); // creation time
        b.int(u32, 0); // modification time
        b.int(u32, movie_timescale);
        layout.mvhd_duration = b.len;
        b.int(u32, 0); // duration: filled in at the end
        b.int(u32, 0x00010000); // rate 1.0
        b.int(u16, 0x0100); // volume 1.0
        b.zeros(10);
        b.matrix();
        b.zeros(24); // pre_defined
        b.int(u32, 2); // next track id
        b.close();

        b.open("trak");
        {
            b.full("tkhd", 0, 0x000003); // enabled, in movie
            b.int(u32, 0);
            b.int(u32, 0);
            b.int(u32, 1); // track id
            b.int(u32, 0);
            layout.tkhd_duration = b.len;
            b.int(u32, 0); // duration: filled in at the end
            b.zeros(8);
            b.int(u16, 0); // layer
            b.int(u16, 0); // alternate group
            b.int(u16, 0); // volume: video has none
            b.int(u16, 0);
            b.matrix();
            b.int(u32, video.width << 16);
            b.int(u32, video.height << 16);
            b.close();

            b.open("mdia");
            {
                b.full("mdhd", 0, 0);
                b.int(u32, 0);
                b.int(u32, 0);
                b.int(u32, timescale);
                b.int(u32, 0);
                b.int(u16, 0x55C4); // language: undetermined ("und")
                b.int(u16, 0);
                b.close();

                b.full("hdlr", 0, 0);
                b.int(u32, 0);
                b.bytes("vide");
                b.zeros(12);
                b.bytes("Black Box video\x00");
                b.close();

                b.open("minf");
                {
                    b.full("vmhd", 0, 1);
                    b.zeros(8);
                    b.close();

                    b.open("dinf");
                    b.full("dref", 0, 0);
                    b.int(u32, 1);
                    b.full("url ", 0, 1); // the data is in this file
                    b.close();
                    b.close();
                    b.close();

                    b.open("stbl");
                    {
                        b.full("stsd", 0, 0);
                        b.int(u32, 1);
                        b.open("avc3");
                        {
                            b.zeros(6);
                            b.int(u16, 1); // data reference index
                            b.zeros(16);
                            b.int(u16, @intCast(video.width));
                            b.int(u16, @intCast(video.height));
                            b.int(u32, 0x00480000); // 72 dpi
                            b.int(u32, 0x00480000);
                            b.int(u32, 0);
                            b.int(u16, 1); // frames per sample
                            b.zeros(32); // compressor name
                            b.int(u16, 0x0018); // depth: color
                            b.int(i16, -1);

                            b.open("avcC");
                            b.int(u8, 1); // version
                            b.int(u8, video.sps[1]); // profile
                            b.int(u8, video.sps[2]); // constraint flags
                            b.int(u8, video.sps[3]); // level
                            b.int(u8, 0xFC | 3); // 4-byte NAL lengths
                            b.int(u8, 0xE0 | 1); // one SPS
                            b.int(u16, @intCast(video.sps.len));
                            b.bytes(video.sps);
                            b.int(u8, 1); // one PPS
                            b.int(u16, @intCast(video.pps.len));
                            b.bytes(video.pps);
                            if (sps_info.high) {
                                b.int(u8, 0xFC | @as(u8, sps_info.chroma_format));
                                b.int(u8, 0xF8 | @as(u8, sps_info.bit_depth_luma_minus8));
                                b.int(u8, 0xF8 | @as(u8, sps_info.bit_depth_chroma_minus8));
                                b.int(u8, 0); // no SPS extensions
                            }
                            b.close();
                        }
                        b.close();
                        b.close();

                        // Empty tables: the samples are in the fragments.
                        for ([_]*const [4]u8{ "stts", "stsc", "stco" }) |name| {
                            b.full(name, 0, 0);
                            b.int(u32, 0);
                            b.close();
                        }
                        b.full("stsz", 0, 0);
                        b.int(u32, 0);
                        b.int(u32, 0);
                        b.close();
                    }
                    b.close();
                }
                b.close();
            }
            b.close();
        }
        b.close();

        b.open("mvex");
        b.full("mehd", 1, 0);
        layout.mehd_duration = b.len;
        b.int(u64, 0); // the fragments' duration: filled in at the end
        b.close();
        b.full("trex", 0, 0);
        b.int(u32, 1); // track id
        b.int(u32, 1); // default sample description index
        b.int(u32, 0);
        b.int(u32, 0);
        b.int(u32, 0);
        b.close();
        b.close();

        layout.udta = b.len;
        writeTags(b.buf[b.len..][0..tags_area], &.{});
        b.len += tags_area;
    }
    b.close();
    layout.len = b.len;
    return layout;
}

/// A fragment's moof and its mdat's header, into `buf` (moof_max_len): the frames' bytes
/// (their sizes' sum) follow the returned bytes in the file. `sequence` counts fragments from
/// 1; `decode_time` is the first frame's.
pub fn fragmentHeader(buf: *[moof_max_len + 8]u8, sequence: u32, decode_time: u64, samples: []const Sample) []const u8 {
    std.debug.assert(samples.len > 0 and samples.len <= fragment_max_frames);
    var b: Boxes = .{ .buf = buf };
    var data_len: u64 = 0;
    for (samples) |s| data_len += s.size;
    b.open("moof");
    b.full("mfhd", 0, 0);
    b.int(u32, sequence);
    b.close();
    b.open("traf");
    b.full("tfhd", 0, 0x020000); // default-base-is-moof
    b.int(u32, 1); // track id
    b.close();
    b.full("tfdt", 1, 0);
    b.int(u64, decode_time);
    b.close();
    // data offset, and each sample's duration, size, flags and composition offset (version 1:
    // signed).
    b.full("trun", 1, trun_flags);
    b.int(u32, @intCast(samples.len));
    const data_offset_at = b.len;
    b.int(u32, 0);
    for (samples) |s| {
        b.int(u32, s.duration);
        b.int(u32, s.size);
        // A keyframe depends on nothing; other frames depend on others and aren't sync points.
        b.int(u32, if (s.keyframe) keyframe_flags else other_flags);
        b.int(i32, s.offset);
    }
    b.close();
    b.close();
    b.close();
    // The data starts after moof and mdat's header.
    std.mem.writeInt(u32, buf[data_offset_at..][0..4], @intCast(b.len + 8), .big);
    b.int(u32, @intCast(8 + data_len));
    b.bytes("mdat");
    return b.written();
}

const keyframe_flags = 0x02000000;
const other_flags = 0x01010000;
/// trun has a data offset, and per sample a duration, size, flags and composition offset.
const trun_flags = 0x000F01;

/// What a fragment's moof says, for rebuilding the seek index from a file (see Muxer.restore).
pub const MoofInfo = struct {
    sequence: u32,
    decode_time: u64,
    /// When its first frame is shown.
    time: u64,
    /// Its first frame is a keyframe: a place to seek to.
    keyframe: bool,
};

/// Reads back a moof that fragmentHeader wrote (its body, after the 8-byte box header).
pub fn parseMoof(body: []const u8) error{BadFragment}!MoofInfo {
    var r: BoxReader = .{ .bytes = body };
    const mfhd = try r.expect("mfhd", 8);
    var traf: BoxReader = .{ .bytes = try r.expect("traf", 0) };
    _ = try traf.expect("tfhd", 8);
    const tfdt = try traf.expect("tfdt", 12);
    if (tfdt[0] != 1) return error.BadFragment;
    // Version and flags, sample count, data offset, then the first sample.
    const trun = try traf.expect("trun", 12 + trun_entry_len);
    if (std.mem.readInt(u32, trun[0..4], .big) != @as(u32, 1 << 24 | trun_flags)) return error.BadFragment;
    const decode_time = std.mem.readInt(u64, tfdt[4..12], .big);
    const time = std.math.cast(u64, @as(i65, decode_time) + std.mem.readInt(i32, trun[24..28], .big)) orelse return error.BadFragment;
    return .{
        .sequence = std.mem.readInt(u32, mfhd[4..8], .big),
        .decode_time = decode_time,
        .time = time,
        .keyframe = std.mem.readInt(u32, trun[20..24], .big) == keyframe_flags,
    };
}

/// Boxes in a byte slice, one after another, for parseMoof.
const BoxReader = struct {
    bytes: []const u8,
    at: usize = 0,

    /// The next box's body: it must be named `name` and at least `min_len` long.
    fn expect(r: *BoxReader, name: *const [4]u8, min_len: usize) error{BadFragment}![]const u8 {
        if (r.bytes.len - r.at < 8) return error.BadFragment;
        const size = std.mem.readInt(u32, r.bytes[r.at..][0..4], .big);
        if (size < 8 + min_len or size > r.bytes.len - r.at or !std.mem.eql(u8, r.bytes[r.at + 4 ..][0..4], name)) return error.BadFragment;
        defer r.at += size;
        return r.bytes[r.at + 8 .. r.at + size];
    }
};

/// Recovering: checks the file a checkpoint left (`len` bytes, through `source.read(buf,
/// offset)`) is what the muxer (a Muxer) wrote, an init segment then fragments numbered up to
/// its next one's, and gives the muxer its seek index back. Fails with BadFragment if it
/// isn't, or the read's error.
pub fn scan(m: anytype, gpa: std.mem.Allocator, source: anytype, len: u64) (error{BadFragment} || @TypeOf(source).Error)!void {
    std.debug.assert(m.seek_points.items.len == 0);
    const started = switch (m.state) {
        .waiting => return if (len != 0) error.BadFragment,
        .started => |s| s,
    };
    var init_buf: [init_max_len]u8 = undefined;
    const layout = writeInit(&init_buf, .{ .width = m.width, .height = m.height, .sps = started.sets.sps(), .pps = started.sets.pps() }) catch return error.BadFragment;
    var at: u64 = layout.len;
    if (len < at) return error.BadFragment;
    var sequence: u32 = 1;
    var moof_buf: [moof_max_len]u8 = undefined;
    while (at < len) {
        if (len - at < 8) return error.BadFragment;
        var header: [8]u8 = undefined;
        try source.read(&header, at);
        const size = std.mem.readInt(u32, header[0..4], .big);
        if (size < 8 or size > len - at or !std.mem.eql(u8, header[4..8], "moof") or size - 8 > moof_buf.len) return error.BadFragment;
        const body = moof_buf[0 .. size - 8];
        try source.read(body, at + 8);
        const info = try parseMoof(body);
        if (info.sequence != sequence) return error.BadFragment;
        if (info.keyframe) m.addSeekPoint(gpa, .{ .time = info.time, .offset = at });
        at += size;
        // Its mdat.
        if (len - at < 8) return error.BadFragment;
        try source.read(&header, at);
        const mdat_size = std.mem.readInt(u32, header[0..4], .big);
        if (mdat_size < 8 or mdat_size > len - at or !std.mem.eql(u8, header[4..8], "mdat")) return error.BadFragment;
        at += mdat_size;
        sequence += 1;
    }
    if (sequence != started.sequence) return error.BadFragment;
}

/// A fragment that starts with a keyframe: an entry in the seek index (mfra).
pub const SeekPoint = struct {
    time: u64,
    /// Its moof's offset in the file.
    offset: u64,
};

/// The seek index (mfra: a tfra listing the keyframe fragments, then mfro), appended when the
/// file is finished: players that want one find it from the file's end.
pub fn writeIndex(w: *std.Io.Writer, points: []const SeekPoint) error{WriteFailed}!u64 {
    const entry_len = 8 + 8 + 3;
    const tfra_len: u32 = @intCast(8 + 4 + 12 + points.len * entry_len);
    const mfro_len = 16;
    const len = 8 + tfra_len + mfro_len;
    try w.writeInt(u32, len, .big);
    try w.writeAll("mfra");
    try w.writeInt(u32, tfra_len, .big);
    try w.writeAll("tfra");
    try w.writeInt(u32, 0x01000000, .big); // version 1: 64-bit times and offsets
    try w.writeInt(u32, 1, .big); // track id
    try w.writeInt(u32, 0, .big); // 1-byte traf, trun and sample numbers
    try w.writeInt(u32, @intCast(points.len), .big);
    for (points) |p| {
        try w.writeInt(u64, p.time, .big);
        try w.writeInt(u64, p.offset, .big);
        // The first traf, trun and sample of the fragment (numbered from 1).
        try w.writeAll(&.{ 1, 1, 1 });
    }
    try w.writeInt(u32, mfro_len, .big);
    try w.writeAll("mfro");
    try w.writeInt(u32, 0, .big);
    try w.writeInt(u32, len, .big);
    return len;
}

/// A tag for the tags area: a standard one (an iTunes-style four-character name like ©nam) or
/// a freeform one (a name like RECORDING_START_QPC), with a UTF-8 value.
pub const Tag = struct {
    name: []const u8,
    value: []const u8,
};

/// Standard tags' names: title, date, encoding tool.
pub const tag_title = "\xA9nam";
pub const tag_date = "\xA9day";
pub const tag_tool = "\xA9too";

/// The tags area: udta { meta { hdlr, ilst { tags } } }, then a free box filling the rest, so
/// the area is always tags_area bytes and can be rewritten in place. Panics if the tags don't
/// fit: callers keep their values bounded (see the tags in record.zig).
pub fn writeTags(out: *[tags_area]u8, tags: []const Tag) void {
    var b: Boxes = .{ .buf = out };
    b.open("udta");
    b.full("meta", 0, 0);
    b.full("hdlr", 0, 0);
    b.int(u32, 0);
    b.bytes("mdir");
    b.bytes("appl");
    b.zeros(8);
    b.int(u8, 0); // empty name
    b.close();
    b.open("ilst");
    for (tags) |t| {
        const standard = t.name.len == 4 and t.name[0] == 0xA9;
        // What the tag takes, to check it fits before writing it.
        const need = 8 + (if (standard) 0 else 8 + 4 + "com.apple.iTunes".len + 12 + t.name.len) + 16 + t.value.len;
        if (b.len + need + 8 > out.len) std.debug.panic("MP4 tags don't fit in {d} bytes (at {s})", .{ tags_area, t.name });
        if (standard) {
            b.open(t.name[0..4]);
        } else {
            b.open("----");
            b.full("mean", 0, 0);
            b.bytes("com.apple.iTunes");
            b.close();
            b.full("name", 0, 0);
            b.bytes(t.name);
            b.close();
        }
        b.open("data");
        b.int(u32, 1); // UTF-8 text
        b.int(u32, 0); // no locale
        b.bytes(t.value);
        b.close();
        b.close();
    }
    b.close();
    b.close();
    // The rest is free space, as one box (it needs its 8-byte header).
    const free_len = out.len - b.len - 8;
    std.debug.assert(b.len + 8 <= out.len);
    b.open("free");
    b.zeros(free_len);
    b.close();
    b.close();
    std.debug.assert(b.len == out.len);
}

/// Bytes to write over a finished file's init segment: its durations and tags.
pub const Patches = struct {
    mvhd_duration: struct { offset: usize, bytes: [4]u8 },
    tkhd_duration: struct { offset: usize, bytes: [4]u8 },
    mehd_duration: struct { offset: usize, bytes: [8]u8 },
    tags: struct { offset: usize, bytes: [tags_area]u8 },
};

/// Turns encoded frames into a fragmented MP4: the init segment at the first keyframe (frames
/// before it can't be decoded, and are dropped), then a fragment at each keyframe, when
/// fragment_max_frames or max_fragment_data are pending, and at a gap between decode times too
/// long for a frame's duration. Each frame's duration is to the next frame's decode time, so
/// the fragments' times join exactly; only the file's last frame takes nominal_duration. Writes
/// go to the caller's writer, sequentially.
///
/// The caller gives each frame a `FrameTag` (the compressor: where it is in the journal); the
/// pending fragment keeps its first frame's, for checkpoint.
pub fn Muxer(comptime FrameTag: type) type {
    return struct {
        width: u32,
        height: u32,
        /// The last frame's duration, when there's no next frame to measure to.
        nominal_duration: u32,
        /// What gaps show (see pause): a NoVideoRun, the webcam's encoder's frames of
        /// novideo.zig's picture. The owner's; none, and gaps show nothing.
        novideo: []const u8 = &.{},
        state: State = .{ .waiting = .{} },
        /// The fragment being made, if one is: its frames are in `data` and `samples`.
        pending: ?Pending = null,
        data: std.ArrayList(u8) = .empty,
        samples: [fragment_max_frames]Sample = undefined,
        /// Fragments that start with a keyframe, for the seek index.
        seek_points: std.ArrayList(SeekPoint) = .empty,
        header_buf: [moof_max_len + 8]u8 = undefined,

        const Self = @This();

        pub const Pending = struct {
            /// Its first frame's decode time, and its frames.
            time: u64,
            frames: u32,
            /// The state before its first frame was added, and that frame's tag: with its
            /// frames added again from there, the muxer is back where it is.
            start: State,
            tag: FrameTag,
        };

        /// What a checkpoint saves (see checkpoint), and restores.
        pub const Checkpoint = struct {
            state: State,
            /// The pending fragment, made again by adding its frames from `tag`'s.
            replay: ?struct { tag: FrameTag, frames: u32 },
        };

        pub const AddError = Error || error{
            WriteFailed,
            /// A frame decoded no later than the one before it: not a stream that decodes.
            OutOfOrder,
            /// A frame shown further from its decode time than a composition offset holds
            /// (about 3.5 minutes).
            BadTiming,
        };

        pub fn deinit(m: *Self, gpa: std.mem.Allocator) void {
            m.data.deinit(gpa);
            m.seek_points.deinit(gpa);
        }

        /// The file's length so far.
        pub fn len(m: *const Self) u64 {
            return switch (m.state) {
                .waiting => 0,
                .started => |s| s.len,
            };
        }

        /// A frame (Annex B), the next the encoder gave: shown at `time`, decoded at
        /// `decode_time` (timescale units from the recording's start; the encoder may decode a
        /// frame before the start, it's never shown before it).
        pub fn add(m: *Self, gpa: std.mem.Allocator, w: *std.Io.Writer, annex_b: []const u8, time: u64, decode_time: i64, keyframe: bool, tag: FrameTag) AddError!void {
            // Its decode time in the file (see the file's doc comment).
            const decode: u64 = switch (m.state) {
                .waiting => |*waiting| blk: {
                    if (!keyframe) {
                        waiting.dropped += 1;
                        return;
                    }
                    break :blk time;
                },
                .started => |*s| blk: {
                    if (s.rebase) {
                        // A new stream (see rebase): from its first keyframe, its decode times
                        // shifted as the file's first frame's were.
                        if (!keyframe) {
                            s.dropped += 1;
                            return;
                        }
                        // The time it was gone shows "NO VIDEO", up to this frame.
                        if (s.gap) |from| {
                            if (from < time) try m.writeGap(gpa, w, from, time);
                            m.state.started.gap = null;
                        }
                        if (time <= m.state.started.last_decode) return error.OutOfOrder;
                        break :blk time;
                    }
                    const d = @as(i65, decode_time) + s.decode_shift;
                    if (d <= s.last_decode) return error.OutOfOrder;
                    break :blk std.math.cast(u64, d) orelse return error.OutOfOrder;
                },
            };
            const offset = std.math.cast(i32, @as(i65, time) - decode) orelse return error.BadTiming;
            if (m.pending) |p| {
                const gap = decode - m.state.started.last_decode;
                if (gap > std.math.maxInt(u32)) {
                    // Longer than a duration holds (about 7 minutes): the fragment ends with
                    // the last frame at its nominal duration, and the next starts at this
                    // frame's time.
                    try m.flush(gpa, w);
                } else {
                    m.samples[p.frames - 1].duration = @intCast(gap);
                    // A fragment starts at each keyframe, so each can be decoded (and seeked
                    // to) alone; and before it outgrows a moof or an mdat.
                    if (keyframe or p.frames == fragment_max_frames or m.data.items.len + annex_b.len * 2 > max_fragment_data)
                        try m.flush(gpa, w);
                }
            }
            const start = m.state;
            m.data.ensureUnusedCapacity(gpa, annex_b.len * 2) catch @panic("out of memory");
            const out = m.data.unusedCapacitySlice();
            const frame_len = switch (m.state) {
                .started => |*s| try toLengthPrefixed(annex_b, &s.sets, out),
                .waiting => |waiting| blk: {
                    // The parameter sets are the muxer's only once the init segment that has
                    // them is written: a checkpoint never has sets without one.
                    var sets: ParameterSets = .{};
                    const n = try toLengthPrefixed(annex_b, &sets, out);
                    if (!sets.known()) return error.BadStream;
                    var init_buf: [init_max_len]u8 = undefined;
                    const layout = try writeInit(&init_buf, .{ .width = m.width, .height = m.height, .sps = sets.sps(), .pps = sets.pps() });
                    try w.writeAll(init_buf[0..layout.len]);
                    m.state = .{ .started = .{
                        .sets = sets,
                        .dropped = waiting.dropped,
                        .len = layout.len,
                        .first_time = time,
                        .last_time = time,
                        // Set to this frame's when it's added, after anything before it.
                        .last_decode = 0,
                        .decode_shift = @as(i64, @intCast(time)) - decode_time,
                    } };
                    // From the recording's start to the first frame (a webcam added partway,
                    // or slow to start): "NO VIDEO", so the file starts with the recording, as
                    // the audio files do.
                    if (time > 0) try m.writeGap(gpa, w, 0, time);
                    break :blk n;
                },
            };
            m.data.items.len += frame_len;
            const p = if (m.pending) |*p| p else blk: {
                m.pending = .{ .time = decode, .frames = 0, .start = start, .tag = tag };
                break :blk &m.pending.?;
            };
            m.samples[p.frames] = .{ .size = @intCast(frame_len), .duration = m.nominal_duration, .offset = offset, .keyframe = keyframe };
            p.frames += 1;
            const s = &m.state.started;
            if (s.rebase) {
                s.decode_shift = @as(i64, @intCast(time)) - decode_time;
                s.rebase = false;
            }
            s.last_decode = decode;
            s.last_time = @max(s.last_time, time);
        }

        /// The frames so far written out (the pending fragment, if any, ends), and the next
        /// frame starts a new stream, from another encoder: the same webcam added again, the
        /// file carrying on after the time it was gone. That stream's decode times are its
        /// encoder's own, so they're shifted afresh (see Started.rebase); the gap is a stretch
        /// with no frames.
        pub fn pause(m: *Self, gpa: std.mem.Allocator, w: *std.Io.Writer) error{WriteFailed}!void {
            switch (m.state) {
                .waiting => {},
                .started => |*s| {
                    if (m.pending != null) try m.flush(gpa, w);
                    s.rebase = true;
                    // From the end of the last frame shown.
                    s.gap = s.last_time + m.nominal_duration;
                },
            }
        }

        /// `novideo`'s run shown from `from` to `to` (the recording's start to the first frame,
        /// or a gap, see pause and finish), over and over: each time a fragment, starting at its
        /// keyframe (so seeking into the gap shows it), the last cut short where the gap ends.
        /// Its first frame decoded when it's shown, after the frames before (the last ended by
        /// `from`).
        fn writeGap(m: *Self, gpa: std.mem.Allocator, w: *std.Io.Writer, from: u64, to: u64) (Error || error{WriteFailed})!void {
            std.debug.assert(m.pending == null and from < to);
            if (m.novideo.len == 0) return;
            const s = &m.state.started;
            const run = try NoVideoRun.parse(m.novideo);
            // Its frames length-prefixed, one after another: no more than twice as big (see
            // toLengthPrefixed). A few KB, once a gap.
            const data = gpa.alloc(u8, m.novideo.len * 2) catch @panic("out of memory");
            defer gpa.free(data);
            var frames: [fragment_max_frames]struct { frame: NoVideoFrame, end: usize } = undefined;
            var data_len: usize = 0;
            {
                var it = run.iterator();
                var i: usize = 0;
                while (try it.next()) |f| : (i += 1) {
                    data_len += try toLengthPrefixed(f.h264, &s.sets, data[data_len..]);
                    frames[i] = .{ .frame = f.frame, .end = data_len };
                }
            }
            const cycle = @as(u64, run.header.interval) * run.header.frames;
            // After the frames before (decoded by last_decode), if any were written.
            var base = if (s.sequence == 1) from else @max(from, s.last_decode + 1);
            while (base < to) : (base += cycle) {
                // The run's frames that are shown and decoded before the gap ends: any after
                // one that isn't may depend on it.
                var n: usize = 0;
                while (n < run.header.frames) : (n += 1) {
                    const f = frames[n].frame;
                    const shown = base + f.shown;
                    const decode = base + f.decode;
                    if (shown >= to or decode >= to) break;
                    if (n > 0) m.samples[n - 1].duration = @intCast(decode - (base + frames[n - 1].frame.decode));
                    m.samples[n] = .{
                        .size = @intCast(frames[n].end - if (n == 0) 0 else frames[n - 1].end),
                        .duration = undefined,
                        .offset = @intCast(@as(i64, f.shown) - f.decode),
                        .keyframe = f.keyframe != 0,
                    };
                }
                // Its keyframe is at base, before the gap ends.
                std.debug.assert(n > 0);
                const last_decode = base + frames[n - 1].frame.decode;
                m.samples[n - 1].duration = @intCast(@min(base + cycle, to) - last_decode);
                m.addSeekPoint(gpa, .{ .time = base, .offset = s.len });
                const header = fragmentHeader(&m.header_buf, s.sequence, base, m.samples[0..n]);
                try w.writeAll(header);
                try w.writeAll(data[0..frames[n - 1].end]);
                s.len += header.len + frames[n - 1].end;
                s.sequence += 1;
                s.last_decode = last_decode;
                // (last_time stays the last real frame's: the file ends at gap_end at least.)
                s.gap_end = to;
            }
        }
        /// What a checkpoint saves: the state before the pending fragment and where its first
        /// frame is (recovery adds its frames again), or with none pending, the state now.
        pub fn checkpoint(m: *const Self) Checkpoint {
            const p = m.pending orelse return .{ .state = m.state, .replay = null };
            return .{ .state = p.start, .replay = .{ .tag = p.tag, .frames = p.frames } };
        }

        /// Recovering: the muxer as a checkpoint saved it. The seek index is rebuilt from the
        /// file (scan), and the pending fragment's frames are added again.
        pub fn restore(m: *Self, state: State) void {
            std.debug.assert(m.pending == null and m.seek_points.items.len == 0);
            m.state = state;
        }

        /// Frames pending: the fragment being made's.
        pub fn pendingFrames(m: *const Self) u32 {
            return if (m.pending) |p| p.frames else 0;
        }

        /// The pending fragment goes, unwritten (its track failed).
        pub fn discardPending(m: *Self) void {
            m.pending = null;
            m.data.clearRetainingCapacity();
        }

        pub fn addSeekPoint(m: *Self, gpa: std.mem.Allocator, point: SeekPoint) void {
            m.seek_points.append(gpa, point) catch @panic("out of memory");
        }

        /// The file's end: the pending frames as a fragment (the last at its nominal
        /// duration), "NO VIDEO" up to `end` if it's paused (its webcam is gone: the file
        /// lasts as long as the recording, as the audio files do), then the seek index. After
        /// this, `patches` gives what to write over the init segment. Nothing to do if there
        /// was no keyframe.
        pub fn finish(m: *Self, gpa: std.mem.Allocator, w: *std.Io.Writer, end: ?u64) (Error || error{WriteFailed})!void {
            if (m.state == .waiting) return;
            if (m.pending != null) try m.flush(gpa, w);
            const s = &m.state.started;
            if (s.gap) |from| if (end) |e| if (from < e) {
                try m.writeGap(gpa, w, from, e);
                s.gap = null;
            };
            s.len += try writeIndex(w, m.seek_points.items);
        }

        /// The finished file's durations (to the end of its last frame) and `tags`.
        pub fn patches(m: *const Self, tags: []const Tag) Patches {
            std.debug.assert(m.pending == null);
            const s = &m.state.started;
            var init_buf: [init_max_len]u8 = undefined;
            // The same init segment as was written (the same sets), for its layout.
            const layout = writeInit(&init_buf, .{ .width = m.width, .height = m.height, .sps = s.sets.sps(), .pps = s.sets.pps() }) catch unreachable;
            const end_ms = @max(s.last_time + m.nominal_duration, s.gap_end) / (timescale / movie_timescale);
            var p: Patches = undefined;
            p.mvhd_duration.offset = layout.mvhd_duration;
            std.mem.writeInt(u32, &p.mvhd_duration.bytes, @intCast(@min(end_ms, std.math.maxInt(u32))), .big);
            p.tkhd_duration.offset = layout.tkhd_duration;
            p.tkhd_duration.bytes = p.mvhd_duration.bytes;
            p.mehd_duration.offset = layout.mehd_duration;
            std.mem.writeInt(u64, &p.mehd_duration.bytes, end_ms, .big);
            p.tags.offset = layout.udta;
            writeTags(&p.tags.bytes, tags);
            return p;
        }

        /// Writes the pending frames as a fragment.
        fn flush(m: *Self, gpa: std.mem.Allocator, w: *std.Io.Writer) error{WriteFailed}!void {
            const p = m.pending.?;
            const s = &m.state.started;
            const samples = m.samples[0..p.frames];
            // A seek point is when its keyframe is shown.
            if (samples[0].keyframe) m.addSeekPoint(gpa, .{ .time = @intCast(@as(i65, p.time) + samples[0].offset), .offset = s.len });
            const header = fragmentHeader(&m.header_buf, s.sequence, p.time, samples);
            try w.writeAll(header);
            try w.writeAll(m.data.items);
            s.len += header.len + m.data.items.len;
            s.sequence += 1;
            m.discardPending();
        }
    };
}

/// Where a muxer is: what a checkpoint saves.
pub const State = union(enum) {
    /// No keyframe yet: nothing written, frames dropped (they can't be decoded alone).
    waiting: struct { dropped: u32 = 0 },
    started: Started,
};

pub const Started = struct {
    /// The first parameter sets, as the init segment has them.
    sets: ParameterSets,
    /// Frames dropped before the first keyframe.
    dropped: u32,
    /// Bytes written to the file.
    len: u64,
    /// The next fragment's number, from 1.
    sequence: u32 = 1,
    /// When the first frame is shown.
    first_time: u64,
    /// When the last frame shown so far (the latest) is shown: the file ends a frame after.
    last_time: u64,
    /// The last frame's decode time in the file: the next must be later.
    last_decode: u64,
    /// What's added to the encoder's decode times in the file: from the stream's first
    /// frame's decode time to when it's shown.
    decode_shift: i64,
    /// The next frame starts a new stream (see Muxer.pause): frames before its first keyframe
    /// are dropped (counted in `dropped`), and decode_shift is measured again on it.
    rebase: bool = false,
    /// Paused: from when "NO VIDEO" is shown, until the next stream's first frame, or the
    /// file's end (see Muxer.finish).
    gap: ?u64 = null,
    /// The end of the last "NO VIDEO" written: the file lasts at least to there.
    gap_end: u64 = 0,
};

/// The most frame data a fragment holds: its mdat's size fits its 32 bits.
pub const max_fragment_data = 1 << 30;

/// Boxes built in a fixed buffer, each's size filled in when it's closed. Overflowing the
/// buffer is a bug: everything written is bounded.
const Boxes = struct {
    buf: []u8,
    len: usize = 0,
    open_at: [12]usize = undefined,
    depth: usize = 0,

    fn open(b: *Boxes, name: *const [4]u8) void {
        b.open_at[b.depth] = b.len;
        b.depth += 1;
        b.int(u32, 0);
        b.bytes(name);
    }
    fn full(b: *Boxes, name: *const [4]u8, version: u8, flags: u24) void {
        b.open(name);
        b.int(u8, version);
        b.int(u24, flags);
    }
    fn close(b: *Boxes) void {
        b.depth -= 1;
        const at = b.open_at[b.depth];
        std.mem.writeInt(u32, b.buf[at..][0..4], @intCast(b.len - at), .big);
    }
    fn int(b: *Boxes, comptime T: type, v: T) void {
        std.mem.writeInt(T, b.buf[b.len..][0 .. @typeInfo(T).int.bits / 8], v, .big);
        b.len += @typeInfo(T).int.bits / 8;
    }
    fn bytes(b: *Boxes, s: []const u8) void {
        @memcpy(b.buf[b.len..][0..s.len], s);
        b.len += s.len;
    }
    fn zeros(b: *Boxes, n: usize) void {
        @memset(b.buf[b.len..][0..n], 0);
        b.len += n;
    }
    /// The identity transformation.
    fn matrix(b: *Boxes) void {
        for ([9]u32{ 0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000 }) |v| b.int(u32, v);
    }
    fn written(b: *const Boxes) []const u8 {
        std.debug.assert(b.depth == 0);
        return b.buf[0..b.len];
    }
};

/// The NAL units of an Annex B stream (each after a 3 or 4 byte start code), without the start
/// codes and the zero bytes before the next one.
pub const NalIterator = struct {
    bytes: []const u8,
    at: usize = 0,

    /// Fails if the stream doesn't start with a start code (zero bytes before it are fine: a
    /// 4-byte start code is one).
    pub fn init(bytes: []const u8) Error!NalIterator {
        const first = startCode(bytes, 0) orelse return error.BadStream;
        for (bytes[0..first.at]) |b| if (b != 0) return error.BadStream;
        return .{ .bytes = bytes, .at = first.at + first.len };
    }

    pub fn next(it: *NalIterator) ?[]const u8 {
        if (it.at >= it.bytes.len) return null;
        const start = it.at;
        const end, const next_at = if (startCode(it.bytes, start)) |sc| .{ sc.at, sc.at + sc.len } else .{ it.bytes.len, it.bytes.len };
        it.at = next_at;
        // Trailing zeros (cabac_zero_words, or a 4-byte start code's leading zero) aren't part
        // of the NAL unit.
        var e = end;
        while (e > start and it.bytes[e - 1] == 0) e -= 1;
        return it.bytes[start..e];
    }

    /// The first 00 00 01 at or after `from`. Inside a NAL unit, emulation prevention keeps that
    /// sequence from appearing, so it always starts the next one.
    fn startCode(bytes: []const u8, from: usize) ?struct { at: usize, len: usize } {
        var i = from;
        while (i + 3 <= bytes.len) : (i += 1) {
            if (bytes[i] == 0 and bytes[i + 1] == 0 and bytes[i + 2] == 1) return .{ .at = i, .len = 3 };
        }
        return null;
    }
};

pub const NalType = struct {
    pub const idr = 5;
    pub const sps = 7;
    pub const pps = 8;
    pub const aud = 9;
};

pub fn nalType(nal: []const u8) u5 {
    return @truncate(nal[0]);
}

/// The first parameter sets the stream carries, for the init segment.
pub const ParameterSets = struct {
    sps_buf: [max_parameter_set]u8 = undefined,
    sps_len: u16 = 0,
    pps_buf: [max_parameter_set]u8 = undefined,
    pps_len: u16 = 0,

    pub fn sps(p: *const ParameterSets) []const u8 {
        return p.sps_buf[0..p.sps_len];
    }
    pub fn pps(p: *const ParameterSets) []const u8 {
        return p.pps_buf[0..p.pps_len];
    }
    pub fn known(p: *const ParameterSets) bool {
        return p.sps_len != 0 and p.pps_len != 0;
    }
};

/// An Annex B frame as MP4 stores it: each NAL unit after its length (4 bytes, big-endian),
/// into `out`. Access unit delimiters are left out. SPS and PPS stay in the stream (the sample
/// entry is avc3, see writeInit): encoders change them partway, e.g. the Qualcomm one rewrites
/// the SPS's timing when the camera drops from 30 to 15 fps in low light. The first ones seen
/// are kept in `sets`, for the init segment. Returns the bytes written. `out` must hold as many
/// bytes as `annex_b` plus 1 for each NAL unit after a 3-byte start code; annex_b.len * 2
/// always does.
pub fn toLengthPrefixed(annex_b: []const u8, sets: *ParameterSets, out: []u8) Error!usize {
    var it: NalIterator = try .init(annex_b);
    var n: usize = 0;
    while (it.next()) |nal| {
        if (nal.len == 0) return error.BadStream;
        switch (nalType(nal)) {
            NalType.aud => continue,
            NalType.sps => try keepFirst(&sets.sps_buf, &sets.sps_len, nal),
            NalType.pps => try keepFirst(&sets.pps_buf, &sets.pps_len, nal),
            else => {},
        }
        std.mem.writeInt(u32, out[n..][0..4], @intCast(nal.len), .big);
        @memcpy(out[n + 4 ..][0..nal.len], nal);
        n += 4 + nal.len;
    }
    return n;
}

fn keepFirst(buf: *[max_parameter_set]u8, len: *u16, nal: []const u8) Error!void {
    // Only the first is kept: later ones (changed or not) stay in the stream, whatever size.
    if (len.* != 0) return;
    if (nal.len > buf.len) return error.BadStream;
    @memcpy(buf[0..nal.len], nal);
    len.* = @intCast(nal.len);
}

/// What avcC needs from an SPS beyond its first bytes (ISO/IEC 14496-15 5.3.3.1.2): for the
/// High profiles, the chroma format and bit depths.
pub const SpsInfo = struct {
    high: bool,
    chroma_format: u2 = 1,
    bit_depth_luma_minus8: u3 = 0,
    bit_depth_chroma_minus8: u3 = 0,
};

pub fn parseSps(sps: []const u8) Error!SpsInfo {
    if (sps.len < 4 or nalType(sps) != NalType.sps) return error.BadSps;
    const profile = sps[1];
    const high = switch (profile) {
        100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135 => true,
        else => false,
    };
    if (!high) return .{ .high = false };
    // After the NAL header, profile, constraint flags and level: seq_parameter_set_id, then
    // chroma_format_idc and so on, in Exp-Golomb codes, with emulation prevention removed.
    var r: BitReader = .{ .bytes = sps[4..] };
    _ = try r.ue(); // seq_parameter_set_id
    const chroma = try r.ue();
    if (chroma > 3) return error.BadSps;
    if (chroma == 3) _ = try r.bit(); // separate_colour_plane_flag
    const luma = try r.ue();
    const chroma_depth = try r.ue();
    if (luma > 6 or chroma_depth > 6) return error.BadSps;
    return .{ .high = true, .chroma_format = @intCast(chroma), .bit_depth_luma_minus8 = @intCast(luma), .bit_depth_chroma_minus8 = @intCast(chroma_depth) };
}

/// Bits of an RBSP, skipping emulation prevention bytes (the 03 in 00 00 03).
const BitReader = struct {
    bytes: []const u8,
    byte: usize = 0,
    bit_index: u3 = 0,
    zeros: u8 = 0,

    fn bit(r: *BitReader) Error!u1 {
        if (r.bit_index == 0) {
            if (r.byte >= r.bytes.len) return error.BadSps;
            if (r.zeros >= 2 and r.bytes[r.byte] == 3) {
                r.byte += 1;
                r.zeros = 0;
                if (r.byte >= r.bytes.len) return error.BadSps;
            }
            r.zeros = if (r.bytes[r.byte] == 0) r.zeros + 1 else 0;
        }
        const v: u1 = @truncate(r.bytes[r.byte] >> (7 - @as(u3, r.bit_index)));
        r.bit_index +%= 1;
        if (r.bit_index == 0) r.byte += 1;
        return v;
    }

    /// An unsigned Exp-Golomb code.
    fn ue(r: *BitReader) Error!u32 {
        var leading: u5 = 0;
        while (try r.bit() == 0) {
            if (leading == 31) return error.BadSps;
            leading += 1;
        }
        var v: u32 = 0;
        for (0..leading) |_| v = v << 1 | try r.bit();
        return (@as(u32, 1) << leading) - 1 + v;
    }
};

// The camera's SPS and PPS from a recording (Qualcomm hardware encoder, 1920x1080, High
// profile level 4.0), with two emulation prevention bytes in the SPS.
const test_sps = [_]u8{ 0x67, 0x64, 0x00, 0x28, 0xac, 0xb4, 0x03, 0xc0, 0x11, 0x3f, 0x2e, 0x02, 0x20, 0x00, 0x00, 0x03, 0x00, 0x20, 0x00, 0x00, 0x07, 0x81, 0xb4, 0x28, 0x4d, 0x40 };
const test_pps = [_]u8{ 0x68, 0xee, 0x06, 0xf2, 0xc0 };
/// A stand-in for an encoder's "NO VIDEO" run: a keyframe (its SPS and PPS, and a slice), then
/// a frame half a second later.
const test_novideo_key = [_]u8{ 0, 0, 0, 1 } ++ test_sps ++ [_]u8{ 0, 0, 0, 1 } ++ test_pps ++ [_]u8{ 0, 0, 0, 1, 0x65, 0x88, 0x84, 0x21 };
const test_novideo_next = [_]u8{ 0, 0, 0, 1, 0x41, 0x9a, 0x21 };
const test_novideo_interval = 5_000_000;
const test_novideo = std.mem.toBytes(NoVideoRun{ .interval = test_novideo_interval, .frames = 2 }) ++
    std.mem.toBytes(NoVideoFrame{ .len = test_novideo_key.len, .keyframe = 1, .shown = 0, .decode = 0 }) ++ test_novideo_key ++
    std.mem.toBytes(NoVideoFrame{ .len = test_novideo_next.len, .keyframe = 0, .shown = test_novideo_interval, .decode = test_novideo_interval }) ++ test_novideo_next;

/// The run fills `from` to `to` exactly: fragments one after another, each starting at its
/// keyframe at a run's start (every 2 frames, a second), the last cut short at `to`.
fn expectFilled(frags: []const TestFragment, from: u64, to: u64) !void {
    var at = from;
    for (frags) |f| {
        if (f.time < from or f.time >= to) continue;
        errdefer std.debug.print("fragment at {d} ({d} frames, {d} long), {d} expected\n", .{ f.time, f.frames, f.duration, at });
        try std.testing.expectEqual(at, f.time);
        try std.testing.expect(f.keyframe and f.frames <= 2);
        at = f.time + f.duration;
    }
    try std.testing.expectEqual(to, at);
}

test parseSps {
    try std.testing.expectEqual(SpsInfo{ .high = true, .chroma_format = 1, .bit_depth_luma_minus8 = 0, .bit_depth_chroma_minus8 = 0 }, try parseSps(&test_sps));
    // Baseline: nothing more to read.
    try std.testing.expectEqual(SpsInfo{ .high = false }, try parseSps(&.{ 0x67, 0x42, 0xc0, 0x1e, 0xff }));
    try std.testing.expectError(error.BadSps, parseSps(&test_pps));
    try std.testing.expectError(error.BadSps, parseSps(test_sps[0..4]));
    // 4:4:4 at 10 bits: chroma_format_idc 3 (00100), separate planes 0, luma 2 (011), chroma 2.
    try std.testing.expectEqual(SpsInfo{ .high = true, .chroma_format = 3, .bit_depth_luma_minus8 = 2, .bit_depth_chroma_minus8 = 2 }, try parseSps(&.{ 0x67, 0xf4, 0x00, 0x28, 0b1_00100_0_0, 0b11_011_000 }));
}

test "BitReader skips emulation prevention bytes" {
    // 00 00 03 01: the 03 isn't data.
    var r: BitReader = .{ .bytes = &.{ 0x00, 0x00, 0x03, 0x01 } };
    for (0..23) |_| try std.testing.expectEqual(0, try r.bit());
    try std.testing.expectEqual(1, try r.bit());
    try std.testing.expectError(error.BadSps, r.bit());
}

test toLengthPrefixed {
    // AUD, SPS, PPS, an IDR slice with trailing zeros, then a 3-byte start code slice.
    const frame = [_]u8{ 0, 0, 0, 1, 0x09, 0x10 } ++ [_]u8{ 0, 0, 0, 1 } ++ test_sps ++ [_]u8{ 0, 0, 0, 1 } ++ test_pps ++
        [_]u8{ 0, 0, 0, 1, 0x65, 0xb8, 0x41, 0x00, 0x00 } ++ [_]u8{ 0, 0, 1, 0x65, 0x11 };
    var sets: ParameterSets = .{};
    var out: [frame.len * 2]u8 = undefined;
    const n = try toLengthPrefixed(&frame, &sets, &out);
    const expected = [_]u8{ 0, 0, 0, test_sps.len } ++ test_sps ++ [_]u8{ 0, 0, 0, test_pps.len } ++ test_pps ++
        [_]u8{ 0, 0, 0, 3, 0x65, 0xb8, 0x41, 0, 0, 0, 2, 0x65, 0x11 };
    try std.testing.expectEqualSlices(u8, &expected, out[0..n]);
    try std.testing.expectEqualSlices(u8, &test_sps, sets.sps());
    try std.testing.expectEqualSlices(u8, &test_pps, sets.pps());
    // A changed SPS stays in the stream; the init segment keeps the first.
    var changed = frame;
    changed[6 + 4 + 17] ^= 0x60;
    const n2 = try toLengthPrefixed(&changed, &sets, &out);
    try std.testing.expectEqualSlices(u8, changed[6 + 4 ..][0..test_sps.len], out[4..][0..test_sps.len]);
    try std.testing.expectEqual(expected.len, n2);
    try std.testing.expectEqualSlices(u8, &test_sps, sets.sps());
    try std.testing.expectError(error.BadStream, toLengthPrefixed(&.{ 0x65, 0x00 }, &sets, &out));
}

/// A box's children, checked to fill it exactly.
const TestBox = struct {
    name: [4]u8,
    body: []const u8,

    fn children(bytes: []const u8, out: []TestBox) ![]TestBox {
        var n: usize = 0;
        var at: usize = 0;
        while (at < bytes.len) {
            try std.testing.expect(bytes.len - at >= 8);
            const size = std.mem.readInt(u32, bytes[at..][0..4], .big);
            try std.testing.expect(size >= 8 and size <= bytes.len - at);
            out[n] = .{ .name = bytes[at + 4 ..][0..4].*, .body = bytes[at + 8 .. at + size] };
            n += 1;
            at += size;
        }
        return out[0..n];
    }

    fn find(boxes: []const TestBox, name: *const [4]u8) !TestBox {
        for (boxes) |b| if (std.mem.eql(u8, &b.name, name)) return b;
        std.debug.print("no {s} box\n", .{name});
        return error.TestUnexpectedResult;
    }
};

test writeInit {
    var buf: [init_max_len]u8 = undefined;
    const layout = try writeInit(&buf, .{ .width = 1920, .height = 1080, .sps = &test_sps, .pps = &test_pps });
    const bytes = buf[0..layout.len];
    var top_buf: [8]TestBox = undefined;
    const top = try TestBox.children(bytes, &top_buf);
    try std.testing.expectEqual(2, top.len);
    try std.testing.expectEqualStrings("ftyp", &top[0].name);
    var moov_buf: [8]TestBox = undefined;
    const moov = try TestBox.children((try TestBox.find(top, "moov")).body, &moov_buf);
    var trak_buf: [8]TestBox = undefined;
    const trak = try TestBox.children((try TestBox.find(moov, "trak")).body, &trak_buf);
    const tkhd = (try TestBox.find(trak, "tkhd")).body;
    try std.testing.expectEqual(1920 << 16, std.mem.readInt(u32, tkhd[tkhd.len - 8 ..][0..4], .big));
    try std.testing.expectEqual(1080 << 16, std.mem.readInt(u32, tkhd[tkhd.len - 4 ..][0..4], .big));
    var mdia_buf: [8]TestBox = undefined;
    const mdia = try TestBox.children((try TestBox.find(trak, "mdia")).body, &mdia_buf);
    try std.testing.expectEqual(timescale, std.mem.readInt(u32, (try TestBox.find(mdia, "mdhd")).body[12..16], .big));
    var minf_buf: [8]TestBox = undefined;
    const minf = try TestBox.children((try TestBox.find(mdia, "minf")).body, &minf_buf);
    var stbl_buf: [8]TestBox = undefined;
    const stbl = try TestBox.children((try TestBox.find(minf, "stbl")).body, &stbl_buf);
    const stsd = (try TestBox.find(stbl, "stsd")).body;
    // Version and flags, entry count, then avc3: 78 bytes of sample entry, then avcC.
    var avc3_buf: [1]TestBox = undefined;
    const avc3 = try TestBox.children(stsd[8..], &avc3_buf);
    try std.testing.expectEqualStrings("avc3", &avc3[0].name);
    var avcc_buf: [1]TestBox = undefined;
    const avcc = (try TestBox.children(avc3[0].body[78..], &avcc_buf))[0];
    try std.testing.expectEqualStrings("avcC", &avcc.name);
    const expected_avcc = [_]u8{ 1, 0x64, 0x00, 0x28, 0xff, 0xe1, 0, test_sps.len } ++ test_sps ++ [_]u8{ 1, 0, test_pps.len } ++ test_pps ++ [_]u8{ 0xfd, 0xf8, 0xf8, 0 };
    try std.testing.expectEqualSlices(u8, &expected_avcc, avcc.body);
    // mvex: mehd (version 1), then trex.
    var mvex_buf: [2]TestBox = undefined;
    const mvex = try TestBox.children((try TestBox.find(moov, "mvex")).body, &mvex_buf);
    try std.testing.expectEqualStrings("mehd", &mvex[0].name);
    try std.testing.expectEqual(1, mvex[0].body[0]);
    try std.testing.expectEqualStrings("trex", &mvex[1].name);
    // The tags area is moov's last box, all of tags_area, ending the init segment.
    try std.testing.expectEqualStrings("udta", &moov[moov.len - 1].name);
    try std.testing.expectEqual(tags_area, moov[moov.len - 1].body.len + 8);
    try std.testing.expectEqual(layout.len - tags_area, layout.udta);
    try std.testing.expectEqualStrings("udta", bytes[layout.udta + 4 ..][0..4]);
    // The durations to fill in: in mvhd and tkhd after creation, modification and the
    // timescale or track id, in mehd its body; all 0 for now.
    try std.testing.expectEqual(0, std.mem.readInt(u32, bytes[layout.mvhd_duration..][0..4], .big));
    try std.testing.expectEqual(movie_timescale, std.mem.readInt(u32, bytes[layout.mvhd_duration - 4 ..][0..4], .big));
    try std.testing.expectEqual(1, std.mem.readInt(u32, bytes[layout.tkhd_duration - 8 ..][0..4], .big));
    try std.testing.expectEqual(0, std.mem.readInt(u64, bytes[layout.mehd_duration..][0..8], .big));
    try std.testing.expectEqualStrings("mehd", bytes[layout.mehd_duration - 8 ..][0..4]);
    // A PPS longer than max_parameter_set isn't one.
    const long_pps: [max_parameter_set + 1]u8 = @splat(0x68);
    try std.testing.expectError(error.BadStream, writeInit(&buf, .{ .width = 2, .height = 2, .sps = &test_sps, .pps = &long_pps }));
}

test writeTags {
    var area: [tags_area]u8 = undefined;
    writeTags(&area, &.{
        .{ .name = tag_title, .value = "Front Camera" },
        .{ .name = "RECORDING_START_QPC", .value = "123" },
    });
    var udta_buf: [1]TestBox = undefined;
    const udta = try TestBox.children(&area, &udta_buf);
    try std.testing.expectEqualStrings("udta", &udta[0].name);
    var udta_children_buf: [2]TestBox = undefined;
    const children = try TestBox.children(udta[0].body, &udta_children_buf);
    try std.testing.expectEqualStrings("meta", &children[0].name);
    // The rest is free space.
    try std.testing.expectEqualStrings("free", &children[1].name);
    var meta_buf: [2]TestBox = undefined;
    // meta is a full box: version and flags first.
    const meta = try TestBox.children(children[0].body[4..], &meta_buf);
    try std.testing.expectEqualStrings("hdlr", &meta[0].name);
    try std.testing.expectEqualStrings("mdir", meta[0].body[8..12]);
    var items_buf: [2]TestBox = undefined;
    const items = try TestBox.children((try TestBox.find(meta, "ilst")).body, &items_buf);
    try std.testing.expectEqual(2, items.len);
    try std.testing.expectEqualStrings(tag_title, &items[0].name);
    var data_buf: [1]TestBox = undefined;
    const data = (try TestBox.children(items[0].body, &data_buf))[0];
    try std.testing.expectEqualStrings("data", &data.name);
    try std.testing.expectEqual(1, std.mem.readInt(u32, data.body[0..4], .big));
    try std.testing.expectEqualStrings("Front Camera", data.body[8..]);
    try std.testing.expectEqualStrings("----", &items[1].name);
    var free_buf: [3]TestBox = undefined;
    const freeform = try TestBox.children(items[1].body, &free_buf);
    try std.testing.expectEqualStrings("com.apple.iTunes", freeform[0].body[4..]);
    try std.testing.expectEqualStrings("RECORDING_START_QPC", freeform[1].body[4..]);
    try std.testing.expectEqualStrings("123", freeform[2].body[8..]);
    // The most a tag value can be and still fit, with the device name's bound (1024) and room
    // to spare, fills nothing past the area.
    const long_value: [3000]u8 = @splat('x');
    writeTags(&area, &.{.{ .name = tag_title, .value = &long_value }});
}

/// A frame as an encoder gives it: a keyframe with an AUD, the SPS and PPS, then an IDR slice;
/// another frame an AUD and a slice. `n` bytes of slice, none zero.
fn testFrame(buf: []u8, keyframe: bool, n: usize, sps: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll(&.{ 0, 0, 0, 1, 0x09, 0x10 }) catch unreachable;
    if (keyframe) {
        w.writeAll(&.{ 0, 0, 0, 1 }) catch unreachable;
        w.writeAll(sps) catch unreachable;
        w.writeAll(&.{ 0, 0, 0, 1 }) catch unreachable;
        w.writeAll(&test_pps) catch unreachable;
    }
    w.writeAll(&.{ 0, 0, 1, if (keyframe) 0x65 else 0x41 }) catch unreachable;
    for (0..n) |i| w.writeByte(@intCast(1 + i % 250)) catch unreachable;
    return w.buffered();
}

/// A muxed file, read back: each fragment's first frame's decode time, the sum of its
/// durations, its frames, and its moof's offset.
const TestFragment = struct { time: u64, duration: u64, frames: u32, keyframe: bool, offset: u64, last_duration: u32 };

/// When each frame of a muxed file is shown, in the order they're stored, into `out`.
fn testShownTimes(file: []const u8, out: []u64) ![]u64 {
    var top_buf: [512]TestBox = undefined;
    const top = try TestBox.children(file, &top_buf);
    var n: usize = 0;
    for (top) |box| {
        if (!std.mem.eql(u8, &box.name, "moof")) continue;
        var decode = (try parseMoof(box.body)).decode_time;
        var moof_buf: [2]TestBox = undefined;
        const moof = try TestBox.children(box.body, &moof_buf);
        var traf_buf: [3]TestBox = undefined;
        const traf = try TestBox.children(moof[1].body, &traf_buf);
        const trun = (try TestBox.find(traf, "trun")).body;
        for (0..std.mem.readInt(u32, trun[4..8], .big)) |i| {
            const entry = trun[12 + i * trun_entry_len ..];
            out[n] = @intCast(@as(i65, decode) + std.mem.readInt(i32, entry[12..16], .big));
            n += 1;
            decode += std.mem.readInt(u32, entry[0..4], .big);
        }
    }
    return out[0..n];
}

fn testFragments(file: []const u8, out: []TestFragment) ![]TestFragment {
    var top_buf: [512]TestBox = undefined;
    const top = try TestBox.children(file, &top_buf);
    var n: usize = 0;
    var offset: u64 = 0;
    for (top) |box| {
        defer offset += box.body.len + 8;
        if (!std.mem.eql(u8, &box.name, "moof")) continue;
        const info = try parseMoof(box.body);
        try std.testing.expectEqual(n + 1, info.sequence);
        var moof_buf: [2]TestBox = undefined;
        const moof = try TestBox.children(box.body, &moof_buf);
        var traf_buf: [3]TestBox = undefined;
        const traf = try TestBox.children(moof[1].body, &traf_buf);
        const trun = (try TestBox.find(traf, "trun")).body;
        const count = std.mem.readInt(u32, trun[4..8], .big);
        var duration: u64 = 0;
        var last: u32 = 0;
        for (0..count) |i| {
            last = std.mem.readInt(u32, trun[12 + i * trun_entry_len ..][0..4], .big);
            duration += last;
        }
        out[n] = .{ .time = info.decode_time, .duration = duration, .frames = count, .keyframe = info.keyframe, .offset = offset, .last_duration = last };
        n += 1;
    }
    return out[0..n];
}

/// Frames at 15 fps where the nominal rate is 30, with jitter, and a keyframe every 10.
const test_frames = 50;
fn testFrameTime(i: u64) u64 {
    const jitter: u64 = (i * 7919) % 20_000;
    return 5_000_000 + i * 666_666 + jitter;
}

/// The tests' muxer: its frames are tagged with their numbers.
const TestMuxer = Muxer(u64);

/// The frame the encoder gives `i`th, as one with B-frames does: in each keyframe's ten, frames
/// 2, 1, 4, 3, ... (a frame is decoded before the B-frame shown ahead of it), 9 last.
fn testShownAs(i: u64) u64 {
    const k = i % 10;
    if (k == 0 or k == 9) return i;
    return if (k % 2 == 1) i + 1 else i - 1;
}

/// The encoder's decode times: steady, behind when frames are shown (the B-frames' delay).
fn testDecodeTime(i: u64) i64 {
    return @as(i64, @intCast(testFrameTime(i))) - 700_000;
}

fn testMux(gpa: std.mem.Allocator, w: *std.Io.Writer, m: *TestMuxer, from: u64, to: u64) !void {
    var frame_buf: [4096]u8 = undefined;
    for (from..to) |i| {
        const keyframe = i % 10 == 0;
        try m.add(gpa, w, testFrame(&frame_buf, keyframe, 100 + i * 13 % 900, &test_sps), testFrameTime(testShownAs(i)), testDecodeTime(i), keyframe, i);
    }
}

test "fragments start at keyframes and join exactly" {
    const gpa = std.testing.allocator;
    var file: std.Io.Writer.Allocating = .init(gpa);
    defer file.deinit();
    var m: TestMuxer = .{ .width = 1920, .height = 1080, .nominal_duration = 333_333 };
    defer m.deinit(gpa);
    try testMux(gpa, &file.writer, &m, 0, test_frames);
    try m.finish(gpa, &file.writer, null);
    try std.testing.expectEqual(file.written().len, m.len());

    var frag_buf: [64]TestFragment = undefined;
    const frags = try testFragments(file.written(), &frag_buf);
    try std.testing.expectEqual(testFrameTime(0), frags[0].time);
    // Each frame shown when the encoder said, stored in the order it gave them.
    var shown_buf: [test_frames]u64 = undefined;
    const shown = try testShownTimes(file.written(), &shown_buf);
    try std.testing.expectEqual(test_frames, shown.len);
    for (shown, 0..) |t, i| try std.testing.expectEqual(testFrameTime(testShownAs(i)), t);
    var frames: u32 = 0;
    for (frags, 0..) |f, i| {
        frames += f.frames;
        // Each starts where the one before ended: durations measured to the next frame.
        if (i + 1 < frags.len) try std.testing.expectEqual(frags[i + 1].time, f.time + f.duration);
    }
    try std.testing.expectEqual(test_frames, frames);
    // Only the file's last frame takes the nominal duration.
    try std.testing.expectEqual(333_333, frags[frags.len - 1].last_duration);
    try std.testing.expectEqual(testFrameTime(test_frames - 1) + 333_333, frags[frags.len - 1].time + frags[frags.len - 1].duration);
    // A fragment per keyframe, each starting with it.
    var keyframe_fragments: usize = 0;
    for (frags) |f| {
        if (f.keyframe) keyframe_fragments += 1;
        try std.testing.expectEqual(10, f.frames);
    }
    try std.testing.expectEqual(test_frames / 10, keyframe_fragments);
    try std.testing.expectEqual(frags.len, keyframe_fragments);

    // The seek index, found from the end, lists exactly the keyframe fragments.
    const bytes = file.written();
    const mfra_len = std.mem.readInt(u32, bytes[bytes.len - 4 ..][0..4], .big);
    var mfra_buf: [1]TestBox = undefined;
    const mfra = (try TestBox.children(bytes[bytes.len - mfra_len ..], &mfra_buf))[0];
    try std.testing.expectEqualStrings("mfra", &mfra.name);
    var tfra_buf: [2]TestBox = undefined;
    const tfra = (try TestBox.children(mfra.body, &tfra_buf))[0].body;
    try std.testing.expectEqual(keyframe_fragments, std.mem.readInt(u32, tfra[12..16], .big));
    var k: usize = 0;
    for (frags) |f| if (f.keyframe) {
        const e = tfra[16 + k * 19 ..];
        try std.testing.expectEqual(f.time, std.mem.readInt(u64, e[0..8], .big));
        try std.testing.expectEqual(f.offset, std.mem.readInt(u64, e[8..16], .big));
        try std.testing.expectEqualSlices(u8, &.{ 1, 1, 1 }, e[16..19]);
        k += 1;
    };

    // The durations and tags written over the init segment.
    const p = m.patches(&.{.{ .name = tag_title, .value = "Cam" }});
    const end_ms = (testFrameTime(test_frames - 1) + 333_333) / 10_000;
    try std.testing.expectEqual(end_ms, std.mem.readInt(u32, &p.mvhd_duration.bytes, .big));
    try std.testing.expectEqual(end_ms, std.mem.readInt(u32, &p.tkhd_duration.bytes, .big));
    try std.testing.expectEqual(end_ms, std.mem.readInt(u64, &p.mehd_duration.bytes, .big));
    for ([_]usize{ p.mvhd_duration.offset, p.tkhd_duration.offset }) |at| try std.testing.expectEqual(0, std.mem.readInt(u32, bytes[at..][0..4], .big));
    try std.testing.expectEqualStrings("udta", bytes[p.tags.offset + 4 ..][0..4]);
    try std.testing.expect(std.mem.indexOf(u8, &p.tags.bytes, "Cam") != null);
}

/// The file so far, for scan.
const TestSource = struct {
    bytes: []const u8,
    pub const Error = error{ReadFailed};
    pub fn read(s: TestSource, buf: []u8, offset: u64) error{ReadFailed}!void {
        if (offset + buf.len > s.bytes.len) return error.ReadFailed;
        @memcpy(buf, s.bytes[@intCast(offset)..][0..buf.len]);
    }
};

test "a muxer restored from a checkpoint, its fragment's frames added again, writes what it would have" {
    const gpa = std.testing.allocator;
    var whole: std.Io.Writer.Allocating = .init(gpa);
    defer whole.deinit();
    var a: TestMuxer = .{ .width = 640, .height = 480, .nominal_duration = 333_333 };
    defer a.deinit(gpa);
    try testMux(gpa, &whole.writer, &a, 0, test_frames);
    try a.finish(gpa, &whole.writer, null);

    // Checkpointed at every frame: before anything (no keyframe yet), at a keyframe, and partway
    // through fragments.
    for (0..test_frames) |at| {
        errdefer std.debug.print("checkpointed after frame {d}\n", .{at});
        var part: std.Io.Writer.Allocating = .init(gpa);
        defer part.deinit();
        var b: TestMuxer = .{ .width = 640, .height = 480, .nominal_duration = 333_333 };
        defer b.deinit(gpa);
        try testMux(gpa, &part.writer, &b, 0, at + 1);
        // What a checkpoint saves: the state the pending fragment started from, and its first
        // frame (the frames from there are added again).
        const saved = b.checkpoint();
        const replay_from = if (saved.replay) |r| r.tag else at + 1;
        if (saved.replay) |r| try std.testing.expectEqual(at + 1 - r.tag, r.frames);
        // The file as far as it got: no more than the checkpoint says (what's after is
        // overwritten).
        var restored: TestMuxer = .{ .width = 640, .height = 480, .nominal_duration = 333_333 };
        restored.restore(saved.state);
        part.writer.end = @intCast(restored.len());

        var c = restored;
        defer c.deinit(gpa);
        try scan(&c, gpa, TestSource{ .bytes = part.written() }, c.len());
        try testMux(gpa, &part.writer, &c, replay_from, test_frames);
        try c.finish(gpa, &part.writer, null);
        try std.testing.expectEqualSlices(u8, whole.written(), part.written());
    }

    // A file that isn't what the checkpoint says: cut short, or with a fragment missing.
    var b: TestMuxer = .{ .width = 640, .height = 480, .nominal_duration = 333_333 };
    defer b.deinit(gpa);
    var part: std.Io.Writer.Allocating = .init(gpa);
    defer part.deinit();
    try testMux(gpa, &part.writer, &b, 0, 25);
    const saved = b.checkpoint();
    var d: TestMuxer = .{ .width = 640, .height = 480, .nominal_duration = 333_333 };
    defer d.deinit(gpa);
    d.restore(saved.state);
    try std.testing.expectError(error.BadFragment, scan(&d, gpa, TestSource{ .bytes = part.written() }, d.len() - 1));
    d.seek_points.clearRetainingCapacity();
    d.state.started.sequence += 1;
    try std.testing.expectError(error.BadFragment, scan(&d, gpa, TestSource{ .bytes = part.written() }, d.len()));
}

test "a gap too long for a frame's duration starts a new fragment" {
    const gpa = std.testing.allocator;
    var file: std.Io.Writer.Allocating = .init(gpa);
    defer file.deinit();
    var m: TestMuxer = .{ .width = 640, .height = 480, .nominal_duration = 333_333 };
    defer m.deinit(gpa);
    var frame_buf: [4096]u8 = undefined;
    const gap: u64 = std.math.maxInt(u32) + 1;
    const times = [_]u64{ 0, 333_333, 333_333 + gap, 333_333 + gap + 333_333 };
    for (times, 0..) |t, i| try m.add(gpa, &file.writer, testFrame(&frame_buf, i == 0, 50, &test_sps), t, @intCast(t), i == 0, i);
    try m.finish(gpa, &file.writer, null);
    var frag_buf: [8]TestFragment = undefined;
    const frags = try testFragments(file.written(), &frag_buf);
    try std.testing.expectEqual(2, frags.len);
    try std.testing.expectEqual(2, frags[0].frames);
    // The frame before the gap at its nominal duration; the next fragment at its own time.
    try std.testing.expectEqual(333_333, frags[0].last_duration);
    try std.testing.expectEqual(times[2], frags[1].time);
}

test "frames shown in any order are taken; one decoded no later than the last is refused, across fragments too" {
    const gpa = std.testing.allocator;
    var file: std.Io.Writer.Allocating = .init(gpa);
    defer file.deinit();
    var m: TestMuxer = .{ .width = 640, .height = 480, .nominal_duration = 333_333 };
    defer m.deinit(gpa);
    var frame_buf: [4096]u8 = undefined;
    try m.add(gpa, &file.writer, testFrame(&frame_buf, true, 50, &test_sps), 1000, 500, true, 0);
    // Shown before the frame decoded ahead of it: a B-frame.
    try m.add(gpa, &file.writer, testFrame(&frame_buf, false, 50, &test_sps), 3000, 1500, false, 0);
    try m.add(gpa, &file.writer, testFrame(&frame_buf, false, 50, &test_sps), 2000, 2500, false, 0);
    try std.testing.expectError(error.OutOfOrder, m.add(gpa, &file.writer, testFrame(&frame_buf, false, 50, &test_sps), 4000, 2500, false, 0));
    // A keyframe would end the fragment before it's checked: still refused.
    try std.testing.expectError(error.OutOfOrder, m.add(gpa, &file.writer, testFrame(&frame_buf, true, 50, &test_sps), 4000, 2000, true, 0));
    // Shown further from its decode time than an offset holds.
    try std.testing.expectError(error.BadTiming, m.add(gpa, &file.writer, testFrame(&frame_buf, false, 50, &test_sps), 1 << 40, 3500, false, 0));
}

test "a paused file carries on with a new stream after the gap, each frame shown at its time" {
    const gpa = std.testing.allocator;
    var file: std.Io.Writer.Allocating = .init(gpa);
    defer file.deinit();
    var m: TestMuxer = .{ .width = 640, .height = 480, .nominal_duration = 333_333, .novideo = &test_novideo };
    defer m.deinit(gpa);
    var frame_buf: [4096]u8 = undefined;
    // Ten frames, decoded 700 us ahead of when they're shown (as testMux's encoder).
    try testMux(gpa, &file.writer, &m, 0, 10);
    try m.pause(gpa, &file.writer);
    // Written out: nothing pending to hold the journal back.
    try std.testing.expectEqual(0, m.pendingFrames());
    // A minute later, another encoder: its first frames before a keyframe can't be decoded
    // (dropped), then frames decoded 1 frame ahead of when they're shown, on its own clock.
    const later: u64 = 60 * timescale;
    try m.add(gpa, &file.writer, testFrame(&frame_buf, false, 50, &test_sps), later - 333_333, @intCast(later - 333_333), false, 99);
    for (0..5) |i| {
        const t = later + i * 333_333;
        try m.add(gpa, &file.writer, testFrame(&frame_buf, i == 0, 50, &test_sps), t, @as(i64, @intCast(t)) - 333_333 - 5 * timescale, i == 0, 100 + i);
    }
    try m.finish(gpa, &file.writer, null);
    try std.testing.expectEqual(1, m.state.started.dropped);
    // The gap shows "NO VIDEO" from the end of the last frame shown before it, up to the new
    // stream's first: one picture, its own fragment, a keyframe.
    // "NO VIDEO" from the recording's start to the first frame (5 s in), and in the gap, from
    // the end of the last frame shown before it to the new stream's first.
    const gap = testFrameTime(9) + 333_333;
    var frag_buf: [128]TestFragment = undefined;
    const frags = try testFragments(file.written(), &frag_buf);
    try expectFilled(frags, 0, testFrameTime(0));
    try expectFilled(frags, gap, later);
    // The frames shown at their times between.
    var shown_buf: [256]u64 = undefined;
    const shown = try testShownTimes(file.written(), &shown_buf);
    const leading = (testFrameTime(0) + test_novideo_interval - 1) / test_novideo_interval;
    for (shown[leading..][0..10], 0..) |t, i| try std.testing.expectEqual(testFrameTime(testShownAs(i)), t);
    for (shown[shown.len - 5 ..], 0..) |t, i| try std.testing.expectEqual(later + i * 333_333, t);
    // The new stream starts its own fragment, at its time.
    try std.testing.expectEqual(later, frags[frags.len - 1].time);
}
test "a file whose webcam is gone at the end shows NO VIDEO to the end" {
    const gpa = std.testing.allocator;
    var file: std.Io.Writer.Allocating = .init(gpa);
    defer file.deinit();
    var m: TestMuxer = .{ .width = 640, .height = 480, .nominal_duration = 333_333, .novideo = &test_novideo };
    defer m.deinit(gpa);
    try testMux(gpa, &file.writer, &m, 0, 10);
    try m.pause(gpa, &file.writer);
    // Gone for 10.25 s: ten whole runs, then a keyframe cut short.
    const gap = testFrameTime(9) + 333_333;
    const end = gap + 10 * timescale + timescale / 4;
    try m.finish(gpa, &file.writer, end);
    var frag_buf: [64]TestFragment = undefined;
    const frags = try testFragments(file.written(), &frag_buf);
    try expectFilled(frags, gap, end);
    try std.testing.expectEqual(1, frags[frags.len - 1].frames);
    // Each run is a seek point, and the file lasts to the end.
    try std.testing.expectEqual(frags.len, m.seek_points.items.len);
    const p = m.patches(&.{});
    try std.testing.expectEqual(end / 10_000, std.mem.readInt(u64, &p.mehd_duration.bytes, .big));
}

test "a NO VIDEO run that isn't one is refused" {
    try std.testing.expectEqual(2, (try NoVideoRun.parse(&test_novideo)).header.frames);
    // Cut short, or its first frame not a keyframe at its start.
    try std.testing.expectError(error.BadStream, NoVideoRun.parse(test_novideo[0 .. test_novideo.len - 1]));
    var bad = test_novideo;
    bad[@sizeOf(NoVideoRun) + 4] = 0;
    try std.testing.expectError(error.BadStream, NoVideoRun.parse(&bad));
}
test "a keyframe whose init segment can't be made leaves the muxer as it was" {
    const gpa = std.testing.allocator;
    var file: std.Io.Writer.Allocating = .init(gpa);
    defer file.deinit();
    var m: TestMuxer = .{ .width = 640, .height = 480, .nominal_duration = 333_333 };
    defer m.deinit(gpa);
    var frame_buf: [4096]u8 = undefined;
    // An SPS cut short: no profile's worth of fields to read.
    try std.testing.expectError(error.BadSps, m.add(gpa, &file.writer, testFrame(&frame_buf, true, 50, test_sps[0..4]), 1000, 1000, true, 0));
    try std.testing.expectEqual(State{ .waiting = .{} }, m.state);
    try std.testing.expectEqual(0, m.len());
    try std.testing.expectEqual(0, file.written().len);
    // Frames before the first keyframe are dropped and counted.
    try m.add(gpa, &file.writer, testFrame(&frame_buf, false, 50, &test_sps), 2000, 2000, false, 0);
    try std.testing.expectEqual(State{ .waiting = .{ .dropped = 1 } }, m.state);
    try m.add(gpa, &file.writer, testFrame(&frame_buf, true, 50, &test_sps), 3000, 3000, true, 0);
    try std.testing.expect(m.state.started.sets.known());
    try std.testing.expectEqual(1, m.state.started.dropped);
}

test fragmentHeader {
    var buf: [moof_max_len + 8]u8 = undefined;
    const samples = [_]Sample{
        .{ .size = 1000, .duration = 333_333, .offset = 666_666, .keyframe = true },
        .{ .size = 200, .duration = 333_334, .offset = -333_333, .keyframe = false },
    };
    const header = fragmentHeader(&buf, 7, 123_456_789_000, &samples);
    // moof, then mdat's header, which holds the frames.
    var top_buf: [2]TestBox = undefined;
    const top = try TestBox.children(header[0 .. header.len - 8], &top_buf);
    try std.testing.expectEqual(1, top.len);
    try std.testing.expectEqualStrings("moof", &top[0].name);
    try std.testing.expectEqual(8 + 1200, std.mem.readInt(u32, header[header.len - 8 ..][0..4], .big));
    try std.testing.expectEqualStrings("mdat", header[header.len - 4 ..]);
    var moof_buf: [2]TestBox = undefined;
    const moof = try TestBox.children(top[0].body, &moof_buf);
    try std.testing.expectEqual(7, std.mem.readInt(u32, (try TestBox.find(moof, "mfhd")).body[4..8], .big));
    var traf_buf: [3]TestBox = undefined;
    const traf = try TestBox.children((try TestBox.find(moof, "traf")).body, &traf_buf);
    try std.testing.expectEqual(123_456_789_000, std.mem.readInt(u64, (try TestBox.find(traf, "tfdt")).body[4..12], .big));
    const trun = (try TestBox.find(traf, "trun")).body;
    // Version 1 (signed composition offsets).
    try std.testing.expectEqualSlices(u8, &.{ 1, 0x00, 0x0F, 0x01 }, trun[0..4]);
    try std.testing.expectEqual(2, std.mem.readInt(u32, trun[4..8], .big));
    // The data offset, from moof's start (default-base-is-moof), is just past mdat's header.
    try std.testing.expectEqual(header.len, std.mem.readInt(u32, trun[8..12], .big));
    try std.testing.expectEqualSlices(u8, &.{
        0x00, 0x05, 0x16, 0x15, 0, 0, 0x03, 0xe8, 0x02, 0,    0,    0,    0x00, 0x0a, 0x2c, 0x2a,
        0x00, 0x05, 0x16, 0x16, 0, 0, 0x00, 0xc8, 0x01, 0x01, 0,    0,    0xff, 0xfa, 0xe9, 0xeb,
    }, trun[12..]);
    // And read back, as recovery does: the first frame shown its offset after its decode time.
    try std.testing.expectEqual(MoofInfo{ .sequence = 7, .decode_time = 123_456_789_000, .time = 123_456_789_000 + 666_666, .keyframe = true }, try parseMoof(top[0].body));
    try std.testing.expectError(error.BadFragment, parseMoof(top[0].body[0 .. top[0].body.len - 1]));
}

const std = @import("std");
