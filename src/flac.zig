//! A FLAC encoder (RFC 9639): fixed predictors, stereo decorrelation, wasted bits and
//! partitioned Rice coding. No allocation: the caller provides every buffer.
//!
//! A stream is `header_len` bytes of header (see writeHeader), then frames (see
//! Encoder.encode). Each frame is independent and checksummed, so a stream cut off mid-write
//! (a crash, a power cut) still decodes up to its last complete frame.

/// Frames (samples per channel) per FLAC frame, except the last, which may be shorter. At
/// 48 kHz, 85 ms.
pub const block_size = 4096;

pub const Format = struct {
    sample_rate: u32,
    channels: u8,
    /// Bits per sample. At most 24, so residuals, including stereo's side channel, fit in i32.
    bits: u8,

    fn check(f: Format) void {
        if (f.sample_rate == 0 or f.sample_rate >= 1 << 20) std.debug.panic("FLAC can't store a {d} Hz sample rate", .{f.sample_rate});
        if (f.channels == 0 or f.channels > max_channels) std.debug.panic("FLAC can't store {d} channels, at most {d}", .{ f.channels, max_channels });
        if (f.bits < 4 or f.bits > 24) std.debug.panic("this FLAC encoder stores 4 to 24 bits per sample, not {d}", .{f.bits});
    }
};

pub const max_channels = 8;

/// What the header records about a whole stream. Unknown (zero) until the stream ends;
/// decoders handle that, so a stream that never finished still decodes.
pub const StreamInfo = struct {
    min_frame_len: u24 = 0,
    max_frame_len: u24 = 0,
    total_frames: u36 = 0,
};

/// The stream header: "fLaC", the STREAMINFO block, then tags_area bytes for the tags (a
/// VORBIS_COMMENT block, then a PADDING block filling the rest). Its size never changes, so
/// it's rewritten in place when the stream ends and the tags are known, without moving the
/// audio after it.
pub const header_len = 4 + 4 + 34 + tags_area;
pub const tags_area = 4096;
/// The VORBIS_COMMENT block's vendor string.
const vendor = "Black Box";

/// Metadata block types (the low 7 bits of a block header's first byte).
const BlockType = enum(u7) { streaminfo = 0, padding = 1, vorbis_comment = 4 };

/// Vorbis comments ("KEY=value", the tags FLAC files carry), encoded as the block holds them.
pub const Tags = struct {
    /// Each comment: its length (32-bit little-endian), then its bytes.
    buf: [max_len]u8 = undefined,
    len: usize = 0,
    count: u32 = 0,

    /// What's left of tags_area for the comments: the area less the two blocks' headers, the
    /// vendor string with its length, and the comment count.
    const max_len = tags_area - 4 - (4 + vendor.len + 4) - 4;

    /// Adds `KEY=value`, the value formatted. Panics if the area is full: callers keep their
    /// values bounded (see the tags in record.zig).
    pub fn add(t: *Tags, comptime key: []const u8, comptime fmt: []const u8, args: anytype) void {
        var w: std.Io.Writer = .fixed(t.buf[t.len..]);
        w.writeInt(u32, 0, .little) catch std.debug.panic("FLAC tags don't fit in {d} bytes", .{tags_area});
        w.print(key ++ "=" ++ fmt, args) catch std.debug.panic("FLAC tags don't fit in {d} bytes", .{tags_area});
        const n = w.buffered().len;
        std.mem.writeInt(u32, t.buf[t.len..][0..4], @intCast(n - 4), .little);
        t.len += n;
        t.count += 1;
    }
};

