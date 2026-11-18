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
        // With a fixed block size, frames are numbered in at most 31 bits (RFC 9639 section
        // 9.1.5): about 5.8 years of audio at 48 kHz.
        if (e.frame_number >= 1 << 31) std.debug.panic("FLAC frame number {d} is past the 31 bits a fixed block size allows", .{e.frame_number});
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

/// A frame or sample number, in FLAC's UTF-8-like variable length coding: up to 7 bytes and
/// 36 bits, though frame numbers (all this encoder writes) stop at 6 bytes and 31 bits.
fn writeCodedNumber(w: *BitWriter, v: u64) void {
    if (v < 0x80) return w.bits(v, 8);
    const n: u3 = if (v < 0x800) 2 else if (v < 0x10000) 3 else if (v < 0x200000) 4 else if (v < 0x4000000) 5 else if (v < 0x80000000) 6 else 7;
    if (v >= 1 << 36) std.debug.panic("{d} is past the 36 bits FLAC's coded numbers hold", .{v});
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

// The checksums' standard check values (CRC-8/SMBUS and CRC-16/UMTS, which are FLAC's): a
// wrong polynomial or bit order makes every frame look damaged to a decoder.
test "frame checksums" {
    try std.testing.expectEqual(0xF4, crc8("123456789"));
    try std.testing.expectEqual(0xFEE8, crc16("123456789"));
    try std.testing.expectEqual(0, crc8(""));
    try std.testing.expectEqual(0, crc16(""));
}

// Coded numbers are like UTF-8, extended to 7 bytes and 36 bits (for sample numbers; frame
// numbers stop at 6 bytes and 31 bits, see writeFrameHeader).
test writeCodedNumber {
    var out: [8]u8 = undefined;
    var utf8: [4]u8 = undefined;
    for ([_]u21{ 0, 0x7F, 0x80, 0x7FF, 0x800, 0xD7FF, 0xE000, 0xFFFF, 0x10000, 0x10FFFF }) |v| {
        var w: BitWriter = .{ .out = &out };
        writeCodedNumber(&w, v);
        const n = try std.unicode.utf8Encode(v, &utf8);
        try std.testing.expectEqualSlices(u8, utf8[0..n], out[0..w.len()]);
    }
    // Past UTF-8: each length's first and last.
    const long = [_]struct { u64, usize }{
        .{ 0x10FFFF + 1, 4 }, .{ 0x1FFFFF, 4 },
        .{ 0x200000, 5 },     .{ 0x3FFFFFF, 5 },
        .{ 0x4000000, 6 },    .{ 0x7FFFFFFF, 6 },
        .{ 0x80000000, 7 },   .{ (1 << 36) - 1, 7 },
    };
    for (long) |c| {
        var w: BitWriter = .{ .out = &out };
        writeCodedNumber(&w, c[0]);
        try std.testing.expectEqual(c[1], w.len());
        var r: TestBitReader = .{ .in = out[0..w.len()] };
        try std.testing.expectEqual(c[0], try r.codedNumber(7));
    }
    var w: BitWriter = .{ .out = &out };
    writeCodedNumber(&w, (1 << 36) - 1);
    try std.testing.expectEqualSlices(u8, &.{ 0xFE, 0xBF, 0xBF, 0xBF, 0xBF, 0xBF, 0xBF }, out[0..7]);
}

// ---------------------------------------------------------------------------
// Round trips: a decoder for what this encoder writes, written from RFC 9639 rather than from
// the encoder, so a stream that decodes here to the samples that went in is lossless and
// well-formed. It checks every field it can, and fails on anything the encoder shouldn't
// write.
// ---------------------------------------------------------------------------

/// Reads bits most significant first. Running out is a test failure.
const TestBitReader = struct {
    in: []const u8,
    /// In bits.
    pos: usize = 0,

    fn bits(r: *TestBitReader, count: u7) !u64 {
        var v: u64 = 0;
        for (0..count) |_| {
            if (r.pos == r.in.len * 8) {
                std.debug.print("a frame of {d} bytes ended inside a field\n", .{r.in.len});
                return error.EndOfFrame;
            }
            v = (v << 1) | ((r.in[r.pos / 8] >> @intCast(7 - r.pos % 8)) & 1);
            r.pos += 1;
        }
        return v;
    }

    /// Two's complement, `count` bits.
    fn signed(r: *TestBitReader, count: u8) !i64 {
        const shift: u6 = @intCast(64 - @as(u32, count));
        return @as(i64, @bitCast(try r.bits(@intCast(count)) << shift)) >> shift;
    }

    fn unary(r: *TestBitReader) !u64 {
        var q: u64 = 0;
        while (try r.bits(1) == 0) q += 1;
        return q;
    }

    /// At most `max_len` bytes: 6 for a frame number (31 bits), 7 for a sample number.
    fn codedNumber(r: *TestBitReader, max_len: u4) !u64 {
        const first = try r.bits(8);
        if (first < 0x80) return first;
        const len: u4 = @clz(~@as(u8, @intCast(first)));
        if (len < 2 or len > max_len) {
            std.debug.print("coded number's first byte 0x{x} isn't a lead byte of at most {d} bytes\n", .{ first, max_len });
            return error.BadCodedNumber;
        }
        var v = first & (@as(u64, 0x7F) >> len);
        for (1..len) |_| {
            const c = try r.bits(8);
            if (c & 0xC0 != 0x80) return error.BadCodedNumber;
            v = (v << 6) | (c & 0x3F);
        }
        return v;
    }

    /// Whole bytes read, which must be all of them.
    fn bytesRead(r: *const TestBitReader) usize {
        std.debug.assert(r.pos % 8 == 0);
        return r.pos / 8;
    }
};

/// A decoded frame's header.
const TestFrame = struct {
    /// Frames (samples per channel).
    n: usize,
    number: u64,
    /// The channel assignment code: channels - 1 when independent, else 8 (left/side),
    /// 9 (side/right) or 10 (mid/side).
    assignment: u4,
    /// The block size code: 12 for block_size, 6 for an 8-bit size after the frame number,
    /// 7 for a 16-bit one.
    size_code: u4,
};

/// Decodes `frame`, exactly one frame, into `out` (per channel) and checks both its CRCs.
fn testDecodeFrame(frame: []const u8, f: Format, out: *[max_channels][block_size]i32) !TestFrame {
    const expect = std.testing.expectEqual;
    var r: TestBitReader = .{ .in = frame };
    try expect(0xFFF8, try r.bits(16)); // sync, reserved 0, fixed block size
    const size_code: u4 = @intCast(try r.bits(4));
    try expect(0, try r.bits(4)); // sample rate: STREAMINFO's
    const assignment: u4 = @intCast(try r.bits(4));
    try expect(@as(u64, switch (f.bits) {
        8 => 1,
        12 => 2,
        16 => 4,
        20 => 5,
        24 => 6,
        else => 0,
    }), try r.bits(3));
    try expect(0, try r.bits(1));
    // A frame number: the blocking strategy bit (in the sync code) is 0, fixed.
    const number = try r.codedNumber(6);
    const n: usize = switch (size_code) {
        6 => @intCast(try r.bits(8) + 1),
        7 => @intCast(try r.bits(16) + 1),
        12 => block_size,
        else => {
            std.debug.print("unexpected block size code {d}\n", .{size_code});
            return error.TestUnexpectedResult;
        },
    };
    try expect(crc8(frame[0..r.bytesRead()]), try r.bits(8));

    // Which subframe is a side channel, coded with an extra bit.
    const side: ?usize = switch (assignment) {
        8, 10 => 1,
        9 => 0,
        else => null,
    };
    if (side != null) try expect(2, f.channels) else try expect(f.channels - 1, assignment);
    for (0..f.channels) |ch| {
        try testDecodeSubframe(&r, if (side == ch) f.bits + 1 else f.bits, out[ch][0..n]);
    }
    if (side != null) for (out[0][0..n], out[1][0..n]) |*a, *b| {
        const x: i64 = a.*;
        const y: i64 = b.*;
        const left: i64, const right: i64 = switch (assignment) {
            8 => .{ x, x - y },
            9 => .{ x + y, y },
            10 => blk: {
                const mid = (x << 1) | (y & 1);
                break :blk .{ (mid + y) >> 1, (mid - y) >> 1 };
            },
            else => unreachable,
        };
        a.* = try testSample(left, f.bits);
        b.* = try testSample(right, f.bits);
    };

    // Zero bits to the byte, then the CRC-16 of everything before it.
    while (r.pos % 8 != 0) try expect(0, try r.bits(1));
    try expect(crc16(frame[0..r.bytesRead()]), try r.bits(16));
    try expect(frame.len, r.bytesRead());
    return .{ .n = n, .number = number, .assignment = assignment, .size_code = size_code };
}

fn testDecodeSubframe(r: *TestBitReader, bits: u8, x: []i32) !void {
    try std.testing.expectEqual(0, try r.bits(1));
    const kind = try r.bits(6);
    const wasted: u8 = if (try r.bits(1) == 1) @intCast(try r.unary() + 1) else 0;
    if (wasted >= bits) {
        std.debug.print("{d} wasted bits of {d}\n", .{ wasted, bits });
        return error.TestUnexpectedResult;
    }
    const eff = bits - wasted;
    switch (kind) {
        0 => {
            const v = try r.signed(eff);
            for (x) |*s| s.* = @intCast(v);
        },
        1 => for (x) |*s| {
            s.* = @intCast(try r.signed(eff));
        },
        8...12 => {
            const order: usize = @intCast(kind - 8);
            for (x[0..order]) |*s| s.* = @intCast(try r.signed(eff));
            try testDecodeResidual(r, x, order, eff);
        },
        else => {
            std.debug.print("unexpected subframe type {d}\n", .{kind});
            return error.TestUnexpectedResult;
        },
    }
    for (x) |*s| s.* <<= @intCast(wasted);
}

/// A decoded sample, which must fit in `bits` (signed): one that doesn't means the stream is
/// wrong, and the test says so instead of overflowing.
fn testSample(v: i64, bits: u8) !i32 {
    const max = (@as(i64, 1) << @intCast(bits - 1)) - 1;
    if (v < -max - 1 or v > max) {
        std.debug.print("decoded sample {d} doesn't fit in {d} bits\n", .{ v, bits });
        return error.TestUnexpectedResult;
    }
    return @intCast(v);
}

/// The fixed predictors' coefficients, newest sample first (RFC 9639 section 9.2.5).
const test_fixed_coefficients = [_][]const i64{ &.{}, &.{1}, &.{ 2, -1 }, &.{ 3, -3, 1 }, &.{ 4, -6, 4, -1 } };

fn testDecodeResidual(r: *TestBitReader, x: []i32, order: usize, bits: u8) !void {
    const param_bits: u7 = switch (try r.bits(2)) {
        0 => 4,
        1 => 5,
        else => return error.TestUnexpectedResult,
    };
    const partition_order: u6 = @intCast(try r.bits(4));
    const parts = @as(usize, 1) << partition_order;
    try std.testing.expectEqual(0, x.len % parts);
    const part_len = x.len / parts;
    if (part_len <= order) return error.TestUnexpectedResult;
    var i = order;
    for (0..parts) |j| {
        const k: u6 = @intCast(try r.bits(param_bits));
        // The escape code (samples stored unencoded): this encoder never needs it.
        if (k == (@as(u6, 1) << @intCast(param_bits)) - 1) {
            std.debug.print("partition {d} has the escape code\n", .{j});
            return error.TestUnexpectedResult;
        }
        for (0..part_len - if (j == 0) order else 0) |_| {
            const u = (try r.unary() << k) | try r.bits(k);
            const residual: i64 = @as(i64, @intCast(u >> 1)) ^ -@as(i64, @intCast(u & 1));
            var prediction: i64 = 0;
            for (test_fixed_coefficients[order], 1..) |c, back| prediction += c * x[i - back];
            x[i] = try testSample(prediction + residual, bits);
            i += 1;
        }
    }
    try std.testing.expectEqual(x.len, i);
}

/// An encoder, a decoder's output and a frame: too big for the stack together, so the tests
/// share one (the test runner runs one test at a time).
const TestCodec = struct {
    encoder: Encoder,
    decoded: [max_channels][block_size]i32,
    frame: [18 + max_channels * (2 + 25 * block_size / 8 + 1)]u8,
    /// The first frames' headers, as testRoundTrip decoded them.
    frames: [8]TestFrame,
    frame_count: usize,

    /// Fails unless every frame of the last round trip had channel assignment `want`.
    fn expectAssignment(c: *const TestCodec, want: u4) !void {
        for (c.frames[0..c.frame_count], 0..) |frame, i| {
            if (frame.assignment != want) {
                std.debug.print("frame {d} has channel assignment {d}, expected {d}\n", .{ i, frame.assignment, want });
                return error.TestExpectedEqual;
            }
        }
    }
};

var test_codec: TestCodec = undefined;

/// Encodes `samples` (interleaved) a block at a time, then decodes each frame and checks it
/// gives back what went in, and that STREAMINFO describes the stream. Returns the stream's
/// bytes, header excluded.
fn testRoundTrip(c: *TestCodec, f: Format, samples: []const i32) !usize {
    c.encoder = .init(f);
    const channels: usize = f.channels;
    var total: usize = 0;
    var min_len: usize = std.math.maxInt(usize);
    var max_len: usize = 0;
    var frame_index: usize = 0;
    var at: usize = 0;
    while (at < samples.len) : (frame_index += 1) {
        const block = samples[at..@min(samples.len, at + block_size * channels)];
        const number = c.encoder.frame_number;
        const len = c.encoder.encode(block, &c.frame);
        try std.testing.expect(len <= Encoder.maxFrameLen(f));
        const frame = try testDecodeFrame(c.frame[0..len], f, &c.decoded);
        try std.testing.expectEqual(block.len / channels, frame.n);
        try std.testing.expectEqual(number, frame.number);
        if (frame_index < c.frames.len) {
            c.frames[frame_index] = frame;
            c.frame_count = frame_index + 1;
        }
        for (0..frame.n) |i| for (0..channels) |ch| {
            const want = block[i * channels + ch];
            const got = c.decoded[ch][i];
            if (want != got) {
                std.debug.print("frame {d}, sample {d} channel {d}: encoded {d}, decoded {d}\n", .{ frame_index, i, ch, want, got });
                return error.TestExpectedEqual;
            }
        };
        total += len;
        min_len = @min(min_len, len);
        max_len = @max(max_len, len);
        at += block.len;
    }

    // STREAMINFO, as the header written when the stream ends has it.
    var header: [header_len]u8 = undefined;
    const tags: Tags = .{};
    writeHeader(&header, f, c.encoder.info, &tags);
    var r: TestBitReader = .{ .in = header[8..][0..34] };
    try std.testing.expectEqual(block_size, try r.bits(16));
    try std.testing.expectEqual(block_size, try r.bits(16));
    try std.testing.expectEqual(min_len, try r.bits(24));
    try std.testing.expectEqual(max_len, try r.bits(24));
    try std.testing.expectEqual(f.sample_rate, try r.bits(20));
    try std.testing.expectEqual(f.channels - 1, try r.bits(3));
    try std.testing.expectEqual(f.bits - 1, try r.bits(5));
    try std.testing.expectEqual(samples.len / channels, try r.bits(36));
    return total;
}

/// Frames for the tests' signals: two full blocks and a shorter last one.
const test_frames = 2 * block_size + 300;

/// A smooth signal, cheap for the fixed predictors: two slow sines, up to 7 million.
fn testSmooth(i: usize) i32 {
    const t: f64 = @floatFromInt(i);
    return @intFromFloat(@sin(t * 0.03) * 4_000_000 + @sin(t * 0.0071) * 3_000_000);
}

// Stereo picks whichever pair of channels is cheapest. One channel smooth, the other a little
// noise away from it: the smooth one and the side (the noise) are, and which channel is smooth
// decides left/side or side/right.
test "stereo, left smooth and right near it: left/side" {
    const c = &test_codec;
    var rng: std.Random.DefaultPrng = .init(1);
    var samples: [test_frames * 2]i32 = undefined;
    for (0..test_frames) |i| {
        const v = testSmooth(i);
        samples[2 * i] = v;
        samples[2 * i + 1] = v + rng.random().intRangeAtMost(i32, -50, 50);
    }
    const len = try testRoundTrip(c, .{ .sample_rate = 48000, .channels = 2, .bits = 24 }, &samples);
    try c.expectAssignment(8);
    // Smooth and correlated: far smaller than the 6 bytes a frame it came as.
    try std.testing.expect(len < test_frames * 6 / 3);
}

test "stereo, right smooth and left near it: side/right" {
    const c = &test_codec;
    var rng: std.Random.DefaultPrng = .init(4);
    var samples: [test_frames * 2]i32 = undefined;
    for (0..test_frames) |i| {
        const v = testSmooth(i);
        samples[2 * i] = v + rng.random().intRangeAtMost(i32, -50, 50);
        samples[2 * i + 1] = v;
    }
    _ = try testRoundTrip(c, .{ .sample_rate = 48000, .channels = 2, .bits = 24 }, &samples);
    try c.expectAssignment(9);
}

// Noise opposite either side of a smooth middle: only the mid is smooth. The channels' sum is
// odd, so every side sample is odd and the mid's low bit, which the mid channel drops, must come
// back from the side.
test "stereo, a smooth middle with noise either side: mid/side, every side odd" {
    const c = &test_codec;
    var rng: std.Random.DefaultPrng = .init(5);
    var samples: [test_frames * 2]i32 = undefined;
    for (0..test_frames) |i| {
        const v = testSmooth(i);
        const noise = rng.random().intRangeAtMost(i32, -50, 50);
        samples[2 * i] = v + noise;
        samples[2 * i + 1] = v - noise + 1;
    }
    _ = try testRoundTrip(c, .{ .sample_rate = 48000, .channels = 2, .bits = 24 }, &samples);
    try c.expectAssignment(10);
}

test "noise at full scale, mono and stereo: lossless" {
    const c = &test_codec;
    var rng: std.Random.DefaultPrng = .init(2);
    var samples: [(block_size + 1) * 2]i32 = undefined;
    for ([_]u8{ 16, 24 }) |bits| {
        const max = (@as(i32, 1) << @intCast(bits - 1)) - 1;
        for (&samples) |*s| s.* = rng.random().intRangeAtMost(i32, -max - 1, max);
        // The extremes, side by side: the largest residuals.
        samples[0] = max;
        samples[1] = -max - 1;
        samples[2] = -max - 1;
        samples[3] = max;
        // A last frame of a single sample.
        _ = try testRoundTrip(c, .{ .sample_rate = 44100, .channels = 1, .bits = bits }, samples[0 .. block_size + 1]);
        _ = try testRoundTrip(c, .{ .sample_rate = 44100, .channels = 2, .bits = bits }, &samples);
        // Uncorrelated: a side channel would only cost its extra bit.
        try c.expectAssignment(1);
    }
}

// Left opposite right at full scale: the mid is constant, the side the widest it can be (25
// bits, every sample odd).
test "a full-scale square wave, left opposite right: mid/side, the widest side channel" {
    const c = &test_codec;
    var samples: [test_frames * 2]i32 = undefined;
    const max = (1 << 23) - 1;
    for (0..test_frames) |i| {
        const v: i32 = if (i / 3 % 2 == 0) max else -max - 1;
        samples[2 * i] = v;
        samples[2 * i + 1] = if (v == max) -max - 1 else max;
    }
    _ = try testRoundTrip(c, .{ .sample_rate = 48000, .channels = 2, .bits = 24 }, &samples);
    try c.expectAssignment(10);
}

test "constants and silence, on every channel: tiny, at each block size code" {
    const c = &test_codec;
    const values = [max_channels]i32{ 0, 0, 1, -1, 127, -128, 42, -42 };
    var samples: [(block_size + 257) * max_channels]i32 = undefined;
    for (&samples, 0..) |*s, i| s.* = values[i % max_channels];
    const f: Format = .{ .sample_rate = 8000, .channels = max_channels, .bits = 8 };
    // A block (its own code), then the last at 256 frames (an 8-bit size) or 257 (16-bit).
    for ([_]struct { usize, u4 }{ .{ 256, 6 }, .{ 257, 7 } }) |last| {
        const len = try testRoundTrip(c, f, samples[0 .. (block_size + last[0]) * max_channels]);
        try std.testing.expect(len < 2 * 64);
        try std.testing.expectEqual(2, c.frame_count);
        try std.testing.expectEqual(12, c.frames[0].size_code);
        try std.testing.expectEqual(last[1], c.frames[1].size_code);
    }
}

test "samples with zero low bits: lossless, and the zeros not stored" {
    const c = &test_codec;
    var rng: std.Random.DefaultPrng = .init(3);
    // 16-bit audio in 24 bits (8 zero bits), then a channel of nothing but the extremes
    // (23 zero bits).
    var samples: [block_size * 2]i32 = undefined;
    for (0..block_size) |i| {
        samples[2 * i] = @as(i32, rng.random().int(i16)) << 8;
        samples[2 * i + 1] = if (rng.random().boolean()) 0 else -(1 << 23);
    }
    const f: Format = .{ .sample_rate = 48000, .channels = 2, .bits = 24 };
    const len = try testRoundTrip(c, f, &samples);
    // Each its own zeros: a side channel would share neither's.
    try c.expectAssignment(1);
    // Noise both: no better than verbatim at 16 bits and 1.
    try std.testing.expect(len < block_size * (16 + 1) / 8 + 64);
}

test "sample sizes FLAC has no code for: from STREAMINFO" {
    const c = &test_codec;
    var samples: [600]i32 = undefined;
    for ([_]u8{ 4, 13, 23 }) |bits| {
        const max = (@as(i32, 1) << @intCast(bits - 1)) - 1;
        for (&samples, 0..) |*s, i| s.* = @intCast(@mod(@as(i64, @intCast(i)) * 7919, 2 * @as(i64, max) + 2) - max - 1);
        _ = try testRoundTrip(c, .{ .sample_rate = 96000, .channels = 3, .bits = bits }, &samples);
    }
}

// Up to the last a fixed block size can number, in 6 bytes.
test "frame numbers past one byte" {
    const c = &test_codec;
    const f: Format = .{ .sample_rate = 48000, .channels = 1, .bits = 16 };
    const samples = [_]i32{ 5, -3, 100, 7 };
    for ([_]u64{ 0x7F, 0x80, 0x12345, (1 << 31) - 1 }) |number| {
        c.encoder = .init(f);
        c.encoder.frame_number = number;
        const len = c.encoder.encode(&samples, &c.frame);
        const frame = try testDecodeFrame(c.frame[0..len], f, &c.decoded);
        try std.testing.expectEqual(number, frame.number);
        try std.testing.expectEqualSlices(i32, &samples, c.decoded[0][0..samples.len]);
    }
}

const std = @import("std");
