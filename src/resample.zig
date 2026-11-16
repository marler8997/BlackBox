//! Drift correction: resamples a device's audio from its own clock onto the system clock, so
//! tracks from different devices stay in sync however long the recording.
//!
//! Every device has its own crystal, a little off its nominal rate (tens of parts per
//! million is typical: 150 ms an hour at 42 ppm). Each packet of audio comes with its position
//! in the device's stream and when it was captured (QPC), so the device's true rate can be
//! measured against the system clock (Fit) and its samples read back at that rate: for each
//! output frame at nominal rate on the recording's timeline, the device's samples are
//! interpolated at the matching, usually fractional, position (Kernel). Platform-independent.

/// Taps of the interpolation filter: a windowed sinc, accurate to about -90 dB.
pub const taps = 64;
/// Fractional positions the filter is tabulated for; positions in between interpolate.
const phases = 256;
const half_taps = taps / 2;

/// The interpolation filter, tabulated: row p is for fraction p / phases. Sums to 1, so DC
/// passes unchanged.
pub const Kernel = struct {
    rows: [phases + 1][taps]f32,

    /// `cutoff` is in cycles per sample (0.5 is the Nyquist frequency).
    pub fn init(k: *Kernel) void {
        const cutoff = 0.475;
        const beta = 8.6; // Kaiser window: about 90 dB stopband
        const i0_beta = besselI0(beta);
        for (&k.rows, 0..) |*row, p| {
            const frac = @as(f64, @floatFromInt(p)) / phases;
            var sum: f64 = 0;
            var values: [taps]f64 = undefined;
            for (&values, 0..) |*v, j| {
                // Tap j weighs the sample at (floor + j - half_taps + 1), x samples from the
                // position.
                const x = @as(f64, @floatFromInt(@as(i64, @intCast(j)) - half_taps + 1)) - frac;
                const w = x / half_taps;
                const window = if (@abs(w) >= 1) 0 else besselI0(beta * @sqrt(1 - w * w)) / i0_beta;
                v.* = 2 * cutoff * sinc(2 * cutoff * x) * window;
                sum += v.*;
            }
            for (row, values) |*r, v| r.* = @floatCast(v / sum);
        }
    }
};

fn sinc(x: f64) f64 {
    if (x == 0) return 1;
    const px = std.math.pi * x;
    return @sin(px) / px;
}

/// The zeroth-order modified Bessel function of the first kind, for the Kaiser window.
fn besselI0(x: f64) f64 {
    var sum: f64 = 1;
    var term: f64 = 1;
    var k: f64 = 1;
    while (k < 50) : (k += 1) {
        term *= (x / (2 * k)) * (x / (2 * k));
        sum += term;
        if (term < sum * 1e-17) break;
    }
    return sum;
}

/// A device's position against the system clock: a least-squares line through (time,
/// position) points, weighted to the last `memory_seconds`, so it follows a rate that wanders
/// (some devices' do). Its slope is the device's true rate right now.
pub const Fit = extern struct {
    n: u64 = 0,
    /// Times are seconds from this QPC (100ns units).
    origin_qpc: u64 = 0,
    last_x: f64 = 0,
    mean_x: f64 = 0,
    mean_y: f64 = 0,
    var_x: f64 = 0,
    cov_xy: f64 = 0,

    pub const memory_seconds = 10;
    /// Below this much history the slope is too noisy: the nominal rate is used.
    const min_span_seconds = 2;

    pub fn add(f: *Fit, qpc: u64, position: f64) void {
        if (f.n == 0) {
            f.origin_qpc = qpc;
            f.mean_x = 0;
            f.mean_y = position;
            f.n = 1;
            return;
        }
        const x = f.seconds(qpc);
        // Each point counts for the time since the last one, out of memory_seconds; at the
        // start, it's a plain average.
        const dt = @max(x - f.last_x, 0);
        const alpha = @max(@min(dt / memory_seconds, 1), 1 / @as(f64, @floatFromInt(f.n + 1)));
        f.last_x = x;
        f.n += 1;
        const dx = x - f.mean_x;
        const dy = position - f.mean_y;
        f.mean_x += alpha * dx;
        f.mean_y += alpha * dy;
        f.var_x = (1 - alpha) * (f.var_x + alpha * dx * dx);
        f.cov_xy = (1 - alpha) * (f.cov_xy + alpha * dx * dy);
    }

    pub fn seconds(f: *const Fit, qpc: u64) f64 {
        return @as(f64, @floatFromInt(@as(i128, qpc) - @as(i128, f.origin_qpc))) / 10_000_000;
    }

    /// Whether there's enough history for the slope.
    pub fn settled(f: *const Fit) bool {
        return f.n >= 2 and f.last_x >= min_span_seconds and f.var_x > 0;
    }

    /// Frames per second, or `nominal` until there's enough history.
    pub fn rate(f: *const Fit, nominal: f64) f64 {
        if (!f.settled()) return nominal;
        return f.cov_xy / f.var_x;
    }

    /// The device's position at `qpc`, by the line.
    pub fn predict(f: *const Fit, qpc: u64, nominal: f64) f64 {
        return f.mean_y + f.rate(nominal) * (f.seconds(qpc) - f.mean_x);
    }
};