pub fn writeHeader(out: *[header_len]u8, f: Format, info: StreamInfo, tags: *const Tags) void {
    f.check();
    var w: BitWriter = .{ .out = out };
    w.bytes("fLaC");
    // Metadata block header: not the last block, type 0 (STREAMINFO), 34 bytes.
    w.bits(0, 1);
    w.bits(@intFromEnum(BlockType.streaminfo), 7);
    w.bits(34, 24);
    w.bits(block_size, 16); // min block size; the last block may be shorter, that's allowed
    w.bits(block_size, 16); // max block size
    w.bits(info.min_frame_len, 24);
    w.bits(info.max_frame_len, 24);
    w.bits(f.sample_rate, 20);
    w.bits(f.channels - 1, 3);
    w.bits(f.bits - 1, 5);
    w.bits(info.total_frames, 36);
    // MD5 of the decoded audio; zero means not computed.
    for (0..16) |_| w.bits(0, 8);

    // VORBIS_COMMENT (type 4): its lengths little-endian, unlike the rest of FLAC.
    const comment_len = 4 + vendor.len + 4 + tags.len;
    w.bits(0, 1);
    w.bits(@intFromEnum(BlockType.vorbis_comment), 7);
    w.bits(comment_len, 24);
    const rest = out[w.len()..];
    std.mem.writeInt(u32, rest[0..4], vendor.len, .little);
    @memcpy(rest[4..][0..vendor.len], vendor);
    std.mem.writeInt(u32, rest[4 + vendor.len ..][0..4], tags.count, .little);
    @memcpy(rest[8 + vendor.len ..][0..tags.len], tags.buf[0..tags.len]);
    // PADDING (type 1), the last block: the rest of the area, zeros.
    const padding = rest[comment_len..];
    const padding_len = padding.len - 4;
    padding[0] = 0x80 | @as(u8, @intFromEnum(BlockType.padding));
    padding[1] = @truncate(padding_len >> 16);
    padding[2] = @truncate(padding_len >> 8);
    padding[3] = @truncate(padding_len);
    @memset(padding[4..], 0);
}

