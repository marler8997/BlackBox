//! Drift scenarios for resample.Aligner: a simulated device misbehaving in the ways real ones
//! do (clock drift, lost packets, stalls, restarts, wrong timestamps, steps), each checked for
//! staying in sync with the true clock (measured at every click of the signal), for ending
//! exactly with the recording, and for carrying on bit-exactly after a save and restore (what
//! crash recovery does).

const rate = 48000;
const packet = 480;
const seconds = 30;
const qpc_per_s = 10_000_000;
const start_qpc: u64 = 5_000_000_000;
/// When the restore check saves the aligner.
const save_at = 13.37;

/// The signal, at true time t (seconds): a click every half second (to measure sync by) and a
/// melody.
fn signal(t: f64) f64 {
    if (t < 0) return 0;
    const beat = 0.5;
    const since = @mod(t, beat);
    const n: usize = @intFromFloat(@floor(t / beat));
    const click = if (since < 0.006) 0.6 * @sin(2 * std.math.pi * 2000 * since) * @exp(-since / 0.0015) else 0;
    const notes = [_]f64{ 261.63, 293.66, 329.63, 392.0, 440.0, 392.0, 329.63, 293.66 };
    const f = notes[n % notes.len];
    const env = @min(since / 0.01, 1) * @exp(-since / 0.25);
    return click + 0.25 * env * @sin(2 * std.math.pi * f * t);
}

const Scenario = struct {
    name: []const u8,
    /// The device's clock error in ppm at true time t.
    ppm: *const fn (t: f64) f64 = zero,
    jitter_ms: f64 = 0.5,
    /// Packets lost around these times (seconds): five in a row each time.
    drops: []const f64 = &.{},
    flag_discontinuity: bool = false,
    /// The device stops counting at this time for stall_seconds.
    stall_at: ?f64 = null,
    stall_seconds: f64 = 0.3,
    /// The device restarts (its position goes back to 0) at this time.
    restart_at: ?f64 = null,
    /// Fraction of packets with a garbage timestamp, and whether Windows flags them.
    bad_timestamps: f64 = 0,
    flag_bad_timestamps: bool = false,
    /// The device repeats this much audio at this time: its timestamps go back.
    rewind_at: ?f64 = null,
    rewind_seconds: f64 = 0.01,
    /// The device delivers this long past the recording's end (it's detached a little after).
    past_end_seconds: f64 = 0,
    /// The worst sync error allowed at any click, and at the last.
    worst_ms: f64 = 1.5,
    last_ms: f64 = 0.8,
};

fn zero(_: f64) f64 {
    return 0;
}
fn plus300(_: f64) f64 {
    return 300;
}
fn plus42(_: f64) f64 {
    return 42;
}
fn wander(t: f64) f64 {
    return 100 * @sin(2 * std.math.pi * t / 40);
}

const scenarios = [_]Scenario{
    // 300 ppm is exaggerated: real clocks are tens of ppm off.
    .{ .name = "steady drift, 300 ppm", .ppm = plus300 },
    // Like the AmazonBasics mic measured.
    .{ .name = "real drift, 42 ppm", .ppm = plus42 },
    // The rate's line looks back (Fit.memory_seconds), so it lags a rate that keeps changing,
    // by about a millisecond at worst. Fitting the look-ahead's timestamps too would help.
    .{ .name = "drift wandering between -100 and +100 ppm", .ppm = wander, .last_ms = 1.1 },
    .{ .name = "50 ms of packets lost, three times", .ppm = plus42, .drops = &.{ 8, 14, 20 } },
    .{ .name = "lost packets, flagged DATA_DISCONTINUITY", .ppm = plus42, .drops = &.{ 8, 14, 20 }, .flag_discontinuity = true },
    .{ .name = "device stops counting for 300 ms", .ppm = plus42, .stall_at = 12 },
    .{ .name = "device restarts: its position goes back to 0", .ppm = plus42, .restart_at = 15 },
    .{ .name = "2% of timestamps garbage, flagged TIMESTAMP_ERROR", .ppm = plus42, .bad_timestamps = 0.02, .flag_bad_timestamps = true },
    .{ .name = "2% of timestamps garbage, unflagged", .ppm = plus42, .bad_timestamps = 0.02 },
    .{ .name = "timestamps jittered by +-3 ms", .ppm = plus42, .jitter_ms = 6 },
    // The click at the step genuinely wasn't captured whole: it measures off.
    .{ .name = "timestamps step 10 ms late", .ppm = plus42, .stall_at = 12, .stall_seconds = 0.01, .worst_ms = 8 },
    .{ .name = "timestamps step 10 ms early (audio repeated)", .ppm = plus42, .rewind_at = 12 },
    .{ .name = "device delivers past the end", .ppm = plus42, .past_end_seconds = 0.3 },
};