/// Turns one device's audio into output on the recording's timeline at the nominal rate.
/// The device's frames go in by position (pushFrames, pushZeros); output frames come out as
/// far as there are enough device frames past them to interpolate (produce). It only ever
/// corrects the device's rate: offsets (stalls, timestamps that jump) are the Aligner's to
/// snap, before frames get here.
pub const Corrector = struct {
    channels: u8,
    rate: u32,
    /// Device frames, as f32, at positions [ring_start, end): ring[position % ring_frames].
    ring: []f32,
    ring_frames: u64,
    /// Positions before this aren't needed any more (kept: half_taps behind `read`).
    ring_start: u64 = 0,
    /// The device frames' positions so far: [0, end). Positions are the device's, counted from
    /// its first frame, with gaps and stalls filled with zeros, so they're continuous.
    end: u64 = 0,
    /// The device position the next output frame reads: a whole frame and a fraction past
    /// it, kept apart (as speexdsp and PipeWire do) so the fraction's precision doesn't wear
    /// away as positions grow over a long recording. Negative before the device's first frame:
    /// zeros.
    read_index: i64 = 0,
    read_frac: f64 = 0,
    /// Device frames per output frame: the device's rate against the nominal one, plus any
    /// correction under way. Changes only by gliding toward target_ratio, every output frame,
    /// carrying on across packets: never stepped.
    ratio: f64 = 1,
    target_ratio: f64 = 1,
    /// Output frames until target_ratio is next re-aimed (see aim_seconds).
    aim_left: u32 = 0,
    fit: Fit = .{},
    /// Taking back an error past the dead band, see aim.
    correcting: bool = false,
    /// Jumps of read: the line moved further than any drift could.
    resyncs: u32 = 0,

    /// Correction only starts once timing is this far off (0.5 ms: sound travels 17 cm): the
    /// audio is otherwise read at the device's measured rate, untouched by timestamp noise.
    const dead_band_seconds = 0.0005;
    /// And stops once it's back within this.
    const settled_seconds = dead_band_seconds / 4.0;
    /// How often target_ratio is re-aimed at the line. Only where it's heading changes then:
    /// the ratio itself glides there (max_slew_per_second).
    const aim_seconds = 0.01;
    /// An error is taken back over this long, gently.
    const converge_seconds = 5;
    /// An error past this is a jump, not drift: read jumps rather than racing. The Aligner
    /// snaps offsets before they get here, so it means something unforeseen: counted.
    const jump_seconds = 0.25;
    /// The ratio stays within this of 1, so bad timestamps can't swing the pitch: far past
    /// any real crystal's error (tens of ppm).
    const max_correction = 1000e-6;
    /// Taking back an error adds at most this to the ratio: a third of a cent of pitch, far
    /// below hearing (about 5 cents).
    const max_pull = 200e-6;
    /// The ratio changes by at most this much a second, a little every output frame, so the
    /// pitch only ever glides: a sudden step, even a small one, is audible on high tones.
    const max_slew_per_second = 100e-6;

    pub fn ringFramesFor(rate: u32) u64 {
        // Comfortably more than a packet plus the filter's reach.
        return std.math.ceilPowerOfTwo(u64, rate / 4) catch unreachable;
    }

    /// `fit` places the device's positions in time; the next frame produced is at timeline
    /// time `first_output_qpc`.
    pub fn init(channels: u8, rate: u32, ring: []f32, fit: Fit, first_output_qpc: u64) Corrector {
        std.debug.assert(ring.len % channels == 0 and std.math.isPowerOfTwo(ring.len / channels));
        var c: Corrector = .{
            .channels = channels,
            .rate = rate,
            .ring = ring,
            .ring_frames = ring.len / channels,
            .fit = fit,
        };
        c.setRead(c.fit.predict(first_output_qpc, @floatFromInt(rate)));
        return c;
    }

    /// That the frame at `position` was captured at `qpc`.
    pub fn addTimestamp(c: *Corrector, qpc: u64, position: f64) void {
        c.fit.add(qpc, position);
    }

    /// The device's frames at positions [end, end + frames), interleaved.
    pub fn pushFrames(c: *Corrector, samples: []const f32) void {
        const frames = samples.len / c.channels;
        std.debug.assert(c.end + frames - c.ring_start <= c.ring_frames);
        for (0..frames) |i| {
            const at: usize = @intCast(((c.end + i) % c.ring_frames) * c.channels);
            @memcpy(c.ring[at..][0..c.channels], samples[i * c.channels ..][0..c.channels]);
        }
        c.end += frames;
    }

    /// Room for this many more device frames before produce must take some.
    pub fn room(c: *const Corrector) u64 {
        return c.ring_frames - (c.end - c.ring_start);
    }

    pub fn pushZeros(c: *Corrector, frames: u64) void {
        std.debug.assert(c.end + frames - c.ring_start <= c.ring_frames);
        for (0..frames) |i| {
            const at: usize = @intCast(((c.end + i) % c.ring_frames) * c.channels);
            @memset(c.ring[at..][0..c.channels], 0);
        }
        c.end += frames;
    }

    /// Writes output frames to `out` (interleaved) while the device's frames reach far enough
    /// past them, or, with `flush`, until all of them are out (reading zeros past the device's
    /// last frame for the filter's tail). `output_qpc` is the timeline time of the first frame
    /// written. Returns the frames written.
    pub fn produce(c: *Corrector, k: *const Kernel, out: []f32, output_qpc: u64, flush: bool) usize {
        const nominal: f64 = @floatFromInt(c.rate);
        const frames = out.len / c.channels;
        var written: usize = 0;
        const slew = max_slew_per_second / nominal;
        while (written < frames) {
            // Not flushing: only as far as the device's frames reach past read. Flushing: until
            // read is past them and the filter's reach, no further (the next segment, or the
            // recording's end, carries on from exactly there).
            if (!flush and c.read_index + half_taps >= @as(i64, @intCast(c.end))) break;
            if (flush and c.read_index - half_taps >= @as(i64, @intCast(c.end))) break;
            if (c.aim_left == 0) c.aim(output_qpc + @as(u64, written) * 10_000_000 / c.rate, nominal);
            c.aim_left -= 1;
            c.ratio = std.math.clamp(c.target_ratio, c.ratio - slew, c.ratio + slew);
            c.interpolate(k, out[written * c.channels ..][0..c.channels]);
            c.read_frac += c.ratio;
            const whole = @floor(c.read_frac);
            c.read_index += @intFromFloat(whole);
            c.read_frac -= whole;
            written += 1;
        }
        // Frames more than half_taps behind read won't be read again.
        const keep_from = c.read_index - half_taps;
        if (keep_from > 0) c.ring_start = @min(@as(u64, @intCast(keep_from)), c.end);
        return written;
    }

    /// Re-aims target_ratio: the device's rate, plus, past the dead band, a pull toward where
    /// the line says read should be, spread over converge_seconds. The pull only ever takes
    /// back what following a changing rate leaves behind (the line moves as the rate wanders).
    fn aim(c: *Corrector, qpc: u64, nominal: f64) void {
        const target = c.fit.predict(qpc, nominal);
        const err = (target - @as(f64, @floatFromInt(c.read_index))) - c.read_frac;
        // Mostly just the device's own rate: the audio as it was, only re-timed.
        var ratio = c.fit.rate(nominal) / nominal;
        if (@abs(err) > jump_seconds * nominal) {
            c.setRead(target);
            c.resyncs += 1;
            c.correcting = false;
            // A jump is already a discontinuity: no point gliding to the rate.
            c.ratio = std.math.clamp(ratio, 1 - max_correction, 1 + max_correction);
        } else {
            if (@abs(err) > dead_band_seconds * nominal) c.correcting = true;
            if (@abs(err) < settled_seconds * nominal) c.correcting = false;
            if (c.correcting) ratio += std.math.clamp(err / (converge_seconds * nominal), -max_pull, max_pull);
        }
        c.target_ratio = std.math.clamp(ratio, 1 - max_correction, 1 + max_correction);
        c.aim_left = @max(1, @as(u32, @intFromFloat(aim_seconds * nominal)));
    }

    /// Everything but the ring's frames (liveParts), to carry on exactly where it is.
    pub const State = extern struct {
        ring_start: u64,
        end: u64,
        read_index: i64,
        read_frac: f64,
        ratio: f64,
        target_ratio: f64,
        fit: Fit,
        aim_left: u32,
        resyncs: u32,
        correcting: bool,
        reserved: [7]u8 = @splat(0),
    };

    pub fn save(c: *const Corrector) State {
        return .{
            .ring_start = c.ring_start,
            .end = c.end,
            .read_index = c.read_index,
            .read_frac = c.read_frac,
            .ratio = c.ratio,
            .target_ratio = c.target_ratio,
            .fit = c.fit,
            .aim_left = c.aim_left,
            .resyncs = c.resyncs,
            .correcting = c.correcting,
        };
    }

    /// The frames still needed, positions [ring_start, end), in two parts (the ring wraps).
    pub fn liveParts(c: *const Corrector) [2][]f32 {
        const ch = c.channels;
        const n = c.end - c.ring_start;
        const start: usize = @intCast(c.ring_start % c.ring_frames);
        const first: usize = @intCast(@min(n, c.ring_frames - start));
        return .{ c.ring[start * ch ..][0 .. first * ch], c.ring[0..@intCast((n - first) * ch)] };
    }

    /// From save, then liveParts' frames read from `source` (see Aligner.restore).
    fn restore(channels: u8, rate: u32, ring: []f32, s: State, source: anytype) error{Invalid}!Corrector {
        const c: Corrector = .{
            .channels = channels,
            .rate = rate,
            .ring = ring,
            .ring_frames = ring.len / channels,
            .ring_start = s.ring_start,
            .end = s.end,
            .read_index = s.read_index,
            .read_frac = s.read_frac,
            .ratio = s.ratio,
            .target_ratio = s.target_ratio,
            .aim_left = s.aim_left,
            .fit = s.fit,
            .correcting = s.correcting,
            .resyncs = s.resyncs,
        };
        if (s.end < s.ring_start or s.end - s.ring_start > c.ring_frames) return error.Invalid;
        for (c.liveParts()) |part| try source.read(std.mem.sliceAsBytes(part));
        return c;
    }

    fn setRead(c: *Corrector, position: f64) void {
        const whole = @floor(position);
        c.read_index = @intFromFloat(whole);
        c.read_frac = position - whole;
    }

    fn interpolate(c: *const Corrector, k: *const Kernel, out: []f32) void {
        const phase_f = c.read_frac * phases;
        const phase: usize = @min(@as(usize, @intFromFloat(phase_f)), phases - 1);
        const t = phase_f - @as(f64, @floatFromInt(phase));
        const row0 = &k.rows[phase];
        const row1 = &k.rows[phase + 1];
        // The taps that land on what the device gave (outside it: zeros).
        const first = c.read_index - half_taps + 1;
        const lo: usize = @intCast(std.math.clamp(@as(i64, @intCast(c.ring_start)) - first, 0, taps));
        const hi: usize = @intCast(std.math.clamp(@as(i64, @intCast(c.end)) - first, 0, taps));
        var weights: [taps]f64 = undefined;
        for (weights[lo..hi], row0[lo..hi], row1[lo..hi]) |*w, a, b| w.* = a + (b - a) * t;
        // A channel at a time, summed in f64, as speexdsp does at its high qualities.
        for (out, 0..) |*o, ch| {
            var sum: f64 = 0;
            for (lo..hi) |j| {
                const pos: u64 = @intCast(first + @as(i64, @intCast(j)));
                sum += weights[j] * c.ring[@as(usize, @intCast(pos % c.ring_frames)) * c.channels + ch];
            }
            o.* = @floatCast(sum);
        }
    }
};