pub const Encoder = struct {
    format: Format,
    frame_number: u64 = 0,
    info: StreamInfo = .{},
    /// One block of samples per channel, deinterleaved, then stereo's side and mid.
    channel: [max_channels + 2][block_size]i32 = undefined,

    pub fn init(f: Format) Encoder {
        f.check();
        return .{ .format = f };
    }

    /// The most bytes encode can produce for one frame: every subframe verbatim.
    pub fn maxFrameLen(f: Format) usize {
        // Header (at most 16 bytes) and CRC-16, then per channel a subframe header and samples
        // (stereo's side has an extra bit).
        return 18 + @as(usize, f.channels) * (2 + (@as(usize, f.bits) + 1) * block_size / 8 + 1);
    }

    /// Encodes one frame from `samples`, interleaved, 1 to block_size frames of them. Only
    /// the last frame of a stream may have fewer than block_size. Returns the bytes written
    /// to `out`, which must hold maxFrameLen.
    pub fn encode(e: *Encoder, samples: []const i32, out: []u8) usize {
        const f = e.format;
        const channels: usize = f.channels;
        std.debug.assert(samples.len % channels == 0);
        const n = samples.len / channels;
        std.debug.assert(n >= 1 and n <= block_size);
        std.debug.assert(out.len >= maxFrameLen(f));

        for (0..channels) |ch| {
            for (e.channel[ch][0..n], 0..) |*s, i| s.* = samples[i * channels + ch];
        }

        // Stereo: try coding the difference (side) with one channel, or with the average (mid).
        // For a voice recorded on two channels that are nearly the same, side is nearly
        // silent and costs almost nothing.
        var assignment: Assignment = .independent;
        var plans: [max_channels]Plan = undefined;
        if (channels == 2) {
            const left = e.channel[0][0..n];
            const right = e.channel[1][0..n];
            const side = e.channel[max_channels][0..n];
            const mid = e.channel[max_channels + 1][0..n];
            for (left, right, side, mid) |l, r, *s, *m| {
                s.* = l - r;
                m.* = (l + r) >> 1;
            }
            const p_left = plan(left, f.bits);
            const p_right = plan(right, f.bits);
            const p_side = plan(side, f.bits + 1);
            const p_mid = plan(mid, f.bits);
            const options = [_]struct { Assignment, Plan, Plan }{
                .{ .independent, p_left, p_right },
                .{ .left_side, p_left, p_side },
                .{ .side_right, p_side, p_right },
                .{ .mid_side, p_mid, p_side },
            };
            var best = options[0];
            for (options[1..]) |o| {
                if (o[1].cost + o[2].cost < best[1].cost + best[2].cost) best = o;
            }
            assignment = best[0];
            plans[0] = best[1];
            plans[1] = best[2];
        } else {
            for (0..channels) |ch| plans[ch] = plan(e.channel[ch][0..n], f.bits);
        }

        var w: BitWriter = .{ .out = out };
        e.writeFrameHeader(&w, n, assignment);
        for (0..channels) |ch| {
            const source, const bits = assignment.subframe(ch, f.bits);
            writeSubframe(&w, e.channel[source][0..n], bits, plans[ch]);
        }
        w.alignToByte();
        const crc = crc16(out[0..w.len()]);
        w.bits(crc, 16);

        const len = w.len();
        e.frame_number += 1;
        e.info.total_frames +%= @intCast(n);
        if (e.info.min_frame_len == 0 or len < e.info.min_frame_len) e.info.min_frame_len = @intCast(len);
        e.info.max_frame_len = @max(e.info.max_frame_len, @as(u24, @intCast(len)));
        return len;
    }

    fn writeFrameHeader(e: *const Encoder, w: *BitWriter, n: usize, assignment: Assignment) void {
        const start = w.len();
        // Sync code, a reserved 0, and fixed block size.
        w.bits(0xFFF8, 16);
        // Block size: block_size has a code of its own; a shorter last block is given after
        // the frame number.
        const size_code: u4 = if (n == block_size) 12 else if (n <= 256) 6 else 7;
        w.bits(size_code, 4);
        // Sample rate: from STREAMINFO.
        w.bits(0, 4);
        w.bits(switch (assignment) {
            .independent => e.format.channels - 1,
            .left_side => 8,
            .side_right => 9,
            .mid_side => 10,
        }, 4);
        w.bits(switch (e.format.bits) {
            8 => 1,
            12 => 2,
            16 => 4,
            20 => 5,
            24 => 6,
            else => 0, // from STREAMINFO
        }, 3);
        w.bits(0, 1);
        writeCodedNumber(w, e.frame_number);
        switch (size_code) {
            6 => w.bits(n - 1, 8),
            7 => w.bits(n - 1, 16),
            else => {},
        }
        std.debug.assert(w.bit_count == 0);
        w.bits(crc8(w.out[start..w.len()]), 8);
    }
};

/// How a stereo frame's two subframes relate to the left and right channels.
const Assignment = enum {
    independent,
    left_side,
    side_right,
    mid_side,

    /// Which of Encoder.channel subframe `ch` codes, and at how many bits.
    fn subframe(a: Assignment, ch: usize, bits: u8) struct { usize, u8 } {
        const side = .{ max_channels, bits + 1 };
        return switch (a) {
            .independent => .{ ch, bits },
            .left_side => if (ch == 0) .{ 0, bits } else side,
            .side_right => if (ch == 0) side else .{ 1, bits },
            .mid_side => if (ch == 0) .{ max_channels + 1, bits } else side,
        };
    }
};

/// How to code one subframe, and its cost in bits.
const Plan = struct {
    kind: union(enum) {
        constant,
        verbatim,
        fixed: struct { order: u3, rice: RicePlan },
    },
    /// Trailing zero bits shared by every sample, stored once instead of in each sample.
    wasted: u5,
    cost: u64,
};

const max_partition_order = 8;

const RicePlan = struct {
    partition_order: u4,
    /// Rice parameters past 14 need the 5-bit parameter coding method.
    wide: bool,
    params: [1 << max_partition_order]u5,
};

const max_fixed_order = 4;