/// Reads a saved aligner back (Aligner.restore's source).
const ByteSource = struct {
    bytes: []const u8,
    pos: usize = 0,
    pub fn read(b: *ByteSource, dest: []u8) error{Invalid}!void {
        @memcpy(dest, b.bytes[b.pos..][0..dest.len]);
        b.pos += dest.len;
    }
};

const Sink = struct {
    gpa: std.mem.Allocator,
    samples: std.ArrayList(f32) = .empty,
    pub fn write(s: *Sink, frames: []const f32) void {
        s.samples.appendSlice(s.gpa, frames) catch @panic("out of memory");
    }
};

test "drift scenarios" {
    const gpa = std.testing.allocator;
    const kernel = try gpa.create(resample.Kernel);
    defer gpa.destroy(kernel);
    kernel.init();

    const n_out = seconds * rate;
    const reference = try gpa.alloc(f32, n_out);
    defer gpa.free(reference);
    for (reference, 0..) |*r, i| r.* = @floatCast(signal(@as(f64, @floatFromInt(i)) / rate));

    for (scenarios) |sc| {
        errdefer std.debug.print("scenario: {s}\n", .{sc.name});
        try run(gpa, kernel, reference, sc);
    }
}

fn run(gpa: std.mem.Allocator, kernel: *const resample.Kernel, reference: []const f32, sc: Scenario) !void {
    var rng: std.Random.DefaultPrng = .init(7);
    const random = rng.random();
    const buffers: resample.Aligner.Buffers = try .init(gpa, 1, rate);
    defer buffers.deinit(gpa);
    var aligner: resample.Aligner = .init(1, rate, buffers, start_qpc);
    var out: Sink = .{ .gpa = gpa };
    defer out.samples.deinit(gpa);
    // Everything the device gave, for the restored aligner's refill.
    var device: std.ArrayList(f32) = .empty;
    defer device.deinit(gpa);
    // The restore check: an aligner restored from a save partway, fed the same packets after.
    var resumed_buffers: ?resample.Aligner.Buffers = null;
    defer if (resumed_buffers) |b| b.deinit(gpa);
    var resumed: resample.Aligner = undefined;
    var resumed_out: Sink = .{ .gpa = gpa };
    defer resumed_out.samples.deinit(gpa);
    var resumed_from: usize = 0;
    var packet_number: u64 = 0;

    // The device: its true time and its position.
    var t: f64 = 0.0037;
    var position: u64 = 0;
    var stalled = false;
    var restarted = false;
    var rewound = false;
    var lost_since_delivered = false;
    var samples: [packet]f32 = undefined;
    while (t + 2.0 * @as(f64, packet) / rate < seconds + sc.past_end_seconds) {
        if (sc.stall_at) |at| if (!stalled and t >= at) {
            stalled = true;
            t += sc.stall_seconds;
        };
        if (sc.rewind_at) |at| if (!rewound and t >= at) {
            rewound = true;
            t -= sc.rewind_seconds;
        };
        if (sc.restart_at) |at| if (!restarted and t >= at) {
            restarted = true;
            position = 0;
        };
        const packet_t = t;
        for (&samples) |*s| {
            s.* = @floatCast(signal(t));
            t += 1 / (rate * (1 + sc.ppm(t) * 1e-6));
        }
        const first = position;
        position += packet;
        const dropped = for (sc.drops) |d| {
            if (packet_t >= d and packet_t < d + 0.05) break true;
        } else false;
        if (dropped) {
            lost_since_delivered = true;
            continue;
        }
        var qpc: u64 = start_qpc + @as(u64, @intFromFloat((packet_t + (random.float(f64) - 0.5) * sc.jitter_ms / 1000) * qpc_per_s));
        var flagged = false;
        if (random.float(f64) < sc.bad_timestamps) {
            qpc = start_qpc + random.intRangeAtMost(u64, 0, seconds * qpc_per_s);
            flagged = sc.flag_bad_timestamps;
        }
        const p: resample.Packet = .{
            .frames = packet,
            .first_frame = first,
            .capture_qpc = qpc,
            .source = .{ .position = device.items.len, .seq = packet_number },
            .timestamp_error = flagged,
            .discontinuity = sc.flag_discontinuity and lost_since_delivered,
        };
        packet_number += 1;
        lost_since_delivered = false;
        try device.appendSlice(gpa, &samples);
        aligner.pushSamples(kernel, p, &samples, &out);
        if (resumed_buffers != null) resumed.pushSamples(kernel, p, &samples, &resumed_out);
        if (resumed_buffers == null and packet_t >= save_at) {
            // Saved as checkpoint.bin saves it, and restored as recovery does: the queued
            // packets' samples given again from where they came from.
            var saved: std.ArrayList(u8) = .empty;
            defer saved.deinit(gpa);
            const state = aligner.save();
            for (aligner.savedSamples()) |part| try saved.appendSlice(gpa, std.mem.sliceAsBytes(part));
            for (aligner.savedEntries()) |part| try saved.appendSlice(gpa, std.mem.sliceAsBytes(part));
            resumed_buffers = try .init(gpa, 1, rate);
            var source: ByteSource = .{ .bytes = saved.items };
            resumed = try .restore(state, resumed_buffers.?, &source);
            try std.testing.expectEqual(saved.items.len, source.pos);
            while (resumed.missing()) |m| {
                const slots = resumed.missingSlots();
                const from = device.items[@intCast(m.source.position)..][0..m.frames];
                @memcpy(slots[0], from[0..slots[0].len]);
                @memcpy(slots[1], from[slots[0].len..]);
                resumed.refilled();
            }
            resumed_from = out.samples.items.len;
        }
    }
    const end_qpc = start_qpc + seconds * qpc_per_s;
    aligner.finish(kernel, end_qpc, &out);
    resumed.finish(kernel, end_qpc, &resumed_out);

    // Every track ends exactly with the recording.
    try std.testing.expectEqual(reference.len, out.samples.items.len);
    // Recovery carries on exactly where it was.
    try std.testing.expectEqualSlices(f32, out.samples.items[resumed_from..], resumed_out.samples.items);
    // In sync throughout, and at the end.
    const sync = syncError(reference, out.samples.items);
    errdefer std.debug.print("sync error: worst {d:.2} ms, last {d:.2} ms over {d} clicks\n", .{ sync.worst_ms, sync.last_ms, sync.clicks });
    try std.testing.expect(sync.clicks > 50);
    try std.testing.expect(@abs(sync.worst_ms) <= sc.worst_ms);
    try std.testing.expect(@abs(sync.last_ms) <= sc.last_ms);
    try std.testing.expectEqual(@as(u32, 0), aligner.stats.resyncs);
}