/// A packet of a device's audio, as the journal records it (journal.Record).
pub const Packet = extern struct {
    /// The device's position (in frames) of its first frame.
    first_frame: u64,
    /// When its first frame was captured, QPC in 100ns units.
    capture_qpc: u64,
    /// Where it came from, for the caller: the aligner only keeps it (see head).
    source: Source = .{},
    frames: u32,
    /// Digital silence: no samples given.
    silent: bool = false,
    /// Windows said capture_qpc is wrong.
    timestamp_error: bool = false,
    /// Windows said audio was lost before it.
    discontinuity: bool = false,
    reserved: u8 = 0,

    pub const Source = extern struct {
        position: u64 = 0,
        seq: u64 = 0,
        index: u32 = 0,
        /// Frames into what it came from, when that was split (see maxPacketFrames).
        offset: u32 = 0,
    };
};

/// Puts one device's audio on the recording's timeline: output at the nominal rate from the
/// recording's start, in step with the system clock, whatever the device's own clock does.
/// Output goes to `sink`, which has `fn write(sink, frames: []const f32) void` (interleaved).
///
/// Two kinds of error, handled two ways (as FFmpeg's async resampling, GStreamer's audio
/// sinks and PipeWire all split them):
///   - The device's clock runs at its own rate: the Corrector resamples, following the rate.
///   - The audio is at the wrong place: silence where the device gave nothing (before its
///     first packet, gaps where its position skipped, stalls where it stopped counting while
///     time went on, after its last), frames dropped where its timestamps say it gave more
///     than time allowed. Snapped at once, at the packet where it happened, faded so it
///     doesn't click: never pulled back slowly by bending the pitch.
///
/// Packets wait in a look-ahead queue (lookahead_seconds) before they're used, so every
/// decision sees what came after: the start is placed by the timestamps of its first packets
/// together, not the first alone, and a packet off the line is only a step if the packets
/// after it agree; one that's off alone just has a wrong timestamp, which is ignored.
pub const Aligner = struct {
    channels: u8,
    rate: u32,
    /// When the timeline's first frame is, QPC.
    start_qpc: u64,
    buffers: Buffers,
    /// The device's audio since it (re)started, or null.
    corrector: ?Corrector = null,
    /// Output frames written: the position on the timeline.
    written: u64 = 0,

    /// The look-ahead queue: buffers.entries[(queue_head + i) % len] for i < queue_len.
    queue_head: usize = 0,
    queue_len: usize = 0,
    /// Frames ever queued, and the first still held: frame n is buffers.lookahead[n % frames].
    queued_end: u64 = 0,
    queued_start: u64 = 0,
    /// The device position the next packet queued should have, or null to start a segment.
    queue_next_frame: ?u64 = null,
    /// After restore: the last this many queued packets' samples aren't back yet (missing).
    unfilled: usize = 0,
    /// Frames reserve made room for, for the push that follows.
    reserved: ?u32 = null,
    /// Finishing: the timeline frame nothing is written at or past (see finish).
    stop_at: ?u64 = null,

    /// The segment being corrected: its first device frame, and the device frame expected
    /// next. Positions in the corrector are device frame - origin + shift, where shift counts
    /// frames inserted for stalls less those dropped.
    origin: u64 = 0,
    next_frame: u64 = 0,
    shift: i64 = 0,

    /// Splicing: the last frames given are held back (buffers.tail), so a snap can fade them
    /// out or crossfade from them. A drop crossfades from buffers.xfade (xfade_pos of
    /// xfade_len done) into the audio after skip_left frames are skipped.
    tail_len: usize = 0,
    fade_in_left: usize = 0,
    skip_left: u64 = 0,
    xfade_len: usize = 0,
    xfade_pos: usize = 0,

    stats: Stats = .{},

    pub const Stats = extern struct {
        gaps: u32 = 0,
        gap_frames: u64 = 0,
        /// Snaps: silence inserted where the device fell behind time, frames dropped where it
        /// got ahead.
        stalls: u32 = 0,
        stall_frames: u64 = 0,
        drops: u32 = 0,
        drop_frames: u64 = 0,
        restarts: u32 = 0,
        timestamp_errors: u32 = 0,
        discontinuities: u32 = 0,
        /// Timestamps off the line on their own: ignored.
        outliers: u32 = 0,
        /// Jumps of the corrector's read (shouldn't happen: snaps come first).
        resyncs: u32 = 0,
        /// The device's clock over the whole track, for reporting.
        drift: DriftFit = .{},
    };

    pub const Entry = extern struct {
        packet: Packet,
        /// Its first frame's place in the look-ahead (see queued_end).
        at: u64,
        /// Frames to insert before it (positive) or drop from it on (negative).
        snap: i64 = 0,
        /// The device (re)started at this packet.
        segment_start: bool,
        /// Its timestamp placed the segment's start (already in the fit).
        fitted: bool = false,
        decided: bool = false,
        reserved: [5]u8 = @splat(0),
    };

    /// Everything but the buffers' contents (see savedSamples, savedEntries), to carry on
    /// exactly where it is, after a crash.
    pub const State = extern struct {
        start_qpc: u64,
        written: u64,
        queue_len: u64,
        queued_end: u64,
        queued_start: u64,
        queue_next_frame: u64,
        origin: u64,
        next_frame: u64,
        shift: i64,
        tail_len: u64,
        fade_in_left: u64,
        skip_left: u64,
        xfade_len: u64,
        xfade_pos: u64,
        corrector: Corrector.State,
        stats: Stats,
        rate: u32,
        channels: u8,
        has_queue_next_frame: bool,
        has_corrector: bool,
        reserved: u8 = 0,
    };

    /// Packets are used this long after they come, so decisions see what came after.
    const lookahead_seconds = 0.6;
    /// A packet whose timestamp is this far off the line (2 ms: sound travels 70 cm) was a
    /// step, if the packets after it agree; smaller offsets are jitter, left to the fit.
    const step_seconds = 0.002;
    /// A timestamp this far off the line that isn't a step is wrong, and ignored.
    const outlier_seconds = 0.005;
    /// The packets after one (within this long) that are looked at, how many there must be,
    /// and what share must agree (within step_seconds / 2) on where the audio now is.
    const confirm_seconds = 0.5;
    const min_confirm = 3;
    const agree_tenths = 6;
    /// Snaps fade over this long (raised cosine), so they don't click.
    const fade_seconds = 0.0025;
    const max_entries = 1024;

    /// Everything an Aligner needs, for a track: one allocation, its size set by the
    /// device's rate and channels.
    pub const Buffers = struct {
        memory: []align(@alignOf(Entry)) u8,
        entries: []Entry,
        ring: []f32,
        lookahead: []f32,
        tail: []f32,
        xfade: []f32,

        pub fn init(gpa: std.mem.Allocator, channels: u8, rate: u32) error{OutOfMemory}!Buffers {
            const ring_len = Corrector.ringFramesFor(rate) * channels;
            const lookahead_len = lookaheadFrames(rate) * channels;
            const fade_len = fadeFrames(rate) * channels;
            const entries_bytes = max_entries * @sizeOf(Entry);
            const memory = try gpa.alignedAlloc(u8, .of(Entry), entries_bytes + (ring_len + lookahead_len + 2 * fade_len) * @sizeOf(f32));
            const floats: []f32 = @ptrCast(@alignCast(memory[entries_bytes..]));
            return .{
                .memory = memory,
                .entries = @ptrCast(memory[0..entries_bytes]),
                .ring = floats[0..ring_len],
                .lookahead = floats[ring_len..][0..lookahead_len],
                .tail = floats[ring_len + lookahead_len ..][0..fade_len],
                .xfade = floats[ring_len + lookahead_len + fade_len ..][0..fade_len],
            };
        }

        pub fn deinit(b: Buffers, gpa: std.mem.Allocator) void {
            gpa.free(b.memory);
        }
    };

    fn lookaheadFrames(rate: u32) u64 {
        return std.math.ceilPowerOfTwo(u64, rate) catch unreachable;
    }
    fn holdFrames(rate: u32) u64 {
        return @intFromFloat(lookahead_seconds * @as(f64, @floatFromInt(rate)));
    }
    fn fadeFrames(rate: u32) u64 {
        return @max(1, @as(u64, @intFromFloat(fade_seconds * @as(f64, @floatFromInt(rate)))));
    }

    /// The largest packet push takes (at least 0.4 s: devices give about 10 ms at a time).
    /// Callers split bigger ones (Packet.Source.offset says where a piece starts).
    pub fn maxPacketFrames(rate: u32) u32 {
        return @intCast(lookaheadFrames(rate) - holdFrames(rate));
    }

    pub fn init(channels: u8, rate: u32, buffers: Buffers, start_qpc: u64) Aligner {
        std.debug.assert(channels > 0);
        return .{ .channels = channels, .rate = rate, .buffers = buffers, .start_qpc = start_qpc };
    }

    /// Room in the look-ahead for the device's next packet, of `frames`: the caller writes its
    /// samples there (interleaved, in two parts as the ring wraps), then pushes it. Silent
    /// packets needn't be written: push zeros them.
    pub fn reserve(a: *Aligner, k: *const Kernel, frames: u32, sink: anytype) [2][]f32 {
        if (frames > maxPacketFrames(a.rate)) std.debug.panic("a {d}-frame packet is bigger than the aligner takes ({d}): split it", .{ frames, maxPacketFrames(a.rate) });
        a.checkFilled();
        const lf = a.buffers.lookahead.len / a.channels;
        while (a.queue_len == a.buffers.entries.len or lf - (a.queued_end - a.queued_start) < frames) a.processHead(k, sink);
        a.reserved = frames;
        return a.slots(a.queued_end, frames);
    }

    /// The device's next packet, its samples written where reserve said.
    pub fn push(a: *Aligner, k: *const Kernel, p: Packet, sink: anytype) void {
        if (a.reserved != p.frames) std.debug.panic("aligner: pushing {d} frames, {?d} reserved", .{ p.frames, a.reserved });
        a.reserved = null;
        if (p.discontinuity) a.stats.discontinuities += 1;
        if (p.timestamp_error) a.stats.timestamp_errors += 1;
        if (p.silent) for (a.slots(a.queued_end, p.frames)) |s| @memset(s, 0);

        // A new segment: the first packet, or the device restarted (its position went back).
        const segment_start = if (a.queue_next_frame) |n| p.first_frame < n else true;
        if (segment_start and a.queue_next_frame != null) a.stats.restarts += 1;
        a.queue_next_frame = p.first_frame + p.frames;

        a.entry(a.queue_len).* = .{ .packet = p, .at = a.queued_end, .segment_start = segment_start };
        a.queue_len += 1;
        a.queued_end += p.frames;
        while (a.queued_end - a.queued_start > holdFrames(a.rate)) a.processHead(k, sink);
    }

    /// reserve, copy, push: for samples already in float.
    pub fn pushSamples(a: *Aligner, k: *const Kernel, p: Packet, samples: ?[]const f32, sink: anytype) void {
        const parts = a.reserve(k, p.frames, sink);
        if (samples) |s| {
            if (s.len != @as(usize, p.frames) * a.channels) std.debug.panic("packet of {d} frames came with {d} samples", .{ p.frames, s.len });
            @memcpy(parts[0], s[0..parts[0].len]);
            @memcpy(parts[1], s[parts[0].len..]);
        }
        a.push(k, p, sink);
    }

    /// The look-ahead's frames [at, at + frames), in two parts as the ring wraps.
    fn slots(a: *Aligner, at: u64, frames: u32) [2][]f32 {
        const ch = a.channels;
        const lf = a.buffers.lookahead.len / ch;
        const start: usize = @intCast(at % lf);
        const first_n = @min(frames, lf - start);
        return .{ a.buffers.lookahead[start * ch ..][0 .. first_n * ch], a.buffers.lookahead[0 .. (frames - first_n) * ch] };
    }

    /// The oldest packet still queued (its source is where to find it again), or null.
    pub fn head(a: *Aligner) ?Packet {
        return if (a.queue_len > 0) a.entry(0).packet else null;
    }

    /// After restore: the next queued packet whose samples are missing, or null once all
    /// are back. The caller writes them in missingSlots (zeros if it's silent), then calls
    /// refilled.
    pub fn missing(a: *Aligner) ?Packet {
        return if (a.unfilled > 0) a.entry(a.queue_len - a.unfilled).packet else null;
    }

    pub fn missingSlots(a: *Aligner) [2][]f32 {
        const e = a.entry(a.queue_len - a.unfilled);
        return a.slots(e.at, e.packet.frames);
    }

    pub fn refilled(a: *Aligner) void {
        a.unfilled -= 1;
    }

    fn checkFilled(a: *const Aligner) void {
        if (a.unfilled > 0) std.debug.panic("aligner used with {d} restored packets' samples not refilled", .{a.unfilled});
    }

    pub fn save(a: *const Aligner) State {
        return .{
            .start_qpc = a.start_qpc,
            .written = a.written,
            .queue_len = a.queue_len,
            .queued_end = a.queued_end,
            .queued_start = a.queued_start,
            .queue_next_frame = a.queue_next_frame orelse 0,
            .origin = a.origin,
            .next_frame = a.next_frame,
            .shift = a.shift,
            .tail_len = a.tail_len,
            .fade_in_left = a.fade_in_left,
            .skip_left = a.skip_left,
            .xfade_len = a.xfade_len,
            .xfade_pos = a.xfade_pos,
            .corrector = if (a.corrector) |*c| c.save() else std.mem.zeroes(Corrector.State),
            .stats = a.stats,
            .rate = a.rate,
            .channels = a.channels,
            .has_queue_next_frame = a.queue_next_frame != null,
            .has_corrector = a.corrector != null,
        };
    }

    /// The samples save needs with State, in order (State.sampleCount in all): the
    /// corrector's, then the held tail, then the crossfade's.
    pub fn savedSamples(a: *const Aligner) [4][]const f32 {
        const ch = a.channels;
        const ring: [2][]f32 = if (a.corrector) |*c| c.liveParts() else .{ &.{}, &.{} };
        return .{ ring[0], ring[1], a.buffers.tail[0 .. a.tail_len * ch], a.buffers.xfade[0 .. a.xfade_len * ch] };
    }

    /// The queued packets, in order (State.queue_len of them). Their samples aren't saved:
    /// the caller gives them again after restore (missing, refill).
    pub fn savedEntries(a: *const Aligner) [2][]const Entry {
        const len = a.buffers.entries.len;
        const first = @min(a.queue_len, len - a.queue_head);
        return .{ a.buffers.entries[a.queue_head..][0..first], a.buffers.entries[0 .. a.queue_len - first] };
    }

    /// From save, then savedSamples' and savedEntries' bytes, in order, read straight into
    /// `buffers` (for the same channels and rate) from `source`, which has
    /// `fn read(source, dest: []u8) error{Invalid}!void`. error.Invalid: the state doesn't fit
    /// the buffers (it's damaged), or the source said so. Only the sizes are checked, so
    /// nothing reads past the buffers: whether the rest is sound is the caller's to know (a
    /// checksum, say) before using it.
    pub fn restore(s: State, buffers: Buffers, source: anytype) error{Invalid}!Aligner {
        const ch = s.channels;
        if (ch == 0 or s.queue_len > buffers.entries.len or s.tail_len * ch > buffers.tail.len or s.xfade_len * ch > buffers.xfade.len or
            s.fade_in_left * ch > buffers.tail.len or s.xfade_pos > s.xfade_len or s.queued_end < s.queued_start or
            s.queued_end - s.queued_start > buffers.lookahead.len / ch)
            return error.Invalid;
        const entries = buffers.entries[0..@intCast(s.queue_len)];
        var a: Aligner = .{
            .channels = ch,
            .rate = s.rate,
            .start_qpc = s.start_qpc,
            .buffers = buffers,
            .written = s.written,
            .queue_len = entries.len,
            .queued_end = s.queued_end,
            .queued_start = s.queued_start,
            .queue_next_frame = if (s.has_queue_next_frame) s.queue_next_frame else null,
            .unfilled = entries.len,
            .origin = s.origin,
            .next_frame = s.next_frame,
            .shift = s.shift,
            .tail_len = @intCast(s.tail_len),
            .fade_in_left = @intCast(s.fade_in_left),
            .skip_left = s.skip_left,
            .xfade_len = @intCast(s.xfade_len),
            .xfade_pos = @intCast(s.xfade_pos),
            .stats = s.stats,
        };
        if (s.has_corrector) a.corrector = try .restore(ch, s.rate, buffers.ring, s.corrector, source);
        try source.read(std.mem.sliceAsBytes(buffers.tail[0 .. a.tail_len * ch]));
        try source.read(std.mem.sliceAsBytes(buffers.xfade[0 .. a.xfade_len * ch]));
        try source.read(std.mem.sliceAsBytes(entries));
        return a;
    }

    /// The device is gone (for now): what it gave is all used and flushed out; until it's
    /// back, nothing more is written (finish or its return fills the time with silence).
    pub fn endSegment(a: *Aligner, k: *const Kernel, sink: anytype) void {
        a.checkFilled();
        while (a.queue_len > 0) a.processHead(k, sink);
        if (a.corrector != null) a.closeSegment(k, null, sink);
        a.queue_next_frame = null;
    }

    /// The recording ended at `end_qpc`: everything out, then silence to then. What the
    /// device gave past the end is dropped: the recording stopped there.
    pub fn finish(a: *Aligner, k: *const Kernel, end_qpc: u64, sink: anytype) void {
        const end = a.timelineFrame(end_qpc);
        a.checkFilled();
        // Nothing goes out past the end, however much the queue still holds: packets captured
        // after the recording stopped (devices deliver until they're detached).
        a.stop_at = end;
        while (a.queue_len > 0) a.processHead(k, sink);
        if (a.corrector != null) a.closeSegment(k, end, sink);
        var zeros: [1024]f32 = @splat(0);
        const per = zeros.len / a.channels;
        while (a.written < end) {
            const n = @min(per, end - a.written);
            sink.write(zeros[0 .. n * a.channels]);
            a.written += n;
        }
    }

    fn entry(a: *Aligner, i: usize) *Entry {
        return &a.buffers.entries[(a.queue_head + i) % a.buffers.entries.len];
    }

    /// Uses the oldest queued packet.
    fn processHead(a: *Aligner, k: *const Kernel, sink: anytype) void {
        const e = a.entry(0);
        if (e.segment_start or a.corrector == null) {
            if (a.corrector != null) a.closeSegment(k, null, sink);
            a.startSegment();
            e.segment_start = false;
        }
        a.decide();
        if (e.packet.first_frame > a.next_frame) {
            // The device's position skipped: audio lost, silence in its place.
            const lost = e.packet.first_frame - a.next_frame;
            a.stats.gaps += 1;
            a.stats.gap_frames += lost;
            a.insertSilence(k, lost, sink);
        }
        if (e.snap > 0) {
            a.stats.stalls += 1;
            a.stats.stall_frames += @intCast(e.snap);
            a.insertSilence(k, @intCast(e.snap), sink);
        } else if (e.snap < 0) {
            a.stats.drops += 1;
            a.stats.drop_frames += @intCast(-e.snap);
            a.drop(k, @intCast(-e.snap), sink);
        }
        a.shift += e.snap;
        if (!e.packet.timestamp_error) {
            const pos = a.position(e.packet.first_frame);
            if (!e.fitted) a.corrector.?.addTimestamp(e.packet.capture_qpc, pos);
            a.stats.drift.add(e.packet.capture_qpc, @intCast(@max(0, @as(i64, @intFromFloat(pos)) + @as(i64, @intCast(a.stats.drift.offset)))));
        }
        const ch = a.channels;
        const lf = a.buffers.lookahead.len / ch;
        const start: usize = @intCast(e.at % lf);
        const first_n = @min(e.packet.frames, lf - start);
        a.feed(k, a.buffers.lookahead[start * ch ..][0 .. first_n * ch], sink);
        a.feed(k, a.buffers.lookahead[0 .. (e.packet.frames - first_n) * ch], sink);
        a.next_frame = e.packet.first_frame + e.packet.frames;
        a.queued_start = e.at + e.packet.frames;
        a.queue_head = (a.queue_head + 1) % a.buffers.entries.len;
        a.queue_len -= 1;
        a.drain(k, false, null, sink);
    }

    /// Places a new segment (its first packet is the head) by the timestamps of its queued
    /// packets together: those within step_seconds of their median make the line; any others
    /// are decided as they come (steps or wrong).
    fn startSegment(a: *Aligner) void {
        const first = a.entry(0).packet;
        a.origin = first.first_frame;
        a.next_frame = first.first_frame;
        a.shift = 0;
        a.tail_len = 0;
        a.fade_in_left = 0;
        a.skip_left = 0;
        a.xfade_len = 0;
        a.xfade_pos = 0;

        var offsets: [max_entries]f64 = undefined;
        var n: usize = 0;
        var i: usize = 0;
        while (i < a.queue_len) : (i += 1) {
            const e = a.entry(i);
            if (i > 0 and e.segment_start) break;
            if (e.packet.timestamp_error) continue;
            offsets[n] = a.offsetSeconds(e.packet);
            n += 1;
        }
        var fit: Fit = .{};
        if (n > 0) {
            var sorted: [max_entries]f64 = undefined;
            @memcpy(sorted[0..n], offsets[0..n]);
            std.mem.sort(f64, sorted[0..n], {}, std.sort.asc(f64));
            const median = sorted[n / 2];
            i = 0;
            var j: usize = 0;
            while (i < a.queue_len) : (i += 1) {
                const e = a.entry(i);
                if (i > 0 and e.segment_start) break;
                if (e.packet.timestamp_error) continue;
                if (@abs(offsets[j] - median) < step_seconds) {
                    fit.add(e.packet.capture_qpc, a.position(e.packet.first_frame));
                    e.fitted = true;
                    e.decided = true;
                }
                j += 1;
            }
        } else {
            // No good time at all: where the timeline is now.
            fit.add(a.outputQpc(a.written), 0);
        }
        a.corrector = .init(a.channels, a.rate, a.buffers.ring, fit, a.outputQpc(a.written));
    }

    /// Whether the head packet's timestamp is good, a step (snap), or wrong (ignored).
    fn decide(a: *Aligner) void {
        const e = a.entry(0);
        if (e.decided) return;
        e.decided = true;
        if (e.packet.timestamp_error) return;
        const step = step_seconds * @as(f64, @floatFromInt(a.rate));
        const late = a.lateness(e.packet);
        if (@abs(late) < step) return;
        var lates: [max_entries]f64 = undefined;
        lates[0] = late;
        var n: usize = 1;
        const confirm_frames: u64 = @intFromFloat(confirm_seconds * @as(f64, @floatFromInt(a.rate)));
        var i: usize = 1;
        while (i < a.queue_len) : (i += 1) {
            const f = a.entry(i);
            if (f.segment_start or f.at - e.at > confirm_frames) break;
            if (f.packet.timestamp_error) continue;
            lates[n] = a.lateness(f.packet);
            n += 1;
        }
        if (n > min_confirm) {
            var sorted: [max_entries]f64 = undefined;
            @memcpy(sorted[0..n], lates[0..n]);
            std.mem.sort(f64, sorted[0..n], {}, std.sort.asc(f64));
            const median = sorted[n / 2];
            var agree: usize = 0;
            for (lates[0..n]) |l| {
                if (@abs(l - median) <= step / 2) agree += 1;
            }
            if (@abs(median) >= step and @abs(late - median) <= step / 2 and agree * 10 >= n * agree_tenths) {
                var snap: i64 = @intFromFloat(@round(median));
                // Can't drop more than the segment has had.
                snap = @max(snap, -@as(i64, @intFromFloat(a.position(e.packet.first_frame))));
                e.snap = snap;
                return;
            }
        }
        // Not a step. Off by less than outlier_seconds: jitter, kept (leaving out everything
        // past step_seconds would bias the line toward wherever it already is). Past that:
        // wrong, ignored.
        if (@abs(late) < outlier_seconds * @as(f64, @floatFromInt(a.rate))) return;
        e.packet.timestamp_error = true;
        a.stats.outliers += 1;
    }

    /// Frames the packet is behind where the line says its time puts it (negative: ahead).
    fn lateness(a: *Aligner, p: Packet) f64 {
        return a.corrector.?.fit.predict(p.capture_qpc, @floatFromInt(a.rate)) - a.position(p.first_frame);
    }

    /// The corrector position of a device frame of this segment (snaps so far applied).
    fn position(a: *const Aligner, device_frame: u64) f64 {
        return @floatFromInt(@as(i64, @intCast(device_frame - a.origin)) + a.shift);
    }

    /// When the packet was captured against where its position (at the nominal rate) says,
    /// in seconds from the timeline's start.
    fn offsetSeconds(a: *const Aligner, p: Packet) f64 {
        const t = @as(f64, @floatFromInt(@as(i128, p.capture_qpc) - @as(i128, a.start_qpc))) / 10_000_000;
        return t - a.position(p.first_frame) / @as(f64, @floatFromInt(a.rate));
    }

    fn closeSegment(a: *Aligner, k: *const Kernel, until: ?u64, sink: anytype) void {
        a.finishXfade(k, sink);
        a.skip_left = 0;
        a.fade_in_left = 0;
        a.toCorrector(k, a.buffers.tail[0 .. a.tail_len * a.channels], sink);
        a.tail_len = 0;
        a.drain(k, true, until, sink);
        const c = &a.corrector.?;
        a.stats.resyncs += c.resyncs;
        // A restarted device's positions start over: the drift line carries on from here.
        a.stats.drift.offset = @intCast(@as(i64, @intCast(a.stats.drift.offset)) + @as(i64, @intCast(a.next_frame - a.origin)) + a.shift);
        a.corrector = null;
    }

    /// The segment's audio, after any skip, crossfade or fade-in under way.
    fn feed(a: *Aligner, k: *const Kernel, input: []const f32, sink: anytype) void {
        const ch = a.channels;
        const fade = a.buffers.tail.len / ch;
        var in = input;
        var work: [1024]f32 = undefined;
        const per = work.len / ch;
        while (in.len > 0) {
            if (a.skip_left > 0) {
                const n: usize = @intCast(@min(a.skip_left, in.len / ch));
                a.skip_left -= n;
                in = in[n * ch ..];
                continue;
            }
            const n = @min(per, in.len / ch);
            const w = work[0 .. n * ch];
            @memcpy(w, in[0 .. n * ch]);
            for (0..n) |i| {
                const frame = w[i * ch ..][0..ch];
                if (a.xfade_pos < a.xfade_len) {
                    const g = fadeOut(a.xfade_pos, a.xfade_len);
                    for (frame, a.buffers.xfade[a.xfade_pos * ch ..][0..ch]) |*o, s| o.* = s * g + o.* * (1 - g);
                    a.xfade_pos += 1;
                } else if (a.fade_in_left > 0) {
                    const g = 1 - fadeOut(fade - a.fade_in_left, fade);
                    for (frame) |*o| o.* *= g;
                    a.fade_in_left -= 1;
                }
            }
            a.hold(k, w, sink);
            in = in[n * ch ..];
        }
    }

    /// Gives frames on, holding back the last ones (buffers.tail) for a snap to fade.
    fn hold(a: *Aligner, k: *const Kernel, frames: []const f32, sink: anytype) void {
        const ch = a.channels;
        const tail = a.buffers.tail;
        const cap = tail.len / ch;
        const n = frames.len / ch;
        if (n >= cap) {
            a.toCorrector(k, tail[0 .. a.tail_len * ch], sink);
            a.toCorrector(k, frames[0 .. (n - cap) * ch], sink);
            @memcpy(tail, frames[(n - cap) * ch ..]);
            a.tail_len = cap;
            return;
        }
        if (a.tail_len + n > cap) {
            const out = a.tail_len + n - cap;
            a.toCorrector(k, tail[0 .. out * ch], sink);
            std.mem.copyForwards(f32, tail[0 .. (a.tail_len - out) * ch], tail[out * ch .. a.tail_len * ch]);
            a.tail_len -= out;
        }
        @memcpy(tail[a.tail_len * ch ..][0 .. n * ch], frames);
        a.tail_len += n;
    }

    /// Silence before what comes next: what came before fades out, what comes next fades in.
    fn insertSilence(a: *Aligner, k: *const Kernel, frames: u64, sink: anytype) void {
        a.finishXfade(k, sink);
        var n = frames;
        // A drop under way and silence cancel out.
        const cancel = @min(n, a.skip_left);
        a.skip_left -= cancel;
        n -= cancel;
        if (n == 0) return;
        const ch = a.channels;
        const tail = a.buffers.tail;
        for (0..a.tail_len) |i| {
            const g = fadeOut(i, a.tail_len);
            for (tail[i * ch ..][0..ch]) |*o| o.* *= g;
        }
        a.toCorrector(k, tail[0 .. a.tail_len * ch], sink);
        a.tail_len = 0;
        a.pushZeros(k, n, sink);
        a.fade_in_left = tail.len / ch;
    }

    /// Drops the next `frames` frames of the audio, crossfading from what came before into
    /// what comes after.
    fn drop(a: *Aligner, k: *const Kernel, frames: u64, sink: anytype) void {
        a.finishXfade(k, sink);
        const ch = a.channels;
        const fade = a.buffers.tail.len / ch;
        if (a.skip_left > 0) {
            a.skip_left += frames;
            a.fade_in_left = fade;
            return;
        }
        // The held frames' places are taken by the crossfade: x of them fade out while the
        // frames after the dropped ones fade in.
        const x: usize = @intCast(@min(a.tail_len, frames));
        const tail = a.buffers.tail;
        a.toCorrector(k, tail[0 .. (a.tail_len - x) * ch], sink);
        @memcpy(a.buffers.xfade[0 .. x * ch], tail[(a.tail_len - x) * ch .. a.tail_len * ch]);
        a.tail_len = 0;
        a.xfade_len = x;
        a.xfade_pos = 0;
        a.skip_left = frames - x;
        a.fade_in_left = if (x == 0) fade else 0;
    }

    /// A crossfade cut short (another snap, or the segment's end): what's left of what came
    /// before fades out alone, and the frames it would have taken are skipped.
    fn finishXfade(a: *Aligner, k: *const Kernel, sink: anytype) void {
        if (a.xfade_pos < a.xfade_len) {
            const ch = a.channels;
            for (a.xfade_pos..a.xfade_len) |i| {
                const g = fadeOut(i, a.xfade_len);
                for (a.buffers.xfade[i * ch ..][0..ch]) |*o| o.* *= g;
            }
            a.skip_left += a.xfade_len - a.xfade_pos;
            const left = a.buffers.xfade[a.xfade_pos * ch .. a.xfade_len * ch];
            a.xfade_len = 0;
            a.xfade_pos = 0;
            a.hold(k, left, sink);
        }
        a.xfade_len = 0;
        a.xfade_pos = 0;
    }

    /// Finishing, and the end is written: what's left can't go anywhere.
    fn pastEnd(a: *const Aligner) bool {
        const s = a.stop_at orelse return false;
        return a.written >= s;
    }

    fn toCorrector(a: *Aligner, k: *const Kernel, frames: []const f32, sink: anytype) void {
        const c = &a.corrector.?;
        const ch = a.channels;
        var rest = frames;
        while (rest.len > 0) {
            if (a.pastEnd()) return;
            const n: usize = @intCast(@min(rest.len / ch, c.ring_frames / 2));
            a.makeRoom(k, n, sink);
            c.pushFrames(rest[0 .. n * ch]);
            rest = rest[n * ch ..];
            a.drain(k, false, null, sink);
        }
    }

    /// Output frames until the device's frames run out (or with `flush`, until all of them
    /// are out, or `until` is reached).
    fn drain(a: *Aligner, k: *const Kernel, flush: bool, until: ?u64, sink: anytype) void {
        const c = &a.corrector.?;
        var out: [1024]f32 = undefined;
        const per = out.len / a.channels;
        const limit: ?u64 = if (until) |u| (if (a.stop_at) |s| @min(u, s) else u) else a.stop_at;
        while (true) {
            var max = per;
            if (limit) |u| {
                if (a.written >= u) return;
                max = @intCast(@min(per, u - a.written));
            }
            // Flushing: until read is past the last frame and the filter's reach.
            if (flush and c.read_index - half_taps >= @as(i64, @intCast(c.end))) return;
            const n = c.produce(k, out[0 .. max * a.channels], a.outputQpc(a.written), flush);
            if (n == 0) return;
            sink.write(out[0 .. n * a.channels]);
            a.written += n;
        }
    }

    fn makeRoom(a: *Aligner, k: *const Kernel, frames: u64, sink: anytype) void {
        const c = &a.corrector.?;
        if (c.room() < frames) a.drain(k, false, null, sink);
        if (c.room() < frames) std.debug.panic("resample ring too small: {d} frames free for {d}", .{ c.room(), frames });
    }

    fn pushZeros(a: *Aligner, k: *const Kernel, frames: u64, sink: anytype) void {
        const c = &a.corrector.?;
        var left = frames;
        while (left > 0) {
            if (a.pastEnd()) return;
            const chunk = @min(left, c.ring_frames / 2);
            a.makeRoom(k, chunk, sink);
            c.pushZeros(chunk);
            left -= chunk;
            a.drain(k, false, null, sink);
        }
    }

    fn outputQpc(a: *const Aligner, frame: u64) u64 {
        return a.start_qpc + @as(u64, @intCast(@as(u128, frame) * 10_000_000 / a.rate));
    }

    /// Frames from the timeline's start to `qpc` (0 before it).
    fn timelineFrame(a: *const Aligner, qpc: u64) u64 {
        if (qpc <= a.start_qpc) return 0;
        return @intCast(@as(u128, qpc - a.start_qpc) * a.rate / 10_000_000);
    }
};