fn plan(x: []const i32, bits: u8) Plan {
    const n = x.len;
    var any: i32 = 0;
    var all_same = true;
    for (x) |s| {
        any |= s;
        all_same = all_same and s == x[0];
    }
    // Subframe header: 1 + 6 + 1 bits.
    if (all_same) return .{ .kind = .constant, .wasted = 0, .cost = 8 + @as(u64, bits) };

    const wasted: u5 = @intCast(@ctz(any));
    const eff_bits = bits - wasted;
    // The wasted count is unary: wasted - 1 zeros, then a one.
    const header_bits: u64 = 8 + @as(u64, wasted);
    var best: Plan = .{ .kind = .verbatim, .wasted = wasted, .cost = header_bits + @as(u64, eff_bits) * n };

    var order: u3 = 0;
    while (order <= max_fixed_order) : (order += 1) {
        if (n <= order) break;
        const rice = planResidual(x, wasted, order) orelse continue;
        const cost = header_bits + @as(u64, eff_bits) * order + rice.cost;
        if (cost < best.cost) best = .{ .kind = .{ .fixed = .{ .order = order, .rice = rice.plan } }, .wasted = wasted, .cost = cost };
    }
    return best;
}

/// The residual of fixed predictor `order` at sample `i` (i >= order), samples shifted right by
/// `wasted`.
fn fixedResidual(x: []const i32, wasted: u5, order: u3, i: usize) i64 {
    const s = struct {
        fn at(xs: []const i32, w: u5, j: usize) i64 {
            return xs[j] >> w;
        }
    }.at;
    return switch (order) {
        0 => s(x, wasted, i),
        1 => s(x, wasted, i) - s(x, wasted, i - 1),
        2 => s(x, wasted, i) - 2 * s(x, wasted, i - 1) + s(x, wasted, i - 2),
        3 => s(x, wasted, i) - 3 * s(x, wasted, i - 1) + 3 * s(x, wasted, i - 2) - s(x, wasted, i - 3),
        4 => s(x, wasted, i) - 4 * s(x, wasted, i - 1) + 6 * s(x, wasted, i - 2) - 4 * s(x, wasted, i - 3) + s(x, wasted, i - 4),
        else => unreachable,
    };
}

fn zigzag(r: i64) u64 {
    return @bitCast((r << 1) ^ (r >> 63));
}

/// The cheapest partitioned Rice coding of a fixed predictor's residual, or null if a residual
/// doesn't fit in the 32 bits FLAC allows.
const RiceChoice = struct { plan: RicePlan, cost: u64 };

fn planResidual(x: []const i32, wasted: u5, order: u3) ?RiceChoice {
    const n = x.len;
    // Partition order p splits the block into 2^p partitions, each longer than the predictor
    // order (the first partition starts after the warm-up samples).
    var max_order: u4 = 0;
    while (max_order < max_partition_order) {
        const next = max_order + 1;
        if (n % (@as(usize, 1) << next) != 0 or (n >> next) <= order) break;
        max_order = next;
    }

    // Sum of zigzagged residuals per partition at the finest order; coarser orders add pairs.
    var sums: [1 << max_partition_order]u64 = @splat(0);
    const part_len = n >> max_order;
    for (order..n) |i| {
        const r = fixedResidual(x, wasted, order, i);
        if (r < std.math.minInt(i32) or r > std.math.maxInt(i32)) return null;
        sums[i / part_len] += zigzag(r);
    }

    var best: ?RiceChoice = null;
    var p: i8 = max_order;
    while (p >= 0) : (p -= 1) {
        const po: u4 = @intCast(p);
        const parts = @as(usize, 1) << po;
        if (po != max_order) {
            for (0..parts) |j| sums[j] = sums[2 * j] + sums[2 * j + 1];
        }
        var rice: RicePlan = .{ .partition_order = po, .wide = false, .params = undefined };
        var bits: u64 = 2 + 4; // coding method, partition order
        for (0..parts) |j| {
            const count = (n >> po) - (if (j == 0) order else 0);
            const k, const cost = bestRiceParam(sums[j], count);
            rice.params[j] = k;
            rice.wide = rice.wide or k > 14;
            bits += cost;
        }
        bits += parts * @as(u64, if (rice.wide) 5 else 4);
        if (best == null or bits < best.?.cost) best = .{ .plan = rice, .cost = bits };
    }
    return best.?;
}