/// The sync error at each click: the lag (ms, positive = late) that best lines up the track
/// with the reference around it, by cross-correlation within +-10 ms. Clicks where the track
/// is silent (silence put in for lost audio) are skipped: the click genuinely isn't there.
fn syncError(reference: []const f32, track: []const f32) struct { worst_ms: f64, last_ms: f64, clicks: u32 } {
    const window = rate / 10;
    const max_lag = rate * 10 / 1000;
    var worst: f64 = 0;
    var last: f64 = 0;
    var clicks: u32 = 0;
    var beat: usize = 1;
    while (true) : (beat += 1) {
        const center = beat * rate / 2;
        if (center + window + max_lag >= reference.len) break;
        const start = center - window / 4;
        var energy: f64 = 0;
        var zeros: usize = 0;
        var longest_zeros: usize = 0;
        for (track[start..][0..window]) |v| {
            energy += v * v;
            zeros = if (v == 0) zeros + 1 else 0;
            longest_zeros = @max(longest_zeros, zeros);
        }
        if (energy < 1 or longest_zeros > rate / 100) continue;
        var best_lag: i64 = 0;
        var best: f64 = -std.math.inf(f64);
        var scores: [2 * max_lag + 1]f64 = undefined;
        var lag: i64 = -max_lag;
        while (lag <= max_lag) : (lag += 1) {
            var sum: f64 = 0;
            for (0..window) |i| {
                const ti: i64 = @as(i64, @intCast(start + i)) + lag;
                sum += @as(f64, reference[start + i]) * track[@intCast(ti)];
            }
            scores[@intCast(lag + max_lag)] = sum;
            if (sum > best) {
                best = sum;
                best_lag = lag;
            }
        }
        // Sub-sample, by a parabola through the peak and its neighbours.
        var frac: f64 = 0;
        const bi: usize = @intCast(best_lag + max_lag);
        if (bi > 0 and bi < scores.len - 1) {
            const a = scores[bi - 1];
            const b = scores[bi];
            const c = scores[bi + 1];
            const denom = a - 2 * b + c;
            if (denom != 0) frac = 0.5 * (a - c) / denom;
        }
        const ms = (@as(f64, @floatFromInt(best_lag)) + frac) * 1000 / rate;
        if (@abs(ms) > @abs(worst)) worst = ms;
        last = ms;
        clicks += 1;
    }
    return .{ .worst_ms = worst, .last_ms = last, .clicks = clicks };
}

const std = @import("std");
const resample = @import("resample.zig");