/// Raised-cosine gain falling from 1 to 0 over frames [0, n).
fn fadeOut(i: usize, n: usize) f32 {
    const x = (@as(f64, @floatFromInt(i)) + 0.5) / @as(f64, @floatFromInt(n));
    return @floatCast(0.5 * (1 + @cos(std.math.pi * x)));
}

/// A device's clock over a whole track, for reporting: a least-squares line through (time,
/// position), one point at a time (Welford's method, accurate over hours), and its rate over
/// windows of window_seconds, whose spread shows a rate that wanders.
pub const DriftFit = extern struct {
    n: u64 = 0,
    origin_qpc: u64 = 0,
    mean_x: f64 = 0,
    mean_y: f64 = 0,
    m2x: f64 = 0,
    cxy: f64 = 0,
    /// Seconds from the first point to the last.
    span: f64 = 0,
    /// Added to positions after a restart, so the line carries on.
    offset: u64 = 0,
    window_n: u64 = 0,
    window_start: f64 = 0,
    window_mean_x: f64 = 0,
    window_mean_y: f64 = 0,
    window_m2x: f64 = 0,
    window_cxy: f64 = 0,
    window_rate_min: f64 = std.math.inf(f64),
    window_rate_max: f64 = -std.math.inf(f64),

    pub const window_seconds = 30;

    pub fn add(f: *DriftFit, qpc: u64, position: u64) void {
        if (f.n == 0) f.origin_qpc = qpc;
        const x = @as(f64, @floatFromInt(@as(i128, qpc) - @as(i128, f.origin_qpc))) / 10_000_000;
        const y: f64 = @floatFromInt(position);
        welford(&f.n, &f.mean_x, &f.mean_y, &f.m2x, &f.cxy, x, y);
        f.span = x;
        if (f.window_n > 0 and x - f.window_start >= window_seconds) {
            if (f.window_m2x > 0) {
                const r = f.window_cxy / f.window_m2x;
                f.window_rate_min = @min(f.window_rate_min, r);
                f.window_rate_max = @max(f.window_rate_max, r);
            }
            f.window_n = 0;
            f.window_mean_x = 0;
            f.window_mean_y = 0;
            f.window_m2x = 0;
            f.window_cxy = 0;
        }
        if (f.window_n == 0) f.window_start = x;
        welford(&f.window_n, &f.window_mean_x, &f.window_mean_y, &f.window_m2x, &f.window_cxy, x, y);
    }

    fn welford(n: *u64, mean_x: *f64, mean_y: *f64, m2x: *f64, cxy: *f64, x: f64, y: f64) void {
        n.* += 1;
        const dx = x - mean_x.*;
        mean_x.* += dx / @as(f64, @floatFromInt(n.*));
        mean_y.* += (y - mean_y.*) / @as(f64, @floatFromInt(n.*));
        m2x.* += dx * (x - mean_x.*);
        cxy.* += dx * (y - mean_y.*);
    }

    /// Frames per second over the whole track, once there's enough to tell.
    pub fn rate(f: *const DriftFit) ?f64 {
        if (f.n < 2 or f.m2x == 0) return null;
        return f.cxy / f.m2x;
    }
};

const std = @import("std");