/// The Rice parameter for a partition whose zigzagged residuals sum to `sum`, and its
/// estimated cost: each residual costs k + 1 bits plus its value shifted right by k, which
/// totals about count * (k + 1) + sum >> k.
fn bestRiceParam(sum: u64, count: usize) struct { u5, u64 } {
    if (count == 0) return .{ 0, 0 };
    const mean = sum / count;
    const guess: u5 = if (mean == 0) 0 else @intCast(@min(30, 63 - @clz(mean)));
    var best_k: u5 = guess;
    var best_cost: u64 = std.math.maxInt(u64);
    for ([_]u5{ guess -| 1, guess, @min(30, guess + 1) }) |k| {
        const cost = @as(u64, count) * (@as(u64, k) + 1) + (sum >> k);
        if (cost < best_cost) {
            best_cost = cost;
            best_k = k;
        }
    }
    return .{ best_k, best_cost };
}

fn writeSubframe(w: *BitWriter, x: []const i32, bits: u8, p: Plan) void {
    w.bits(0, 1);
    switch (p.kind) {
        .constant => {
            w.bits(0, 6);
            w.bits(0, 1);
            w.signed(x[0], bits);
            return;
        },
        .verbatim => w.bits(1, 6),
        .fixed => |fixed| w.bits(0b001000 | @as(u6, fixed.order), 6),
    }
    if (p.wasted == 0) {
        w.bits(0, 1);
    } else {
        w.bits(1, 1);
        w.bits(0, p.wasted - 1);
        w.bits(1, 1);
    }
    const eff_bits = bits - p.wasted;
    switch (p.kind) {
        .constant => unreachable,
        .verbatim => for (x) |s| w.signed(s >> p.wasted, eff_bits),
        .fixed => |fixed| {
            for (x[0..fixed.order]) |s| w.signed(s >> p.wasted, eff_bits);
            const rice = fixed.rice;
            w.bits(@intFromBool(rice.wide), 2);
            w.bits(rice.partition_order, 4);
            const parts = @as(usize, 1) << rice.partition_order;
            const part_len = x.len >> rice.partition_order;
            for (0..parts) |j| {
                const k = rice.params[j];
                w.bits(k, if (rice.wide) 5 else 4);
                const start = if (j == 0) fixed.order else j * part_len;
                for (start..(j + 1) * part_len) |i| {
                    const u = zigzag(fixedResidual(x, p.wasted, fixed.order, i));
                    w.unary(u >> k);
                    w.bits(u & ((@as(u64, 1) << k) - 1), k);
                }
            }
        },
    }
}

/// The frame number, in FLAC's UTF-8-like variable length coding.
fn writeCodedNumber(w: *BitWriter, v: u64) void {
    if (v < 0x80) return w.bits(v, 8);
    const n: u3 = if (v < 0x800) 2 else if (v < 0x10000) 3 else if (v < 0x200000) 4 else if (v < 0x4000000) 5 else if (v < 0x80000000) 6 else 7;
    if (v >= 1 << 36) std.debug.panic("FLAC frame number {d} is past what FLAC can number", .{v});
    // First byte: n ones, a zero, then the top bits.
    const lead: u64 = (@as(u64, 0xFF) << (8 - @as(u6, n))) & 0xFF;
    const shift: u6 = 6 * (@as(u6, n) - 1);
    w.bits(lead | (v >> shift), 8);
    var i: u6 = n - 1;
    while (i > 0) {
        i -= 1;
        w.bits(0x80 | ((v >> (6 * i)) & 0x3F), 8);
    }
}

/// Writes bits most significant first.
const BitWriter = struct {
    out: []u8,
    pos: usize = 0,
    acc: u64 = 0,
    bit_count: u6 = 0,

    fn bits(w: *BitWriter, value: u64, count: u7) void {
        var remaining = count;
        while (remaining > 0) {
            const take: u6 = @intCast(@min(remaining, 32));
            remaining -= take;
            const chunk = (value >> @intCast(remaining)) & ((@as(u64, 1) << take) - 1);
            w.acc = (w.acc << take) | chunk;
            w.bit_count += take;
            while (w.bit_count >= 8) {
                w.bit_count -= 8;
                w.out[w.pos] = @truncate(w.acc >> w.bit_count);
                w.pos += 1;
            }
        }
    }

    fn signed(w: *BitWriter, value: i64, count: u8) void {
        w.bits(@as(u64, @bitCast(value)) & ((@as(u64, 1) << @intCast(count)) - 1), @intCast(count));
    }

    /// `q` zeros, then a one.
    fn unary(w: *BitWriter, q: u64) void {
        var left = q;
        while (left >= 32) : (left -= 32) w.bits(0, 32);
        w.bits(1, @as(u7, @intCast(left)) + 1);
    }

    fn bytes(w: *BitWriter, b: []const u8) void {
        for (b) |c| w.bits(c, 8);
    }

    fn alignToByte(w: *BitWriter) void {
        if (w.bit_count != 0) w.bits(0, 8 - @as(u7, w.bit_count));
    }

    /// Whole bytes written so far.
    fn len(w: *const BitWriter) usize {
        return w.pos;
    }
};

fn crc8(data: []const u8) u8 {
    var crc: u8 = 0;
    for (data) |b| {
        crc ^= b;
        for (0..8) |_| crc = if (crc & 0x80 != 0) (crc << 1) ^ 0x07 else crc << 1;
    }
    return crc;
}

const crc16_table = blk: {
    @setEvalBranchQuota(10000);
    var table: [256]u16 = undefined;
    for (&table, 0..) |*t, i| {
        var crc: u16 = @as(u16, i) << 8;
        for (0..8) |_| crc = if (crc & 0x8000 != 0) (crc << 1) ^ 0x8005 else crc << 1;
        t.* = crc;
    }
    break :blk table;
};

fn crc16(data: []const u8) u16 {
    var crc: u16 = 0;
    for (data) |b| crc = (crc << 8) ^ crc16_table[(crc >> 8) ^ b];
    return crc;
}

// The header's metadata blocks are STREAMINFO, VORBIS_COMMENT and PADDING, in that order, the
// last flagged so, filling header_len exactly. (A wrong type once made Windows refuse every
// file: PADDING written as type 6, a PICTURE of zeros.)
test writeHeader {
    var tags: Tags = .{};
    tags.add("TITLE", "{s}", .{"Mic"});
    tags.add("GAPS", "{d}", .{0});
    var header: [header_len]u8 = undefined;
    writeHeader(&header, .{ .sample_rate = 48000, .channels = 2, .bits = 24 }, .{}, &tags);
    try std.testing.expectEqualStrings("fLaC", header[0..4]);
    const expected = [_]BlockType{ .streaminfo, .vorbis_comment, .padding };
    var at: usize = 4;
    for (expected, 0..) |kind, i| {
        const last = header[at] & 0x80 != 0;
        try std.testing.expectEqual(@intFromEnum(kind), header[at] & 0x7F);
        try std.testing.expectEqual(i == expected.len - 1, last);
        at += 4 + std.mem.readInt(u24, header[at + 1 ..][0..3], .big);
    }
    try std.testing.expectEqual(header_len, at);
    // The comments as the block holds them.
    const comments = header[4 + 4 + 34 + 4 ..];
    try std.testing.expectEqual(@as(u32, vendor.len), std.mem.readInt(u32, comments[0..4], .little));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, comments[4 + vendor.len ..][0..4], .little));
    try std.testing.expectEqualStrings("TITLE=Mic", comments[4 + vendor.len + 4 + 4 ..][0..9]);
}

const std = @import("std");
