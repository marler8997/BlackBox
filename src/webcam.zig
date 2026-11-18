//! Webcams, part of the Windows platform layer: listing them and what they deliver, through
//! Media Foundation.
//!
//! A webcam's frames are too big to journal raw the way audio is (1080p at 30 fps in NV12 is
//! about 93 MB/s), so they're encoded to H.264 as they arrive, by the GPU's encoder when it has
//! one, and the journal gets the encoded frames. `probe` shows what a machine has for that.

/// Lists the webcams for the devices menu, with bb.addDevice. Their ids are their symbolic
/// links, for Capture.create.
pub fn listDevices(gpa: std.mem.Allocator) void {
    mfStartup();
    defer mfShutdown();
    var devices: Activates = .enumDevices();
    defer devices.deinit();
    for (devices.items) |activate| {
        const attrs = &activate.IMFAttributes;
        bb.addDevice(.{
            .name = allocAttrString(gpa, attrs, &win32.MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME),
            .id = allocAttrString(gpa, attrs, &win32.MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK),
            .format = null,
        });
    }
}

fn allocAttrString(gpa: std.mem.Allocator, attrs: *win32.IMFAttributes, key: *const win32.Guid) []const u8 {
    var wide: ?[*:0]u16 = null;
    var len: u32 = 0;
    const hr = attrs.GetAllocatedString(key, &wide, &len);
    if (hr.failed) win32.panicHresult("IMFAttributes.GetAllocatedString", hr);
    defer win32.CoTaskMemFree(wide);
    return std.unicode.wtf16LeToWtf8Alloc(gpa, wide.?[0..len]) catch @panic("out of memory");
}

/// A webcam being captured and encoded, for a bb source: on its own thread, from the camera
/// to the encoder (frames staying on the GPU when the encoder takes them), and the encoded
/// frames to a recorder while recording. Posts wasapi.status_msg like an audio capture.
///
/// The camera's reader runs asynchronously: it hands each frame to a callback (on Media
/// Foundation's thread), which signals the capture thread. The capture thread waits for that,
/// for stop_event and for drain_event, with a timeout, as an audio capture waits for its
/// packets: so stopping doesn't wait for the camera, and a camera that stops sending fails
/// after a timeout, all on its own thread. (A synchronous read can't be woken: it waits for
/// the next frame whatever else happens, even the camera being shut down.)
pub const Capture = struct {
    /// Which bb source this is for.
    id: u32,
    /// The webcam to open, from listDevices.
    symbolic_link: [:0]const u16,
    hwnd: win32.HWND,
    thread: std.Thread,
    gpa: std.mem.Allocator,
    /// Written by the thread, which then posts status_msg; read by the window's thread.
    state_lock: record.Lock = .{},
    state: State = .starting,
    /// Set by destroy: the thread stops, now.
    stop_event: win32.HANDLE,
    /// Set when the thread is done (failed or stopped), for waitDrained.
    exited_event: win32.HANDLE,
    /// The recorder this capture's frames go to while recording. Set and taken on the
    /// window's thread (attachRecorder, detachRecorder), used by the capture thread, under the
    /// lock.
    recorder_lock: record.Lock = .{},
    recorder: ?Attached = null,
    /// The window asked for the encoder to be drained into the recorder before detaching it
    /// (requestDrain, which sets drain_event); the capture thread drains it and sets
    /// drained_event.
    drain_requested: std.atomic.Value(bool) = .init(false),
    drain_event: win32.HANDLE,
    drained_event: win32.HANDLE,
    /// Frames encoded and dropped so far (to the recorder or not), for the window (see
    /// bb.setSourceVideoCounts) and to see frames flowing.
    counts: bb.VideoCounts = .{},
    /// What its recordings' files show while there's no video from it (see makeNoVideo):
    /// made by the capture thread before it goes live, read by the window's thread after.
    novideo: []u8 = &.{},

    pub const State = union(enum) {
        starting,
        /// What it captures and how it's encoded.
        live: bb.SourceStatus.VideoLive,
        failed: struct {
            message: bb.Message,
            /// The camera was busy (another app has it) or blocked (privacy settings): not
            /// this program's trouble.
            unavailable: bool,
        },
    };

    const Attached = struct {
        source: *record.AudioPoolSource,
        /// When its recording started, QPC in 100ns units: frames captured before aren't its.
        start: u64,
        first: union(enum) {
            /// No frame of its yet: the first captured from `start` on is made a keyframe, so
            /// its file starts with one instead of waiting up to two seconds for the next.
            waiting,
            /// That frame's time: what the encoder gives back from before it (held while the
            /// recorder was attached) isn't the recorder's.
            from: i64,
        } = .waiting,
    };

    /// A live webcam that sends nothing for this long has stopped. As long as an audio
    /// capture waits for a packet; a camera slows to 15 fps in the dark, never this slow.
    const stall_ms = 2000;
    /// Its first frame can take longer: the camera starts on the first read, and exposure
    /// settles, or effects (Windows Studio Effects) start, before it.
    const first_frame_ms = 10_000;
    /// An encoder that takes frames and gives none back for this long has stopped. Encoders
    /// hold frames to look ahead (Windows' software one 18 frames: 3.6 seconds at 5 fps).
    const encoder_stall_ms = 10_000;

    /// Allocates a capture and starts its thread. Stop it with `destroy`.
    pub fn create(gpa: std.mem.Allocator, id: u32, device_id: []const u8, hwnd: win32.HWND) *Capture {
        const c = gpa.create(Capture) catch @panic("out of memory");
        c.* = .{
            .id = id,
            .symbolic_link = std.unicode.wtf8ToWtf16LeAllocZ(gpa, device_id) catch |e| switch (e) {
                error.OutOfMemory => @panic("out of memory"),
                error.InvalidWtf8 => unreachable, // listDevices made it from UTF-16
            },
            .hwnd = hwnd,
            .thread = undefined,
            .gpa = gpa,
            .stop_event = createEvent(true),
            .exited_event = createEvent(true),
            .drain_event = createEvent(false),
            .drained_event = createEvent(false),
        };
        c.thread = std.Thread.spawn(.{}, run, .{c}) catch |e| std.debug.panic("spawning the webcam thread failed: {t}", .{e});
        return c;
    }

    /// Stops the thread and frees the capture. The thread waits only on its events, the
    /// encoder (bounded, see Encoder.drain) and Media Foundation; closing the camera is what
    /// takes longest (stopping it, a few hundred milliseconds on the dev machine's).
    /// Asks the thread to stop, without waiting: see hasExited, then destroy.
    pub fn requestStop(c: *Capture) void {
        if (0 == win32.SetEvent(c.stop_event)) win32.panicWin32("SetEvent(webcam stop)", win32.GetLastError());
    }

    /// Whether the thread has ended: destroy won't wait.
    pub fn hasExited(c: *Capture) bool {
        return signaled(c.exited_event);
    }

    /// Whether a drain requestDrain asked for is done (or the thread has ended), without
    /// waiting: see waitDrained.
    pub fn drainDone(c: *Capture) bool {
        return !c.drain_requested.load(.acquire) or signaled(c.drained_event) or signaled(c.exited_event);
    }

    /// Stops the thread (waiting for it, see requestStop) and frees the capture.
    pub fn destroy(c: *Capture, gpa: std.mem.Allocator) void {
        c.requestStop();
        c.thread.join();
        win32.closeHandle(c.stop_event);
        win32.closeHandle(c.exited_event);
        win32.closeHandle(c.drain_event);
        win32.closeHandle(c.drained_event);
        gpa.free(c.novideo);
        gpa.free(c.symbolic_link);
        gpa.destroy(c);
    }

    /// The status for bb. Call on the window's thread, after status_msg.
    pub fn sourceStatus(c: *Capture) bb.SourceStatus {
        c.state_lock.lock();
        defer c.state_lock.unlock();
        return switch (c.state) {
            .starting => .starting,
            .live => |l| .{ .live = .{ .video = l } },
            .failed => |f| .{ .failed = f.message },
        };
    }

    pub fn isLive(c: *Capture) bool {
        c.state_lock.lock();
        defer c.state_lock.unlock();
        return c.state == .live;
    }

    /// What its files show while there's no video from it. Once it's been live (made before,
    /// and not changed after, even if it fails).
    pub fn noVideo(c: *Capture) []const u8 {
        return c.novideo;
    }

    /// The track details for the recorder, if it's live: it can fail any time before.
    pub fn trackVideo(c: *Capture) ?record.TrackInfo.Video {
        c.state_lock.lock();
        defer c.state_lock.unlock();
        return switch (c.state) {
            .live => |l| l,
            .starting, .failed => null,
        };
    }

    /// From the window's thread, once live: frames captured from `recording_start` (QPC,
    /// 100ns units) on go to `r`, the first a keyframe.
    pub fn attachRecorder(c: *Capture, r: *record.AudioPoolSource, recording_start: u64) void {
        c.recorder_lock.lock();
        defer c.recorder_lock.unlock();
        std.debug.assert(c.recorder == null);
        c.recorder = .{ .source = r, .start = recording_start };
    }

    /// The window's thread's look at the recorder (it sets and takes it).
    pub fn recorderSource(c: *Capture) ?*record.AudioPoolSource {
        c.recorder_lock.lock();
        defer c.recorder_lock.unlock();
        return if (c.recorder) |a| a.source else null;
    }

    /// From the window's thread, before detachRecorder: asks the capture thread to drain the
    /// encoder into the recorder, so the frames it still holds (up to its lookahead) reach the
    /// file. waitDrained waits for that. Stopping several webcams, ask them all first, then
    /// wait for each: they drain at once.
    pub fn requestDrain(c: *Capture) void {
        if (c.recorderSource() == null or !c.isLive()) return;
        if (0 == win32.ResetEvent(c.drained_event)) win32.panicWin32("ResetEvent(webcam drained)", win32.GetLastError());
        c.drain_requested.store(true, .release);
        if (0 == win32.SetEvent(c.drain_event)) win32.panicWin32("SetEvent(webcam drain)", win32.GetLastError());
    }

    /// Waits for a drain requestDrain asked for: until it's done, the thread exits (it
    /// failed), or `deadline` (QPC, 100ns units; one deadline for all the webcams stopping,
    /// see drainDeadline). Past it, what the encoder holds is lost, but recording stops on
    /// time.
    pub fn waitDrained(c: *Capture, deadline: u64) void {
        if (!c.drain_requested.load(.acquire)) return;
        defer c.drain_requested.store(false, .release);
        const now = record.qpc100ns();
        const ms: u32 = if (now >= deadline) 0 else @intCast((deadline - now) / 10_000);
        const handles = [_]?win32.HANDLE{ c.drained_event, c.exited_event };
        switch (@backingInt(win32.WaitForMultipleObjects(handles.len, &handles, 0, ms))) {
            0, 1, @backingInt(win32.WAIT_TIMEOUT) => {},
            else => win32.panicWin32("WaitForMultipleObjects(webcam drained)", win32.GetLastError()),
        }
    }

    /// The deadline for webcams asked to drain now (waitDrained).
    pub fn drainDeadline() u64 {
        return record.qpc100ns() + drain_wait_ms * 10_000;
    }

    const drain_wait_ms = 500;

    /// From the window's thread. After this the capture thread doesn't touch the recorder.
    pub fn detachRecorder(c: *Capture) ?*record.AudioPoolSource {
        c.recorder_lock.lock();
        defer c.recorder_lock.unlock();
        defer c.recorder = null;
        return if (c.recorder) |a| a.source else null;
    }

    fn setState(c: *Capture, state: State) void {
        {
            c.state_lock.lock();
            defer c.state_lock.unlock();
            c.state = state;
        }
        if (0 == win32.PostMessageW(c.hwnd, wasapi.status_msg, c.id, 0)) win32.panicWin32("PostMessage(capture status)", win32.GetLastError());
    }

    fn fail(c: *Capture, p: Problem) void {
        c.setState(.{ .failed = .{ .message = .init("{f}", .{p}), .unavailable = p.unavailable() } });
    }
};

/// Whether an event is set, without waiting. An auto-reset one is reset by it.
fn signaled(event: win32.HANDLE) bool {
    return switch (@backingInt(win32.WaitForSingleObject(event, 0))) {
        @backingInt(win32.WAIT_OBJECT_0) => true,
        @backingInt(win32.WAIT_TIMEOUT) => false,
        else => win32.panicWin32("WaitForSingleObject(webcam event)", win32.GetLastError()),
    };
}

/// A Win32 event, manual-reset or auto-reset, not set.
fn createEvent(manual_reset: bool) win32.HANDLE {
    return win32.CreateEventW(null, @intFromBool(manual_reset), 0, null) orelse win32.panicWin32("CreateEvent", win32.GetLastError());
}

fn run(c: *Capture) void {
    // However the thread ends: waitDrained stops waiting.
    defer if (0 == win32.SetEvent(c.exited_event)) win32.panicWin32("SetEvent(webcam exited)", win32.GetLastError());
    // Like main, leaves room to report a stack overflow on this thread.
    var guarantee: u32 = wintrace.stack_guarantee;
    if (0 == wintrace.SetThreadStackGuarantee(&guarantee)) win32.panicWin32("SetThreadStackGuarantee", win32.GetLastError());
    {
        const hr = win32.CoInitializeEx(null, win32.COINIT_MULTITHREADED);
        if (hr.failed) win32.panicHresult("CoInitializeEx", hr);
    }
    defer win32.CoUninitialize();
    // Scheduled ahead of ordinary threads (MMCSS "Capture"), so a busy machine doesn't make it
    // miss frames.
    var task_index: u32 = 0;
    const mmcss = win32.AvSetMmThreadCharacteristicsW(win32.L("Capture"), &task_index) orelse
        return c.fail(.{ .mmcss = @intFromEnum(win32.GetLastError()) });
    defer if (0 == win32.AvRevertMmThreadCharacteristics(mmcss)) win32.panicWin32("AvRevertMmThreadCharacteristics", win32.GetLastError());
    mfStartup();
    defer mfShutdown();
    var p: Problem = undefined;
    capture(c, &p) catch |e| switch (e) {
        error.Failed => c.fail(p),
    };
}

/// Returns when stopped (stop_event), or fails.
fn capture(c: *Capture, p: *Problem) error{Failed}!void {
    var gpu: ?Gpu = null;
    defer if (gpu) |*g| g.deinit();
    var encoder: Encoder = try .create(&gpu, p);
    defer encoder.destroy();
    const callback = ReaderCallback.create(c.gpa);
    defer callback.release();
    var camera: Camera = try .open(c.symbolic_link, if (gpu) |*g| g else null, callback, p);
    defer camera.close();
    try encoder.start(camera.format, p);
    c.novideo = try makeNoVideo(c.gpa, camera.format, p);

    const f = camera.format;
    var live: bb.SourceStatus.VideoLive = .{
        .format = .{ .width = f.width, .height = f.height, .fps_num = f.fps_num, .fps_den = f.fps_den },
        .bitrate = f.bitrate(),
        .path = if (gpu != null) .gpu else if (encoder.hardware) .hardware else .software,
    };
    const name = record.truncateUtf8(encoder.name(), live.encoder_buf.len);
    @memcpy(live.encoder_buf[0..name.len], name);
    live.encoder_len = @intCast(name.len);
    if (encoder.hardware) {
        // DXGI's description is 128 UTF-16 units: up to 3 bytes each.
        var gpu_name: [3 * 128]u8 = undefined;
        const g = record.truncateUtf8(adapterName(encoder.adapter, &gpu_name), live.gpu_buf.len);
        @memcpy(live.gpu_buf[0..g.len], g);
        live.gpu_len = @intCast(g.len);
    }
    {
        var w: std.Io.Writer = .fixed(&live.camera_format_buf);
        // The longest: a GUID's 32 hex digits.
        writeSubtype(&w, camera.native_subtype) catch unreachable;
        live.camera_format_len = @intCast(w.end);
        live.camera_converted = !std.mem.eql(u8, &camera.native_subtype.Bytes, &f.subtype.Bytes);
    }
    c.setState(.{ .live = live });

    var sink: RecorderSink = .{ .c = c };
    var number: u64 = 0;
    // When the last frame came (or it went live): a stall is counted from there, whatever
    // else wakes the thread meanwhile (drains, frameless stream ticks).
    var last_frame_qpc = record.qpc100ns();
    try camera.request(p);
    const handles = [_]?win32.HANDLE{ c.stop_event, c.drain_event, callback.event };
    while (true) {
        const limit_hns = @as(u64, if (number == 0) Capture.first_frame_ms else Capture.stall_ms) * 10_000;
        const now = record.qpc100ns();
        const waited = now -| last_frame_qpc;
        if (waited >= limit_hns) {
            p.* = .{ .stalled = if (number == 0) .first_frame else .frames };
            return error.Failed;
        }
        if (sink.waiting_since) |since| if (now -| since >= Capture.encoder_stall_ms * 10_000) {
            p.* = .{ .stalled = .encoder };
            return error.Failed;
        };
        const timeout: u32 = @intCast((limit_hns - waited + 9_999) / 10_000);
        switch (@backingInt(win32.WaitForMultipleObjects(handles.len, &handles, 0, timeout))) {
            0 => return, // stop_event
            1 => {
                // drain_event: the encoder's frames out to the recorder, before it's detached.
                if (!c.drain_requested.load(.acquire)) continue;
                try encoder.drain(&sink, p);
                if (0 == win32.SetEvent(c.drained_event)) win32.panicWin32("SetEvent(webcam drained)", win32.GetLastError());
                continue;
            },
            2 => {}, // a frame, or the reader's error
            @backingInt(win32.WAIT_TIMEOUT) => continue, // checked above
            else => win32.panicWin32("WaitForMultipleObjects(webcam)", win32.GetLastError()),
        }
        const frame = (try camera.take(p)) orelse continue;
        defer _ = frame.sample.IUnknown.Release();
        last_frame_qpc = record.qpc100ns();
        // The next frame is read while this one is encoded.
        try camera.request(p);
        defer number += 1;
        // A recorder's first frame (captured once its recording started) is a keyframe.
        const keyframe = blk: {
            c.recorder_lock.lock();
            defer c.recorder_lock.unlock();
            const a = if (c.recorder) |*a| a else break :blk false;
            if (a.first != .waiting or frame.time < a.start) break :blk false;
            a.first = .{ .from = frame.time };
            break :blk true;
        };
        // A recorder's first, or one by time (see KeyframeClock).
        if (sink.keyframes.due(frame.time) or keyframe) try encoder.forceKeyframe(p);
        if (try encoder.encode(frame, &sink, p)) {
            if (sink.waiting_since == null) sink.waiting_since = last_frame_qpc;
        } else {
            // Not taken (the encoder was busy): a dropped frame, counted in the journal.
            sink.refused += 1;
            _ = c.counts.dropped.fetchAdd(1, .monotonic);
        }
    }
}

/// The source reader's callback, in its asynchronous mode (MF_SOURCE_READER_ASYNC_CALLBACK):
/// it hands over the frame (or error) each read ends with, and signals `event`; the capture
/// thread takes it (Camera.take). Reference counted, as COM objects are: the reader holds it
/// too, and may call it until it's released, so it owns everything it touches.
const ReaderCallback = struct {
    iface: win32.IMFSourceReaderCallback = .{ .vtable = &vtable },
    refs: std.atomic.Value(u32) = .init(1),
    gpa: std.mem.Allocator,
    /// Set when a read ends (auto-reset), and when a flush does.
    event: win32.HANDLE,
    flushed_event: win32.HANDLE,
    lock: record.Lock = .{},
    /// The last read's result, until taken.
    result: ?Result = null,

    const Result = struct {
        hr: win32.HRESULT,
        flags: u32,
        time: i64,
        /// Ours (AddRef'd), handed to whoever takes it.
        sample: ?*win32.IMFSample,
    };

    const vtable: win32.IMFSourceReaderCallback.VTable = .{
        .base = .{ .QueryInterface = queryInterface, .AddRef = addRef, .Release = releaseCom },
        .OnReadSample = onReadSample,
        .OnFlush = onFlush,
        .OnEvent = onEvent,
    };

    fn create(gpa: std.mem.Allocator) *ReaderCallback {
        const cb = gpa.create(ReaderCallback) catch @panic("out of memory");
        cb.* = .{ .gpa = gpa, .event = createEvent(false), .flushed_event = createEvent(false) };
        return cb;
    }

    fn release(cb: *ReaderCallback) void {
        if (cb.refs.fetchSub(1, .acq_rel) != 1) return;
        if (cb.result) |r| if (r.sample) |s| {
            _ = s.IUnknown.Release();
        };
        win32.closeHandle(cb.event);
        win32.closeHandle(cb.flushed_event);
        cb.gpa.destroy(cb);
    }

    /// The last read's result, if it's come.
    fn take(cb: *ReaderCallback) ?Result {
        cb.lock.lock();
        defer cb.lock.unlock();
        defer cb.result = null;
        return cb.result;
    }

    fn of(self: anytype) *ReaderCallback {
        return @constCast(@as(*const ReaderCallback, @alignCast(@fieldParentPtr("iface", @as(*const win32.IMFSourceReaderCallback, @ptrCast(self))))));
    }

    fn queryInterface(self: *const win32.IUnknown, riid: *const win32.Guid, out: **anyopaque) callconv(.winapi) win32.HRESULT {
        if (std.mem.eql(u8, &riid.Bytes, &win32.IID_IUnknown.Bytes) or std.mem.eql(u8, &riid.Bytes, &win32.IID_IMFSourceReaderCallback.Bytes)) {
            const cb = of(self);
            _ = cb.refs.fetchAdd(1, .monotonic);
            out.* = &cb.iface;
            return win32.S_OK;
        }
        // COM's rule: no interface, null.
        @as(*?*anyopaque, @ptrCast(out)).* = null;
        return win32.E_NOINTERFACE;
    }

    fn addRef(self: *const win32.IUnknown) callconv(.winapi) u32 {
        return of(self).refs.fetchAdd(1, .monotonic) + 1;
    }

    fn releaseCom(self: *const win32.IUnknown) callconv(.winapi) u32 {
        const cb = of(self);
        const left = cb.refs.load(.monotonic) - 1;
        cb.release();
        return left;
    }

    fn onReadSample(self: *const win32.IMFSourceReaderCallback, hr: win32.HRESULT, stream: u32, flags: u32, time: i64, sample: ?*win32.IMFSample) callconv(.winapi) win32.HRESULT {
        _ = stream;
        const cb = of(self);
        if (sample) |s| _ = s.IUnknown.AddRef();
        {
            cb.lock.lock();
            defer cb.lock.unlock();
            // One read at a time (Camera.request), each taken before the next is asked for.
            std.debug.assert(cb.result == null);
            cb.result = .{ .hr = hr, .flags = flags, .time = time, .sample = sample };
        }
        if (0 == win32.SetEvent(cb.event)) win32.panicWin32("SetEvent(webcam frame)", win32.GetLastError());
        return win32.S_OK;
    }

    fn onFlush(self: *const win32.IMFSourceReaderCallback, stream: u32) callconv(.winapi) win32.HRESULT {
        _ = stream;
        if (0 == win32.SetEvent(of(self).flushed_event)) win32.panicWin32("SetEvent(webcam flushed)", win32.GetLastError());
        return win32.S_OK;
    }

    fn onEvent(_: *const win32.IMFSourceReaderCallback, _: u32, _: ?*win32.IMFMediaEvent) callconv(.winapi) win32.HRESULT {
        return win32.S_OK;
    }
};

/// A keyframe every 2 seconds: where a file can be cut, seeked to and recovered from.
const keyframe_hns = 20_000_000;

/// Keyframes by time, not frames: the encoder makes one every keyframe_hns of frames at the
/// camera's announced rate, so a camera that slows (a BRIO announcing 60 fps gives ~33 in low
/// light) would make them rarer, 3.6 s apart. This asks for one when none has come out for
/// keyframe_hns of capture time, and not again until that long after asking (an encoder
/// that looks ahead gives it some frames later).
const KeyframeClock = struct {
    /// When the last keyframe out, and the last asked for, were captured (100ns units).
    last_out: ?i64 = null,
    last_asked: ?i64 = null,

    /// Whether to ask for a keyframe at a frame captured at `time`: if so, it's taken as asked.
    fn due(k: *KeyframeClock, time: i64) bool {
        const out = k.last_out orelse return false;
        if (time - out < keyframe_hns) return false;
        if (k.last_asked) |asked| if (time - asked < keyframe_hns) return false;
        k.last_asked = time;
        return true;
    }

    /// A keyframe came out, captured at `time`.
    fn keyframeOut(k: *KeyframeClock, time: i64) void {
        k.last_out = time;
    }
};

test KeyframeClock {
    var k: KeyframeClock = .{};
    // Before any keyframe came out: the encoder makes the first.
    try std.testing.expect(!k.due(0));
    k.keyframeOut(0);
    // A camera at half its rate: frames every 1/15 s where 1/30 was announced.
    var keyframes: u32 = 0;
    var t: i64 = 0;
    while (t < 10 * 10_000_000) : (t += 666_666) {
        if (k.due(t)) {
            keyframes += 1;
            // Out a few frames later, as from an encoder that looks ahead.
            k.keyframeOut(t + 3 * 666_666);
        }
    }
    // One every 2 seconds or so (each counted from the last out), not one a frame.
    try std.testing.expect(keyframes >= 4 and keyframes <= 5);
}

/// Encoded frames to the recorder, if one is attached, each as the encoder gave it: its times
/// and bytes, in the order it gave them.
const RecorderSink = struct {
    c: *Capture,
    /// Frames the encoder gave since the capture started: the next one's number.
    next: u64 = 0,
    /// Frames the encoder refused (it was busy) since the capture started.
    refused: u64 = 0,
    /// When the encoder took the first frame it hasn't given anything back since, if it's
    /// holding any: see Capture.encoder_stall_ms.
    waiting_since: ?u64 = null,
    keyframes: KeyframeClock = .{},

    pub fn encoded(s: *RecorderSink, e: Encoded, p: *Problem) error{Failed}!void {
        _ = p;
        const number = s.next;
        s.next += 1;
        s.waiting_since = null;
        if (e.keyframe) s.keyframes.keyframeOut(e.time);
        _ = s.c.counts.encoded.fetchAdd(1, .monotonic);
        s.c.recorder_lock.lock();
        defer s.c.recorder_lock.unlock();
        const a = s.c.recorder orelse return;
        // Shown before its first keyframe (held while it was attached): not its.
        switch (a.first) {
            .waiting => return,
            .from => |from| if (e.time < from) return,
        }
        // The reader's times are QPC, 100ns units: the recording's clock.
        a.source.pushVideo(e.parameter_sets, e.bytes, number, @intCast(e.time), .{ .decode_qpc = @bitCast(e.decode_time), .refused = s.refused }, e.keyframe);
    }
};

/// The name of the GPU `want` picks (see Gpu.init: the first adapter, the default, if none),
/// into `buf`, or "unknown" if there's no such adapter.
fn adapterName(want: ?Gpu.Adapter, buf: *[3 * 128]u8) []const u8 {
    var factory: *win32.IDXGIFactory1 = undefined;
    {
        const hr = win32.CreateDXGIFactory1(win32.IID_IDXGIFactory1, @ptrCast(&factory));
        if (hr.failed) win32.panicHresult("CreateDXGIFactory1", hr);
    }
    defer _ = factory.IUnknown.Release();
    var i: u32 = 0;
    while (true) : (i += 1) {
        var a: *win32.IDXGIAdapter1 = undefined;
        const hr = factory.EnumAdapters1(i, &a);
        if (hr == win32.DXGI_ERROR_NOT_FOUND) return "unknown";
        if (hr.failed) win32.panicHresult("IDXGIFactory1.EnumAdapters1", hr);
        defer _ = a.IUnknown.Release();
        var desc: win32.DXGI_ADAPTER_DESC = undefined;
        {
            const desc_hr = a.IDXGIAdapter.GetDesc(&desc);
            if (desc_hr.failed) win32.panicHresult("IDXGIAdapter.GetDesc", desc_hr);
        }
        const match = if (want) |w| switch (w) {
            .luid => |l| desc.AdapterLuid.LowPart == l.LowPart and desc.AdapterLuid.HighPart == l.HighPart,
            .vendor => |v| desc.VendorId == v,
        } else true;
        if (match) return buf[0..std.unicode.wtf16LeToWtf8(buf, std.mem.sliceTo(&desc.Description, 0))];
    }
}

/// What a webcam's file shows while there's no video from it (novideo.zig's picture), as a run
/// of frames the webcam's encoder makes for `format` (see mp4.NoVideoRun): another of the same
/// encoder, set up the same way, so the frames have the same parameters as the webcam's and
/// whatever decodes those decodes them (a GPU's decoder takes no stream another encoder
/// made: it gives black). The picture at the webcam's frame rate (see noVideoTiming), the first
/// a keyframe: the muxer repeats the run to fill a gap, so it plays as ordinary video. Made
/// once, when the webcam starts. Allocated.
/// How long makeNoVideo waits for an async encoder to take a frame.
const novideo_wait_ms = 2000;

/// Sleeps shorter than Sleep's (a scheduler tick, 16 ms): a high-resolution waitable timer's.
const WaitableMsTimer = struct {
    timer: win32.HANDLE,

    fn init() WaitableMsTimer {
        return .{ .timer = win32.CreateWaitableTimerExW(null, null, win32.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, @bitCast(win32.TIMER_ALL_ACCESS)) orelse
            win32.panicWin32("CreateWaitableTimerEx", win32.GetLastError()) };
    }
    fn deinit(t: WaitableMsTimer) void {
        win32.closeHandle(t.timer);
    }
    fn sleep(t: WaitableMsTimer, ms: u32) void {
        // Relative: negative, in 100 ns units.
        const due: win32.LARGE_INTEGER = .{ .QuadPart = -@as(i64, ms) * 10_000 };
        if (0 == win32.SetWaitableTimer(t.timer, &due, 0, null, null, 0)) win32.panicWin32("SetWaitableTimer", win32.GetLastError());
        switch (@backingInt(win32.WaitForSingleObject(t.timer, win32.INFINITE))) {
            0 => {},
            else => win32.panicWin32("WaitForSingleObject(timer)", win32.GetLastError()),
        }
    }
};

fn makeNoVideo(gpa: std.mem.Allocator, format: VideoFormat, p: *Problem) error{Failed}![]u8 {
    var gpu: ?Gpu = null;
    defer if (gpu) |*g| g.deinit();
    var e: Encoder = try .create(&gpu, p);
    defer e.destroy();
    try e.start(format, p);
    const buffer = try nv12Buffer(format, p);
    defer _ = buffer.IUnknown.Release();
    const timer: WaitableMsTimer = .init();
    defer timer.deinit();
    {
        var data: ?*u8 = null;
        try check(p, buffer.Lock(&data, null, null), "Drawing the NO VIDEO picture");
        novideo.nv12(@as([*]u8, @ptrCast(data.?))[0..novideo.nv12Len(format.width, format.height)], format.width, format.height);
        try check(p, buffer.Unlock(), "Drawing the NO VIDEO picture");
    }
    const Sink = struct {
        gpa: std.mem.Allocator,
        bytes: std.ArrayList(u8) = .empty,
        frames: [mp4.fragment_max_frames]struct { start: usize, end: usize, time: i64, decode_time: i64, keyframe: bool } = undefined,
        count: usize = 0,
        pub fn encoded(s: *@This(), out: Encoded, q: *Problem) error{Failed}!void {
            if (s.count == s.frames.len) {
                q.* = .{ .encoder_misbehaved = "it gave more frames than it took for its NO VIDEO picture" };
                return error.Failed;
            }
            const start = s.bytes.items.len;
            s.bytes.appendSlice(s.gpa, out.parameter_sets) catch @panic("out of memory");
            s.bytes.appendSlice(s.gpa, out.bytes) catch @panic("out of memory");
            s.frames[s.count] = .{ .start = start, .end = s.bytes.items.len, .time = out.time, .decode_time = out.decode_time, .keyframe = out.keyframe };
            s.count += 1;
        }
    };
    const timing = noVideoTiming(format);
    var sink: Sink = .{ .gpa = gpa };
    defer sink.bytes.deinit(gpa);
    try e.forceKeyframe(p);
    for (0..timing.frames) |i| {
        // Each its own sample (an async encoder holds them, each with its time), the same
        // picture.
        var sample: ?*win32.IMFSample = null;
        try check(p, win32.MFCreateSample(&sample), "Creating a frame");
        defer _ = sample.?.IUnknown.Release();
        try check(p, sample.?.AddBuffer(buffer), "Creating a frame");
        const time: i64 = @intCast(i * timing.interval);
        // An async encoder takes a frame once it asks for one. Tried every millisecond: on a
        // high-resolution timer, as Sleep(1) is a scheduler tick (16 ms, longer than a frame
        // takes). Not forever: an encoder that never asks fails the webcam, not hangs it.
        const deadline = record.qpc100ns() + novideo_wait_ms * 10_000;
        while (!try e.encode(.{ .sample = sample.?, .time = time }, &sink, p)) {
            if (record.qpc100ns() >= deadline) {
                p.* = .{ .encoder_misbehaved = "it took no frame to make its NO VIDEO picture" };
                return error.Failed;
            }
            timer.sleep(1);
        }
    }
    try e.drain(&sink, p);
    if (e.isDraining() or sink.count != timing.frames or !sink.frames[0].keyframe) {
        p.* = .{ .encoder_misbehaved = "it didn't make its NO VIDEO picture, a keyframe and then frames" };
        return error.Failed;
    }
    // The run: its frames' times from its first's.
    var blob: std.ArrayList(u8) = .empty;
    errdefer blob.deinit(gpa);
    blob.appendSlice(gpa, std.mem.asBytes(&mp4.NoVideoRun{ .interval = timing.interval, .frames = timing.frames })) catch @panic("out of memory");
    const first = sink.frames[0];
    for (sink.frames[0..sink.count]) |fr| {
        const shown = fr.time - first.time;
        const decode = fr.decode_time - first.decode_time;
        if (shown < 0 or decode < 0 or shown > std.math.maxInt(u32) or decode > std.math.maxInt(u32)) {
            p.* = .{ .encoder_misbehaved = "its NO VIDEO frames' times aren't a run's" };
            return error.Failed;
        }
        const header: mp4.NoVideoFrame = .{ .len = @intCast(fr.end - fr.start), .keyframe = @intFromBool(fr.keyframe), .shown = @intCast(shown), .decode = @intCast(decode) };
        blob.appendSlice(gpa, std.mem.asBytes(&header)) catch @panic("out of memory");
        blob.appendSlice(gpa, sink.bytes.items[fr.start..fr.end]) catch @panic("out of memory");
    }
    // As the muxer will take it.
    _ = mp4.NoVideoRun.parse(blob.items) catch {
        p.* = .{ .encoder_misbehaved = "its NO VIDEO frames aren't a run (see mp4.NoVideoRun)" };
        return error.Failed;
    };
    if (blob.items.len > record.max_novideo) {
        p.* = .{ .encoder_misbehaved = "its NO VIDEO frames are more than a recording takes" };
        return error.Failed;
    }
    return blob.toOwnedSlice(gpa) catch @panic("out of memory");
}

/// makeNoVideo's run: novideo_run_hns long, a frame at the webcam's rate (as many frames as
/// its own frames, so a decoder's latency, counted in frames, is as short for it: Windows'
/// decoder holds dozens before giving the first, seconds of frames twice a second). The
/// first frame is a keyframe of about 1 KB (640x480 on NVIDIA's encoder; 1.4 KB at 1080p),
/// the others about 30 bytes (the picture doesn't change), and the MP4 has 16 more for each:
/// about 7 MB an hour of gap at 640x480 and 30 fps, roughly 12 at 1080p and 60 (a webcam's
/// own video is GBs an hour), a keyframe to seek to every 2 seconds.
const novideo_run_hns = 20_000_000;

/// The run's frames for `format`: its frame duration, and how many fit novideo_run_hns (at
/// most a fragment's).
fn noVideoTiming(format: VideoFormat) struct { interval: u32, frames: u32 } {
    const interval: u32 = @intCast(@max(1, @as(u64, 10_000_000) * format.fps_den / format.fps_num));
    return .{ .interval = interval, .frames = @intCast(@min(mp4.fragment_max_frames, @max(1, novideo_run_hns / interval))) };
}

/// An NV12 frame's buffer, of `f`'s size, in system memory, its contents undefined.
fn nv12Buffer(f: VideoFormat, p: *Problem) error{Failed}!*win32.IMFMediaBuffer {
    var buffer: ?*win32.IMFMediaBuffer = null;
    const len: u32 = @intCast(novideo.nv12Len(f.width, f.height));
    try check(p, win32.MFCreateMemoryBuffer(len, &buffer), "Creating a frame");
    errdefer _ = buffer.?.IUnknown.Release();
    try check(p, buffer.?.SetCurrentLength(len), "Creating a frame");
    return buffer.?;
}
/// A hardware encoder's vendor id ("VEN_8086"), as DXGI numbers adapters' vendors.
fn parseVendor(s: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, s, "VEN_")) return null;
    return std.fmt.parseInt(u32, s["VEN_".len..], 16) catch null;
}

test parseVendor {
    try std.testing.expectEqual(0x8086, parseVendor("VEN_8086"));
    try std.testing.expectEqual(0x10DE, parseVendor("VEN_10DE"));
    try std.testing.expectEqual(null, parseVendor("8086"));
    try std.testing.expectEqual(null, parseVendor("VEN_XYZ"));
}

/// Whether an encoded frame (Annex B) has an SPS. One that isn't Annex B hasn't: the muxer
/// says what's wrong with it.
fn hasSps(bytes: []const u8) bool {
    var it = mp4.NalIterator.init(bytes) catch return false;
    while (it.next()) |nal| if (nal.len > 0 and mp4.nalType(nal) == mp4.NalType.sps) return true;
    return false;
}

test hasSps {
    try std.testing.expect(hasSps(&.{ 0, 0, 0, 1, 0x09, 0x10, 0, 0, 0, 1, 0x67, 0x64, 0, 0, 1, 0x68, 0xee, 0, 0, 1, 0x65, 0x88 }));
    // An IDR slice alone: its parameter sets went before (or only in the output type).
    try std.testing.expect(!hasSps(&.{ 0, 0, 0, 1, 0x09, 0x10, 0, 0, 1, 0x65, 0x88 }));
    try std.testing.expect(!hasSps(&.{ 0x65, 0x88 }));
}

/// Writes what Media Foundation offers for recording webcams: each video capture device and
/// the formats it delivers natively, then the H.264 encoders. For `blackbox webcams`. COM must
/// be initialized on the thread (multithreaded).
pub fn probe(w: *std.Io.Writer) error{WriteFailed}!void {
    mfStartup();
    defer mfShutdown();

    var devices: Activates = .enumDevices();
    defer devices.deinit();
    try w.print("{d} webcam{s}\n", .{ devices.items.len, if (devices.items.len == 1) "" else "s" });
    for (devices.items, 0..) |activate, i| {
        var name_buf: [256]u8 = undefined;
        try w.print("  {d}: {s}\n", .{ i, attrString(&activate.IMFAttributes, &win32.MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, &name_buf) });
        var link_buf: [512]u8 = undefined;
        try w.print("     {s}\n", .{attrString(&activate.IMFAttributes, &win32.MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, &link_buf)});
        try writeNativeTypes(w, activate);
    }

    var encoders: Activates = .enumH264Encoders();
    defer encoders.deinit();
    try w.print("{d} H.264 encoder{s}, best first\n", .{ encoders.items.len, if (encoders.items.len == 1) "" else "s" });
    for (encoders.items, 0..) |activate, i| {
        const attrs = &activate.IMFAttributes;
        var name_buf: [256]u8 = undefined;
        const name = attrString(attrs, &win32.MFT_FRIENDLY_NAME_Attribute, &name_buf);
        var vendor_buf: [64]u8 = undefined;
        // Only hardware encoders have a vendor id.
        const vendor: ?[]const u8 = if (hasAttr(attrs, &win32.MFT_ENUM_HARDWARE_VENDOR_ID_Attribute))
            attrString(attrs, &win32.MFT_ENUM_HARDWARE_VENDOR_ID_Attribute, &vendor_buf)
        else
            null;
        var is_async: u32 = 0;
        _ = attrs.GetUINT32(&win32.MF_TRANSFORM_ASYNC, &is_async);
        if (vendor) |v|
            try w.print("  {d}: {s} (hardware, vendor {s}{s})\n", .{ i, name, v, if (is_async != 0) ", async" else "" })
        else
            try w.print("  {d}: {s} (software{s})\n", .{ i, name, if (is_async != 0) ", async" else "" });
    }
}

/// The formats a webcam delivers without converting, as its source reader lists them.
fn writeNativeTypes(w: *std.Io.Writer, activate: *win32.IMFActivate) error{WriteFailed}!void {
    var source: *win32.IMFMediaSource = undefined;
    {
        const hr = activate.ActivateObject(win32.IID_IMFMediaSource, @ptrCast(&source));
        if (hr.failed) {
            // In use by an app that holds it exclusively, or blocked by privacy settings: worth
            // seeing, not fatal to listing the rest.
            try w.print("     can't open it, hresult={f}\n", .{hr});
            return;
        }
    }
    defer {
        _ = source.Shutdown();
        _ = activate.ShutdownObject();
        _ = source.IUnknown.Release();
    }
    var reader: ?*win32.IMFSourceReader = null;
    {
        const hr = win32.MFCreateSourceReaderFromMediaSource(source, null, &reader);
        if (hr.failed) win32.panicHresult("MFCreateSourceReaderFromMediaSource", hr);
    }
    defer _ = reader.?.IUnknown.Release();
    var index: u32 = 0;
    while (true) : (index += 1) {
        var media_type: ?*win32.IMFMediaType = null;
        const hr = reader.?.GetNativeMediaType(video_stream, index, &media_type);
        if (hr == win32.MF_E_NO_MORE_TYPES) break;
        if (hr.failed) win32.panicHresult("IMFSourceReader.GetNativeMediaType", hr);
        defer _ = media_type.?.IUnknown.Release();
        const format: VideoFormat = .of(&media_type.?.IMFAttributes);
        try w.print("     {f}\n", .{format});
    }
    if (index == 0) try w.writeAll("     no video formats\n");
}

/// A video media type's essentials.
pub const VideoFormat = struct {
    subtype: win32.Guid,
    width: u32,
    height: u32,
    /// Frames per second, as a fraction.
    fps_num: u32,
    fps_den: u32,

    fn of(attrs: *win32.IMFAttributes) VideoFormat {
        var subtype: win32.Guid = undefined;
        {
            const hr = attrs.GetGUID(&win32.MF_MT_SUBTYPE, &subtype);
            if (hr.failed) win32.panicHresult("IMFMediaType.GetGUID(MF_MT_SUBTYPE)", hr);
        }
        const size = attrU64(attrs, &win32.MF_MT_FRAME_SIZE, "MF_MT_FRAME_SIZE");
        const rate = attrU64(attrs, &win32.MF_MT_FRAME_RATE, "MF_MT_FRAME_RATE");
        return .{
            .subtype = subtype,
            .width = @intCast(size >> 32),
            .height = @truncate(size),
            .fps_num = @intCast(rate >> 32),
            .fps_den = @truncate(rate),
        };
    }

    /// For picking a camera's format: one at least min_fps first (a big picture at a few
    /// frames a second is worse than a smaller smooth one), then more pixels, then more frames
    /// per second, then the cheapest to get to NV12 (NV12 itself, then YUY2, then the rest,
    /// MJPEG among them, which needs decoding).
    fn better(a: VideoFormat, b: VideoFormat) bool {
        const smooth_a = a.atLeastFps(min_fps);
        const smooth_b = b.atLeastFps(min_fps);
        if (smooth_a != smooth_b) return smooth_a;
        const area_a = @as(u64, a.width) * a.height;
        const area_b = @as(u64, b.width) * b.height;
        if (area_a != area_b) return area_a > area_b;
        const rate_a = @as(u64, a.fps_num) * b.fps_den;
        const rate_b = @as(u64, b.fps_num) * a.fps_den;
        if (rate_a != rate_b) return rate_a > rate_b;
        return a.conversionCost() < b.conversionCost();
    }

    const min_fps = 15;

    fn atLeastFps(f: VideoFormat, fps: u32) bool {
        return f.fps_num >= @as(u64, fps) * f.fps_den;
    }

    fn conversionCost(f: VideoFormat) u8 {
        if (std.mem.eql(u8, &f.subtype.Bytes, &win32.MFVideoFormat_NV12.Bytes)) return 0;
        if (std.mem.eql(u8, &f.subtype.Bytes, &win32.MFVideoFormat_YUY2.Bytes)) return 1;
        return 2;
    }

    /// A format the encoders can take: a size and a rate (0 is neither).
    fn usable(f: VideoFormat) bool {
        return f.width != 0 and f.height != 0 and f.width <= max_width and f.height <= max_height and
            f.fps_num != 0 and f.fps_den != 0;
    }

    /// A keyframe every keyframe_hns of frames, at the camera's announced rate (the encoder
    /// counts frames). A camera slower than it says (in low light) makes them rarer: see
    /// KeyframeClock.
    fn keyframeInterval(f: VideoFormat) u32 {
        return @intCast(@max(1, @min(std.math.maxInt(u32), @as(u64, f.fps_num) * (keyframe_hns / 10_000_000) / f.fps_den)));
    }

    /// Bits per second: 0.1 bits per pixel, about 6 Mbps for 1080p at 30 fps, plenty for a
    /// webcam's mostly still picture.
    fn bitrate(f: VideoFormat) u32 {
        return @intCast(@as(u64, f.width) * f.height * f.fps_num / f.fps_den / 10);
    }

    /// An uncompressed video type: this format's subtype, size and rate.
    fn mediaType(f: VideoFormat, p: *Problem) error{Failed}!*win32.IMFMediaType {
        var t: ?*win32.IMFMediaType = null;
        try check(p, win32.MFCreateMediaType(&t), "Creating a media type");
        errdefer _ = t.?.IUnknown.Release();
        const a = &t.?.IMFAttributes;
        try check(p, a.SetGUID(&win32.MF_MT_MAJOR_TYPE, &win32.MFMediaType_Video), "Setting a media type");
        try check(p, a.SetGUID(&win32.MF_MT_SUBTYPE, &f.subtype), "Setting a media type");
        try f.setCommon(a, p);
        return t.?;
    }

    /// The H.264 type the encoder makes from frames of this format.
    fn h264Type(f: VideoFormat, p: *Problem) error{Failed}!*win32.IMFMediaType {
        var t: ?*win32.IMFMediaType = null;
        try check(p, win32.MFCreateMediaType(&t), "Creating a media type");
        errdefer _ = t.?.IUnknown.Release();
        const a = &t.?.IMFAttributes;
        try check(p, a.SetGUID(&win32.MF_MT_MAJOR_TYPE, &win32.MFMediaType_Video), "Setting a media type");
        try check(p, a.SetGUID(&win32.MF_MT_SUBTYPE, &win32.MFVideoFormat_H264), "Setting a media type");
        try check(p, a.SetUINT32(&win32.MF_MT_AVG_BITRATE, f.bitrate()), "Setting a media type");
        try check(p, a.SetUINT32(&win32.MF_MT_MPEG2_PROFILE, @intCast(@intFromEnum(win32.eAVEncH264VProfile.High))), "Setting a media type");
        try f.setCommon(a, p);
        return t.?;
    }

    fn setCommon(f: VideoFormat, a: *win32.IMFAttributes, p: *Problem) error{Failed}!void {
        try check(p, a.SetUINT64(&win32.MF_MT_FRAME_SIZE, @as(u64, f.width) << 32 | f.height), "Setting a media type");
        try check(p, a.SetUINT64(&win32.MF_MT_FRAME_RATE, @as(u64, f.fps_num) << 32 | f.fps_den), "Setting a media type");
        try check(p, a.SetUINT64(&win32.MF_MT_PIXEL_ASPECT_RATIO, 1 << 32 | 1), "Setting a media type");
        try check(p, a.SetUINT32(&win32.MF_MT_INTERLACE_MODE, @intCast(@intFromEnum(win32.MFVideoInterlaceMode.Progressive))), "Setting a media type");
    }

    pub fn format(f: VideoFormat, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try writeSubtype(w, f.subtype);
        try w.print(" {d}x{d} ", .{ f.width, f.height });
        if (f.fps_den != 0 and f.fps_num % f.fps_den == 0)
            try w.print("{d} fps", .{f.fps_num / f.fps_den})
        else if (f.fps_den != 0)
            try w.print("{d}.{d:0>2} fps ({d}/{d})", .{ f.fps_num / f.fps_den, f.fps_num % f.fps_den * 100 / f.fps_den, f.fps_num, f.fps_den })
        else
            try w.print("?/0 fps", .{});
    }
};

/// Video subtypes are a FOURCC in Media Foundation's base GUID (except a few, like RGB32's
/// D3DFORMAT code): the FOURCC if it's printable, otherwise the whole GUID.
fn writeSubtype(w: *std.Io.Writer, subtype: win32.Guid) std.Io.Writer.Error!void {
    var base = win32.MFVideoFormat_H264;
    base.Ints.a = subtype.Ints.a;
    if (std.mem.eql(u8, &base.Bytes, &subtype.Bytes)) {
        const fourcc: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, subtype.Ints.a));
        const printable = for (fourcc) |ch| {
            if (!std.ascii.isPrint(ch)) break false;
        } else true;
        if (printable) return w.writeAll(&fourcc);
        return w.print("format {d}", .{subtype.Ints.a});
    }
    try w.print("{x}", .{subtype.Bytes});
}

/// What failed, for the user.
pub const Problem = union(enum) {
    /// A Media Foundation (or Windows) call failed: the step, and its HRESULT.
    call: struct { what: []const u8, hr: win32.HRESULT },
    /// The capture thread couldn't get capture priority (MMCSS): the Windows error.
    mmcss: u32,
    /// No H.264 encoder (MFTEnumEx listed none).
    no_encoder,
    /// The webcam has no format the encoders take, up to max_width x max_height.
    no_format,
    /// The device runs at another format than the one chosen and set.
    device_format: struct { want: VideoFormat, got: VideoFormat },
    /// The reader's stream had an error (no HRESULT comes with it): the webcam going away.
    reader_error,
    /// The camera ended its stream.
    ended,
    /// The camera changed its format partway: the encoder is set up for the old one.
    format_changed,
    /// No frame came in time: the first, or one after the last; or the encoder took frames
    /// and gave none back.
    stalled: enum { first_frame, frames, encoder },
    /// The encoder broke its protocol: how.
    encoder_misbehaved: []const u8,
    /// An async encoder didn't finish draining in this many milliseconds.
    drain_stuck: u32,

    pub fn format(p: Problem, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (p) {
            .call => |c| {
                if (c.hr == win32.E_ACCESSDENIED) return w.writeAll("Windows is blocking camera access, see Settings > Privacy > Camera");
                if (c.hr == mf_e_video_recording_device_locked) return w.writeAll("Another app is using the webcam");
                if (c.hr == win32.MF_E_HW_MFT_FAILED_START_STREAMING) return w.writeAll("The webcam couldn't start, it may be in use by another app");
                try w.print("{s} failed, error 0x{X:0>8}", .{ c.what, @as(u32, @bitCast(c.hr)) });
            },
            .mmcss => |err| try w.print("Couldn't give the webcam's thread capture priority (MMCSS error {d})", .{err}),
            .no_encoder => try w.writeAll("No H.264 encoder found"),
            .no_format => try w.print("The webcam has no format up to {d}x{d} to record", .{ max_width, max_height }),
            .device_format => |d| try w.print("The webcam runs at {f}, not {f} as set", .{ d.got, d.want }),
            .reader_error => try w.writeAll("The webcam stopped (unplugged, or taken by another app)"),
            .ended => try w.writeAll("The webcam ended its video"),
            .format_changed => try w.writeAll("The webcam changed its format partway; remove it and add it again"),
            .stalled => |s| switch (s) {
                .first_frame => try w.print("The webcam started but sent no video (nothing for {d} seconds)", .{Capture.first_frame_ms / 1000}),
                .frames => try w.print("The webcam stopped sending video (nothing for {d} seconds)", .{Capture.stall_ms / 1000}),
                .encoder => try w.print("The video encoder stopped (it took frames and gave nothing back for {d} seconds)", .{Capture.encoder_stall_ms / 1000}),
            },
            .encoder_misbehaved => |how| try w.print("The video encoder misbehaved: {s}", .{how}),
            .drain_stuck => |ms| try w.print("The video encoder didn't finish draining in {d} ms", .{ms}),
        }
    }

    /// The camera was busy (another app has it) or blocked (privacy settings): not this
    /// program's trouble.
    pub fn unavailable(p: Problem) bool {
        return switch (p) {
            .call => |c| c.hr == win32.E_ACCESSDENIED or c.hr == mf_e_video_recording_device_locked or c.hr == win32.MF_E_HW_MFT_FAILED_START_STREAMING,
            else => false,
        };
    }
};

/// MF_E_VIDEO_RECORDING_DEVICE_LOCKED: another app holds the camera.
const mf_e_video_recording_device_locked: win32.HRESULT = @bitCast(@as(u32, 0xC00D3EA3));

fn check(p: *Problem, hr: win32.HRESULT, what: []const u8) error{Failed}!void {
    if (!hr.failed) return;
    p.* = .{ .call = .{ .what = what, .hr = hr } };
    return error.Failed;
}

/// The size webcams are recorded at, at most: bigger costs disk and encoder time for little.
const max_width = 1920;
const max_height = 1080;

/// A webcam opened to deliver NV12 frames (what the encoders take), from its best native
/// format: the largest up to max_width x max_height, then the fastest. The source reader
/// converts formats that aren't NV12 (YUY2, MJPEG) on the way.
pub const Camera = struct {
    source: *win32.IMFMediaSource,
    reader: *win32.IMFSourceReader,
    /// The frames the reader gives: NV12.
    format: VideoFormat,
    /// What the camera sends, converted to `format` by the reader if it isn't that.
    native_subtype: win32.Guid,
    /// Gets the reader's frames (it reads asynchronously, see Capture).
    callback: *ReaderCallback,
    /// A read is under way: its result comes to the callback.
    reading: bool = false,

    /// With `gpu`, frames stay on it (D3D11 textures) and the reader converts formats there;
    /// without, frames come in system memory.
    pub fn open(symbolic_link: [:0]const u16, gpu: ?*const Gpu, callback: *ReaderCallback, p: *Problem) error{Failed}!Camera {
        var attrs: ?*win32.IMFAttributes = null;
        try check(p, win32.MFCreateAttributes(&attrs, 2), "Creating attributes");
        defer _ = attrs.?.IUnknown.Release();
        try check(p, attrs.?.SetGUID(&win32.MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, &win32.MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID), "Setting the source type");
        try check(p, attrs.?.SetString(&win32.MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, symbolic_link), "Setting the webcam");
        var source: ?*win32.IMFMediaSource = null;
        try check(p, win32.MFCreateDeviceSource(attrs, &source), "Opening the webcam");
        errdefer {
            _ = source.?.Shutdown();
            _ = source.?.IUnknown.Release();
        }

        var reader_attrs: ?*win32.IMFAttributes = null;
        try check(p, win32.MFCreateAttributes(&reader_attrs, 3), "Creating attributes");
        defer _ = reader_attrs.?.IUnknown.Release();
        try check(p, reader_attrs.?.SetUnknown(&win32.MF_SOURCE_READER_ASYNC_CALLBACK, &callback.iface.IUnknown), "Setting the webcam's reader to read asynchronously");
        if (gpu) |g| {
            try check(p, reader_attrs.?.SetUnknown(&win32.MF_SOURCE_READER_D3D_MANAGER, &g.manager.IUnknown), "Giving the webcam's reader the GPU");
            try check(p, reader_attrs.?.SetUINT32(&win32.MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, 1), "Enabling format conversion");
        } else {
            try check(p, reader_attrs.?.SetUINT32(&win32.MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, 1), "Enabling format conversion");
        }
        var reader: ?*win32.IMFSourceReader = null;
        try check(p, win32.MFCreateSourceReaderFromMediaSource(source, reader_attrs, &reader), "Creating the webcam's reader");
        errdefer _ = reader.?.IUnknown.Release();

        var best: ?VideoFormat = null;
        var best_index: u32 = 0;
        var index: u32 = 0;
        while (true) : (index += 1) {
            var media_type: ?*win32.IMFMediaType = null;
            const hr = reader.?.GetNativeMediaType(video_stream, index, &media_type);
            if (hr == win32.MF_E_NO_MORE_TYPES) break;
            try check(p, hr, "Listing the webcam's formats");
            defer _ = media_type.?.IUnknown.Release();
            const f: VideoFormat = .of(&media_type.?.IMFAttributes);
            if (!f.usable()) continue;
            if (best == null or f.better(best.?)) {
                best = f;
                best_index = index;
            }
        }
        const native = best orelse {
            p.* = .no_format;
            return error.Failed;
        };
        // The device's format first, as chosen: otherwise the reader picks one it can convert
        // from, maybe smaller or slower, and scales or repeats frames to what was asked.
        {
            var media_type: ?*win32.IMFMediaType = null;
            try check(p, reader.?.GetNativeMediaType(video_stream, best_index, &media_type), "Choosing the webcam's format");
            defer _ = media_type.?.IUnknown.Release();
            try check(p, reader.?.SetCurrentMediaType(video_stream, null, media_type), "Choosing the webcam's format");
        }
        // Then NV12 out of the reader, converted from it if it isn't already.
        var format = native;
        format.subtype = win32.MFVideoFormat_NV12;
        if (native.conversionCost() != 0) {
            const media_type = try format.mediaType(p);
            defer _ = media_type.IUnknown.Release();
            try check(p, reader.?.SetCurrentMediaType(video_stream, null, media_type), "Choosing the webcam's output format");
        }
        try checkDeviceFormat(source.?, native, p);
        return .{ .source = source.?, .reader = reader.?, .format = format, .native_subtype = native.subtype, .callback = callback };
    }

    /// The device runs at `want`: fails if the reader chose another native format.
    fn checkDeviceFormat(source: *win32.IMFMediaSource, want: VideoFormat, p: *Problem) error{Failed}!void {
        var pd: ?*win32.IMFPresentationDescriptor = null;
        try check(p, source.CreatePresentationDescriptor(&pd), "Checking the webcam's format");
        defer _ = pd.?.IUnknown.Release();
        var selected: win32.BOOL = 0;
        var sd: ?*win32.IMFStreamDescriptor = null;
        try check(p, pd.?.GetStreamDescriptorByIndex(0, &selected, &sd), "Checking the webcam's format");
        defer _ = sd.?.IUnknown.Release();
        var handler: ?*win32.IMFMediaTypeHandler = null;
        try check(p, sd.?.GetMediaTypeHandler(&handler), "Checking the webcam's format");
        defer _ = handler.?.IUnknown.Release();
        var current: ?*win32.IMFMediaType = null;
        try check(p, handler.?.GetCurrentMediaType(&current), "Checking the webcam's format");
        defer _ = current.?.IUnknown.Release();
        const got: VideoFormat = .of(&current.?.IMFAttributes);
        if (got.width != want.width or got.height != want.height or
            @as(u64, got.fps_num) * want.fps_den != @as(u64, want.fps_num) * got.fps_den or
            !std.mem.eql(u8, &got.subtype.Bytes, &want.subtype.Bytes))
        {
            p.* = .{ .device_format = .{ .want = want, .got = got } };
            return error.Failed;
        }
    }

    /// A read under way is flushed (its result, if any, comes to the callback, which keeps it)
    /// before the reader goes: waits at most flush_wait_ms for that.
    pub fn close(c: *Camera) void {
        if (c.reading) {
            if (!c.reader.Flush(all_streams).failed)
                _ = win32.WaitForSingleObject(c.callback.flushed_event, flush_wait_ms);
        }
        _ = c.reader.IUnknown.Release();
        _ = c.source.Shutdown();
        _ = c.source.IUnknown.Release();
        c.* = undefined;
    }

    const flush_wait_ms = 1000;
    const all_streams: u32 = @bitCast(@backingInt(win32.MF_SOURCE_READER_ALL_STREAMS));

    /// Asks the reader for the next frame: it comes to the callback (take).
    pub fn request(c: *Camera, p: *Problem) error{Failed}!void {
        std.debug.assert(!c.reading);
        try check(p, c.reader.ReadSample(video_stream, 0, null, null, null, null), "Reading from the webcam");
        c.reading = true;
    }

    /// The read's result, once the callback signalled it: a frame (the caller releases it),
    /// or null if it had none (a gap in the stream: read again). Fails if the read did, the
    /// stream ended, or the camera changed its format.
    pub fn take(c: *Camera, p: *Problem) error{Failed}!?Frame {
        const r = c.callback.take() orelse return null;
        c.reading = false;
        errdefer if (r.sample) |s| {
            _ = s.IUnknown.Release();
        };
        try check(p, r.hr, "Reading from the webcam");
        const flag = struct {
            fn has(flags: u32, f: win32.MF_SOURCE_READER_FLAG) bool {
                return flags & @as(u32, @bitCast(@backingInt(f))) != 0;
            }
        }.has;
        if (flag(r.flags, win32.MF_SOURCE_READERF_ERROR)) {
            p.* = .reader_error;
            return error.Failed;
        }
        if (flag(r.flags, win32.MF_SOURCE_READERF_ENDOFSTREAM)) {
            p.* = .ended;
            return error.Failed;
        }
        if (flag(r.flags, win32.MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) or flag(r.flags, win32.MF_SOURCE_READERF_NATIVEMEDIATYPECHANGED)) {
            p.* = .format_changed;
            return error.Failed;
        }
        // A gap in the stream (a stream tick) has no sample.
        const s = r.sample orelse {
            try c.request(p);
            return null;
        };
        return .{ .sample = s, .time = r.time };
    }
};

const video_stream: u32 = @bitCast(@backingInt(win32.MF_SOURCE_READER_FIRST_VIDEO_STREAM));

pub const Frame = struct {
    sample: *win32.IMFSample,
    /// When it was captured: the reader's timestamp, which is QPC in 100ns units (the
    /// recording's clock, and WASAPI's).
    time: i64,
};

/// An H.264 frame from the encoder: the caller copies `bytes` (Annex B) before the next call.
pub const Encoded = struct {
    bytes: []const u8,
    /// When it's shown (the input frame's time), 100ns units.
    time: i64,
    /// When it's decoded, 100ns units: the encoder's decode timestamp, or `time` when it gives
    /// none (it doesn't reorder frames).
    decode_time: i64,
    keyframe: bool,
    /// For a keyframe without its SPS and PPS (an encoder that sends them only at its start,
    /// or only in its output type): those, from its output type, to go before it. So every
    /// keyframe decodes on its own: a recording's first is mid-stream (forced when it starts).
    parameter_sets: []const u8 = &.{},
};

/// An H.264 encoder (Media Foundation transform) for one camera format: the best one
/// MFTEnumEx lists, hardware ones first. Hardware encoders are asynchronous (they ask for
/// input and announce output with events), software ones synchronous; both are driven from
/// the capture thread.
pub const Encoder = struct {
    transform: *win32.IMFTransform,
    mode: union(enum) {
        sync,
        async: Async,
    },
    /// The output sample we give the encoder each time, if it doesn't allocate its own
    /// (hardware ones do): its size. Null until started (readOutputInfo), and for those.
    own_output: ?struct { sample: *win32.IMFSample, size: u32 } = null,
    /// What made it: shut down with it (ShutdownObject), as Media Foundation asks of a
    /// hardware encoder's.
    activate: *win32.IMFActivate,
    /// Its settings: rate, keyframes.
    codec: *win32.ICodecAPI,
    /// A frame's nominal duration, 100ns units, for frames that come without one.
    frame_duration: i64 = 0,
    name_buf: [128]u8 = undefined,
    name_len: usize = 0,
    hardware: bool,
    /// The GPU it runs on, if it's a hardware one: see encoderAdapter.
    adapter: ?Gpu.Adapter = null,
    /// How much later than its frames' times the encoder says they're shown: Windows' software
    /// encoder, making B-frames, says a frame later (its reorder delay), and still after a
    /// drain (it carries on the same stream); others nothing. Taken off the times it gives, so
    /// each frame is placed at the time it was captured. Measured on its first frame, a
    /// keyframe decoded and shown first: the time it went in (first_input) against the time
    /// the encoder gives it. Null until then.
    shift: ?i64 = null,
    first_input: ?i64 = null,
    /// Its output type's sequence header (SPS and PPS, Annex B), for keyframes without them
    /// (see Encoded.parameter_sets): the most the muxer takes of each, with start codes.
    sequence_header_buf: [2 * (4 + mp4.max_parameter_set)]u8 = undefined,

    const Async = struct {
        events: *win32.IMFMediaEventGenerator,
        /// Inputs it asked for and hasn't had.
        need_input: u32 = 0,
        /// Draining since (QPC, 100ns units), until METransformDrainComplete.
        draining_since: ?u64 = null,
    };

    /// The adapter a hardware encoder is on, when there may be more than one: the one it says
    /// (MFT_ENUM_ADAPTER_LUID, set only when encoders are listed per adapter, so not by
    /// MFTEnumEx), else its vendor's first. Intel's encoder refuses a device on another
    /// vendor's GPU (E_INVALIDARG), so on a machine with an NVIDIA GPU too, the default
    /// adapter won't do. Microsoft's DX12 encoder says Microsoft's vendor (VEN_1414), which
    /// is the software adapter's (Basic Render Driver): it runs on the default adapter.
    fn encoderAdapter(attrs: *win32.IMFAttributes) ?Gpu.Adapter {
        var l: win32.LUID = undefined;
        var size: u32 = 0;
        if (!attrs.GetBlob(&win32.MFT_ENUM_ADAPTER_LUID, @ptrCast(&l), @sizeOf(win32.LUID), &size).failed and size == @sizeOf(win32.LUID))
            return .{ .luid = l };
        if (!hasAttr(attrs, &win32.MFT_ENUM_HARDWARE_VENDOR_ID_Attribute)) return null;
        var buf: [64]u8 = undefined;
        const vendor = parseVendor(attrString(attrs, &win32.MFT_ENUM_HARDWARE_VENDOR_ID_Attribute, &buf)) orelse return null;
        return if (vendor == microsoft_vendor) null else .{ .vendor = vendor };
    }

    const microsoft_vendor = 0x1414;

    /// The best encoder, not yet started (see start). If it takes D3D11 textures (hardware
    /// ones do), `gpu` is a device on its adapter, given to it: frames go to it without
    /// leaving the GPU.
    pub fn create(gpu: *?Gpu, p: *Problem) error{Failed}!Encoder {
        return createAt(0, gpu, p);
    }

    /// The `index`th encoder MFTEnumEx lists (best first). Only the best is used for
    /// recording (create); the tests try the others too.
    fn createAt(index: usize, gpu: *?Gpu, p: *Problem) error{Failed}!Encoder {
        var encoders: Activates = .enumH264Encoders();
        defer encoders.deinit();
        if (encoders.items.len <= index) {
            p.* = .no_encoder;
            return error.Failed;
        }
        const activate = encoders.items[index];
        const activate_attrs = &activate.IMFAttributes;
        var e: Encoder = .{ .transform = undefined, .mode = .sync, .activate = activate, .codec = undefined, .hardware = hasAttr(activate_attrs, &win32.MFT_ENUM_HARDWARE_VENDOR_ID_Attribute) };
        e.name_len = attrString(activate_attrs, &win32.MFT_FRIENDLY_NAME_Attribute, &e.name_buf).len;
        const adapter = encoderAdapter(activate_attrs);
        e.adapter = adapter;
        try check(p, activate.ActivateObject(win32.IID_IMFTransform, @ptrCast(&e.transform)), "Starting the H.264 encoder");
        errdefer _ = e.transform.IUnknown.Release();
        errdefer _ = activate.ShutdownObject();
        // Ours too: `encoders` releases its own reference.
        _ = activate.IUnknown.AddRef();
        errdefer _ = activate.IUnknown.Release();
        try check(p, e.transform.IUnknown.QueryInterface(win32.IID_ICodecAPI, @ptrCast(&e.codec)), "Configuring the encoder");
        errdefer _ = e.codec.IUnknown.Release();

        var attrs: ?*win32.IMFAttributes = null;
        try check(p, e.transform.GetAttributes(&attrs), "Reading the encoder's attributes");
        defer _ = attrs.?.IUnknown.Release();
        var is_async: u32 = 0;
        _ = attrs.?.GetUINT32(&win32.MF_TRANSFORM_ASYNC, &is_async);
        if (is_async != 0) {
            try check(p, attrs.?.SetUINT32(&win32.MF_TRANSFORM_ASYNC_UNLOCK, 1), "Unlocking the encoder");
            var events: *win32.IMFMediaEventGenerator = undefined;
            try check(p, e.transform.IUnknown.QueryInterface(win32.IID_IMFMediaEventGenerator, @ptrCast(&events)), "Getting the encoder's events");
            e.mode = .{ .async = .{ .events = events } };
        }
        errdefer switch (e.mode) {
            .sync => {},
            .async => |a| _ = a.events.IUnknown.Release(),
        };
        var d3d11_aware: u32 = 0;
        _ = attrs.?.GetUINT32(&win32.MF_SA_D3D11_AWARE, &d3d11_aware);
        if (d3d11_aware != 0) {
            gpu.* = try .init(adapter, p);
            errdefer {
                gpu.*.?.deinit();
                gpu.* = null;
            }
            try check(p, e.transform.ProcessMessage(win32.MFT_MESSAGE_SET_D3D_MANAGER, @intFromPtr(gpu.*.?.manager)), "Giving the encoder the GPU");
        }
        return e;
    }

    /// Sets the encoder up for frames of `format`, and starts it.
    pub fn start(e: *Encoder, format: VideoFormat, p: *Problem) error{Failed}!void {
        e.frame_duration = @intCast(@as(u64, 10_000_000) * format.fps_den / format.fps_num);
        // Settings before the types: some encoders fix them once the types are set.
        try e.configure(format, p);

        const output = try format.h264Type(p);
        defer _ = output.IUnknown.Release();
        try check(p, e.transform.SetOutputType(0, output, 0), "Setting the encoder's output");
        const input = try format.mediaType(p);
        defer _ = input.IUnknown.Release();
        try check(p, e.transform.SetInputType(0, input, 0), "Setting the encoder's input");

        try e.readOutputInfo(p);
        try check(p, e.transform.ProcessMessage(win32.MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0), "Starting the encoder");
        try check(p, e.transform.ProcessMessage(win32.MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0), "Starting the encoder");
    }

    pub fn name(e: *const Encoder) []const u8 {
        return e.name_buf[0..e.name_len];
    }

    /// Whether the encoder gives its own output samples, and if not, one of the size it
    /// wants: after the types are set, and again when it changes its output type.
    fn readOutputInfo(e: *Encoder, p: *Problem) error{Failed}!void {
        var info: win32.MFT_OUTPUT_STREAM_INFO = undefined;
        try check(p, e.transform.GetOutputStreamInfo(0, &info), "Reading the encoder's output");
        if (info.dwFlags & @as(u32, @bitCast(@backingInt(win32.MFT_OUTPUT_STREAM_PROVIDES_SAMPLES))) != 0) {
            e.releaseOwnOutput();
            return;
        }
        if (info.cbSize == 0) {
            p.* = .{ .encoder_misbehaved = "it gave no size for its output" };
            return error.Failed;
        }
        if (e.own_output) |o| if (info.cbSize <= o.size) return;
        var sample: ?*win32.IMFSample = null;
        try check(p, win32.MFCreateSample(&sample), "Creating a sample");
        errdefer _ = sample.?.IUnknown.Release();
        var buffer: ?*win32.IMFMediaBuffer = null;
        try check(p, win32.MFCreateMemoryBuffer(info.cbSize, &buffer), "Creating a buffer");
        defer _ = buffer.?.IUnknown.Release();
        try check(p, sample.?.AddBuffer(buffer), "Creating a sample");
        e.releaseOwnOutput();
        e.own_output = .{ .sample = sample.?, .size = info.cbSize };
    }

    fn releaseOwnOutput(e: *Encoder) void {
        if (e.own_output) |o| _ = o.sample.IUnknown.Release();
        e.own_output = null;
    }

    /// Rate and keyframes. Otherwise the encoder's own defaults, for the best video for the
    /// bits: not its low latency mode (nothing here needs frames sooner), and B-frames if it
    /// makes them (frames come out in any order, each with its decode time, see Encoded). A
    /// keyframe every two seconds: where the files can be cut and recovered from.
    fn configure(e: *Encoder, format: VideoFormat, p: *Problem) error{Failed}!void {
        const codec = e.codec;
        try setCodecValue(codec, win32.CLSID_CODECAPI_AVEncMPVGOPSize, .u32, format.keyframeInterval(), p, "Setting the encoder's keyframe interval");
        try setCodecValue(codec, win32.CLSID_CODECAPI_AVEncCommonRateControlMode, .u32, @intCast(@intFromEnum(win32.eAVEncCommonRateControlMode.PeakConstrainedVBR)), p, "Setting the encoder's rate control");
        try setCodecValue(codec, win32.CLSID_CODECAPI_AVEncCommonMeanBitRate, .u32, format.bitrate(), p, "Setting the encoder's bitrate");
        // The peak for peak-constrained rate control: twice the mean, for a keyframe or a
        // burst of motion.
        try setCodecValue(codec, win32.CLSID_CODECAPI_AVEncCommonMaxBitRate, .u32, @intCast(@min(std.math.maxInt(u32), @as(u64, format.bitrate()) * 2)), p, "Setting the encoder's peak bitrate");
        // Asked for when a recording starts (forceKeyframe): checked now, so an encoder that
        // can't fails when the webcam is added, not when recording starts.
        try check(p, codec.IsSupported(win32.CLSID_CODECAPI_AVEncVideoForceKeyFrame), "Checking the encoder makes keyframes on request");
    }

    /// The next frame encoded is a keyframe.
    pub fn forceKeyframe(e: *Encoder, p: *Problem) error{Failed}!void {
        try setCodecValue(e.codec, win32.CLSID_CODECAPI_AVEncVideoForceKeyFrame, .u32, 1, p, "Asking the encoder for a keyframe");
    }

    pub fn isDraining(e: *const Encoder) bool {
        return switch (e.mode) {
            .sync => false,
            .async => |a| a.draining_since != null,
        };
    }

    /// Everything the encoder holds, out to `sink`; then it takes frames again. An async
    /// encoder is waited for at most drain_wait_ms: if it's slower, it stays draining (see
    /// isDraining), refusing frames (encode returns false: gaps) until it's done
    /// (pumpEvents), or fails if that takes over drain_stuck_ms. Asked again while it's still
    /// draining, it's waited for again (the frames it holds are still to come).
    pub fn drain(e: *Encoder, sink: anytype, p: *Problem) error{Failed}!void {
        switch (e.mode) {
            .sync => {
                try check(p, e.transform.ProcessMessage(win32.MFT_MESSAGE_COMMAND_DRAIN, 0), "Draining the encoder");
                while (try e.takeOutput(sink, p) != .none) {}
            },
            .async => |*a| {
                const since = record.qpc100ns();
                if (a.draining_since == null) {
                    try check(p, e.transform.ProcessMessage(win32.MFT_MESSAGE_COMMAND_DRAIN, 0), "Draining the encoder");
                    a.draining_since = since;
                }
                while (a.draining_since != null and record.qpc100ns() - since < drain_wait_ms * 10_000) {
                    try e.pumpEvents(sink, p);
                    if (a.draining_since != null) win32.Sleep(1);
                }
            },
        }
    }

    const drain_wait_ms = 300;
    /// An async encoder still draining this long after it was asked has stopped answering.
    const drain_stuck_ms = 2000;

    pub fn destroy(e: *Encoder) void {
        _ = e.transform.ProcessMessage(win32.MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
        _ = e.codec.IUnknown.Release();
        e.releaseOwnOutput();
        switch (e.mode) {
            .sync => {},
            .async => |a| _ = a.events.IUnknown.Release(),
        }
        _ = e.transform.IUnknown.Release();
        // Async encoders hold a reference to themselves until shut down: their activate does
        // it, whether or not the encoder itself has IMFShutdown.
        _ = e.activate.ShutdownObject();
        _ = e.activate.IUnknown.Release();
        e.* = undefined;
    }

    /// Encodes a frame, calling `sink.encoded(Encoded)` for each frame that comes out (now or
    /// for earlier frames). Returns false if an async encoder wasn't ready for it: the frame is
    /// dropped, the caller counts it.
    pub fn encode(e: *Encoder, frame: Frame, sink: anytype, p: *Problem) error{Failed}!bool {
        switch (e.mode) {
            .sync => {},
            .async => |*a| {
                try e.pumpEvents(sink, p);
                if (a.draining_since) |since| {
                    if (record.qpc100ns() - since >= drain_stuck_ms * 10_000) {
                        p.* = .{ .drain_stuck = drain_stuck_ms };
                        return error.Failed;
                    }
                    return false;
                }
                if (a.need_input == 0) return false;
                a.need_input -= 1;
            },
        }
        try check(p, frame.sample.SetSampleTime(frame.time), "Timing a frame");
        // Encoders may want a duration (the software one does after a drain): the camera's
        // frames have one, otherwise the nominal one.
        var duration: i64 = 0;
        if (frame.sample.GetSampleDuration(&duration).failed or duration <= 0)
            try check(p, frame.sample.SetSampleDuration(e.frame_duration), "Timing a frame");
        try check(p, e.transform.ProcessInput(0, frame.sample, 0), "Encoding a frame");
        if (e.shift == null and e.first_input == null) e.first_input = frame.time;
        switch (e.mode) {
            .sync => while (try e.takeOutput(sink, p) != .none) {},
            .async => try e.pumpEvents(sink, p),
        }
        return true;
    }

    /// Handles an async encoder's events so far, without waiting.
    fn pumpEvents(e: *Encoder, sink: anytype, p: *Problem) error{Failed}!void {
        const a = &e.mode.async;
        while (true) {
            var event: ?*win32.IMFMediaEvent = null;
            const hr = a.events.GetEvent(win32.MF_EVENT_FLAG_NO_WAIT, &event);
            if (hr == win32.MF_E_NO_EVENTS_AVAILABLE) return;
            try check(p, hr, "Reading the encoder's events");
            defer _ = event.?.IUnknown.Release();
            var status: win32.HRESULT = undefined;
            try check(p, event.?.GetStatus(&status), "Reading the encoder's events");
            try check(p, status, "Encoding");
            var kind: u32 = 0;
            try check(p, event.?.GetType(&kind), "Reading the encoder's events");
            if (kind == @backingInt(win32.METransformNeedInput)) {
                a.need_input += 1;
            } else if (kind == @backingInt(win32.METransformHaveOutput)) {
                // One output per event. A stream change answers it too: the encoder sends
                // another when the frame is ready in the new type.
                if (try e.takeOutput(sink, p) == .none) {
                    p.* = .{ .encoder_misbehaved = "it said it had output, then had none" };
                    return error.Failed;
                }
            } else if (kind == @backingInt(win32.METransformDrainComplete)) {
                a.draining_since = null;
                // Input it asked for before (or while draining) isn't wanted any more: it asks
                // again after, and input without asking is refused (MF_E_NOTACCEPTING).
                a.need_input = 0;
                // Drained, an async encoder waits for a new stream before it asks for input
                // again (the Qualcomm one does; found by the encoder test).
                try check(p, e.transform.ProcessMessage(win32.MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0), "Restarting the encoder after draining");
            }
        }
    }

    /// The SPS and PPS its output type has (MF_MT_MPEG_SEQUENCE_HEADER), or none: then a
    /// keyframe without them fails at the muxer (BadStream), saying the video can't be stored.
    fn sequenceHeader(e: *Encoder, p: *Problem) error{Failed}![]const u8 {
        var t: ?*win32.IMFMediaType = null;
        try check(p, e.transform.GetOutputCurrentType(0, &t), "Reading the encoder's output type");
        defer _ = t.?.IUnknown.Release();
        var size: u32 = 0;
        {
            const hr = t.?.IMFAttributes.GetBlobSize(&win32.MF_MT_MPEG_SEQUENCE_HEADER, &size);
            if (hr == win32.MF_E_ATTRIBUTENOTFOUND) return &.{};
            try check(p, hr, "Reading the encoder's sequence header");
        }
        if (size > e.sequence_header_buf.len) {
            p.* = .{ .encoder_misbehaved = "its sequence header (SPS and PPS) is longer than the recording takes" };
            return error.Failed;
        }
        // (zigwin32 declares the buffer [*:0]u8; a blob has no terminator.)
        try check(p, t.?.IMFAttributes.GetBlob(&win32.MF_MT_MPEG_SEQUENCE_HEADER, @ptrCast(&e.sequence_header_buf), e.sequence_header_buf.len, &size), "Reading the encoder's sequence header");
        return e.sequence_header_buf[0..size];
    }

    const Output = enum {
        /// A frame went to the sink.
        taken,
        /// None ready.
        none,
        /// The encoder changed its output type: the frame comes next time.
        changed,
    };

    /// Takes one encoded frame to `sink`, if there is one.
    fn takeOutput(e: *Encoder, sink: anytype, p: *Problem) error{Failed}!Output {
        const own: ?*win32.IMFSample = if (e.own_output) |o| o.sample else null;
        var out = [1]win32.MFT_OUTPUT_DATA_BUFFER{.{ .dwStreamID = 0, .pSample = own, .dwStatus = 0, .pEvents = null }};
        if (own) |s| {
            var buffer: ?*win32.IMFMediaBuffer = null;
            try check(p, s.GetBufferByIndex(0, &buffer), "Reading an encoded frame");
            defer _ = buffer.?.IUnknown.Release();
            try check(p, buffer.?.SetCurrentLength(0), "Reading an encoded frame");
        }
        var status: u32 = 0;
        const hr = e.transform.ProcessOutput(0, 1, &out, &status);
        if (out[0].pEvents) |ev| _ = ev.IUnknown.Release();
        if (hr == win32.MF_E_TRANSFORM_NEED_MORE_INPUT) return .none;
        if (hr == win32.MF_E_TRANSFORM_STREAM_CHANGE) {
            // The encoder changed its output type (some do once, at the start): take the
            // new one as it is. A sync encoder is asked again (by the caller's loop); an async
            // one sends another METransformHaveOutput.
            var t: ?*win32.IMFMediaType = null;
            try check(p, e.transform.GetOutputAvailableType(0, 0, &t), "Renegotiating the encoder's output");
            defer _ = t.?.IUnknown.Release();
            try check(p, e.transform.SetOutputType(0, t, 0), "Renegotiating the encoder's output");
            try e.readOutputInfo(p);
            return .changed;
        }
        try check(p, hr, "Taking an encoded frame");
        const sample = out[0].pSample orelse {
            p.* = .{ .encoder_misbehaved = "it gave no sample for its output" };
            return error.Failed;
        };
        // Its own, given to us: ours to release.
        defer if (own == null) {
            _ = sample.IUnknown.Release();
        };
        var time: i64 = 0;
        try check(p, sample.GetSampleTime(&time), "Timing an encoded frame");
        var clean: u32 = 0;
        _ = sample.IMFAttributes.GetUINT32(&win32.MFSampleExtension_CleanPoint, &clean);
        // Encoders that reorder frames say when each is decoded (Windows' software one does,
        // and NVIDIA's even though it doesn't reorder). One that says nothing decodes frames
        // when they're shown.
        var decode_time: u64 = undefined;
        {
            const got = sample.IMFAttributes.GetUINT64(&win32.MFSampleExtension_DecodeTimestamp, &decode_time);
            if (got == win32.MF_E_ATTRIBUTENOTFOUND) {
                decode_time = @bitCast(time);
            } else try check(p, got, "Reading an encoded frame's decode time");
        }
        const shift = e.shift orelse blk: {
            const first = e.first_input orelse {
                p.* = .{ .encoder_misbehaved = "it gave a frame before taking one" };
                return error.Failed;
            };
            e.shift = time - first;
            break :blk e.shift.?;
        };
        time -= shift;
        decode_time = @bitCast(@as(i64, @bitCast(decode_time)) - shift);
        var buffer: ?*win32.IMFMediaBuffer = null;
        try check(p, sample.ConvertToContiguousBuffer(&buffer), "Reading an encoded frame");
        defer _ = buffer.?.IUnknown.Release();
        var data: ?*u8 = null;
        var len: u32 = 0;
        try check(p, buffer.?.Lock(&data, null, &len), "Reading an encoded frame");
        defer _ = buffer.?.Unlock();
        const bytes = @as([*]const u8, @ptrCast(data.?))[0..len];
        const parameter_sets = if (clean != 0 and !hasSps(bytes)) try e.sequenceHeader(p) else &.{};
        try sink.encoded(.{ .bytes = bytes, .time = time, .decode_time = @bitCast(decode_time), .keyframe = clean != 0, .parameter_sets = parameter_sets }, p);
        return .taken;
    }
};

/// A D3D11 device and its Media Foundation manager, shared by a webcam's reader and encoder so
/// frames go from one to the other as textures, never copied through system memory.
pub const Gpu = struct {
    device: *win32.ID3D11Device,
    manager: *win32.IMFDXGIDeviceManager,

    /// Which adapter: the encoder's, by its LUID or else its vendor's first.
    pub const Adapter = union(enum) { luid: win32.LUID, vendor: u32 };

    /// On `want` (the encoder's adapter), or the default one.
    fn init(want_adapter: ?Adapter, p: *Problem) error{Failed}!Gpu {
        var adapter: ?*win32.IDXGIAdapter1 = null;
        defer if (adapter) |a| {
            _ = a.IUnknown.Release();
        };
        if (want_adapter) |want| {
            var factory: *win32.IDXGIFactory1 = undefined;
            try check(p, win32.CreateDXGIFactory1(win32.IID_IDXGIFactory1, @ptrCast(&factory)), "Listing the GPUs");
            defer _ = factory.IUnknown.Release();
            var i: u32 = 0;
            while (true) : (i += 1) {
                var a: *win32.IDXGIAdapter1 = undefined;
                const hr = factory.EnumAdapters1(i, &a);
                if (hr == win32.DXGI_ERROR_NOT_FOUND) {
                    p.* = .{ .call = .{ .what = "Finding the encoder's GPU", .hr = hr } };
                    return error.Failed;
                }
                try check(p, hr, "Listing the GPUs");
                var desc: win32.DXGI_ADAPTER_DESC = undefined;
                const desc_hr = a.IDXGIAdapter.GetDesc(&desc);
                const match = !desc_hr.failed and switch (want) {
                    .luid => |l| desc.AdapterLuid.LowPart == l.LowPart and desc.AdapterLuid.HighPart == l.HighPart,
                    .vendor => |v| desc.VendorId == v,
                };
                if (match) {
                    adapter = a;
                    break;
                }
                _ = a.IUnknown.Release();
                try check(p, desc_hr, "Listing the GPUs");
            }
        }
        var device: *win32.ID3D11Device = undefined;
        try check(p, win32.D3D11CreateDevice(
            if (adapter) |a| &a.IDXGIAdapter else null,
            // With an adapter given, the driver type must be UNKNOWN.
            if (adapter != null) .UNKNOWN else .HARDWARE,
            null,
            win32.D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
            null,
            0,
            win32.D3D11_SDK_VERSION,
            &device,
            null,
            null,
        ), "Opening the GPU");
        errdefer _ = device.IUnknown.Release();
        // Media Foundation uses the device from its own threads.
        var mt: *win32.ID3D10Multithread = undefined;
        try check(p, device.IUnknown.QueryInterface(win32.IID_ID3D10Multithread, @ptrCast(&mt)), "Opening the GPU");
        _ = mt.SetMultithreadProtected(1);
        _ = mt.IUnknown.Release();
        var token: u32 = 0;
        var manager: ?*win32.IMFDXGIDeviceManager = null;
        try check(p, win32.MFCreateDXGIDeviceManager(&token, &manager), "Sharing the GPU");
        errdefer _ = manager.?.IUnknown.Release();
        try check(p, manager.?.ResetDevice(&device.IUnknown, token), "Sharing the GPU");
        return .{ .device = device, .manager = manager.? };
    }

    pub fn deinit(g: *Gpu) void {
        _ = g.manager.IUnknown.Release();
        _ = g.device.IUnknown.Release();
        g.* = undefined;
    }
};

const CodecValue = enum { u32, bool };

fn setCodecValue(codec: *win32.ICodecAPI, api: *const win32.Guid, kind: CodecValue, value: u32, p: *Problem, what: []const u8) error{Failed}!void {
    var v: win32.VARIANT = std.mem.zeroes(win32.VARIANT);
    switch (kind) {
        .u32 => {
            v.Anonymous.Anonymous.vt = win32.VT_UI4;
            v.Anonymous.Anonymous.Anonymous.ulVal = value;
        },
        .bool => {
            v.Anonymous.Anonymous.vt = win32.VT_BOOL;
            v.Anonymous.Anonymous.Anonymous.boolVal = if (value != 0) -1 else 0;
        },
    }
    try check(p, codec.SetValue(api, &v), what);
}

/// An array of IMFActivate that Media Foundation allocated: released and freed together.
const Activates = struct {
    items: []*win32.IMFActivate,

    fn enumDevices() Activates {
        var attrs: ?*win32.IMFAttributes = null;
        {
            const hr = win32.MFCreateAttributes(&attrs, 1);
            if (hr.failed) win32.panicHresult("MFCreateAttributes", hr);
        }
        defer _ = attrs.?.IUnknown.Release();
        {
            const hr = attrs.?.SetGUID(&win32.MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, &win32.MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
            if (hr.failed) win32.panicHresult("IMFAttributes.SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE)", hr);
        }
        var array: ?[*]*win32.IMFActivate = null;
        var count: u32 = 0;
        const hr = win32.MFEnumDeviceSources(attrs, @ptrCast(&array), &count);
        if (hr.failed) win32.panicHresult("MFEnumDeviceSources", hr);
        return .{ .items = if (array) |a| a[0..count] else &.{} };
    }

    /// Hardware encoders first: MFT_ENUM_FLAG_SORTANDFILTER puts them ahead of software ones.
    fn enumH264Encoders() Activates {
        const output: win32.MFT_REGISTER_TYPE_INFO = .{ .guidMajorType = win32.MFMediaType_Video, .guidSubtype = win32.MFVideoFormat_H264 };
        var array: ?[*]*win32.IMFActivate = null;
        var count: u32 = 0;
        const hr = win32.MFTEnumEx(
            win32.MFT_CATEGORY_VIDEO_ENCODER,
            .{ .SYNCMFT = 1, .ASYNCMFT = 1, .HARDWARE = 1, .LOCALMFT = 1, .SORTANDFILTER = 1 },
            null,
            &output,
            @ptrCast(&array),
            &count,
        );
        if (hr.failed) win32.panicHresult("MFTEnumEx(H.264 encoders)", hr);
        return .{ .items = if (array) |a| a[0..count] else &.{} };
    }

    fn deinit(a: *Activates) void {
        for (a.items) |activate| _ = activate.IUnknown.Release();
        win32.CoTaskMemFree(if (a.items.len == 0) null else @ptrCast(a.items.ptr));
        a.* = undefined;
    }
};

fn mfStartup() void {
    const hr = win32.MFStartup(win32.MF_VERSION, win32.MFSTARTUP_FULL);
    if (hr.failed) win32.panicHresult("MFStartup", hr);
}

fn mfShutdown() void {
    const hr = win32.MFShutdown();
    if (hr.failed) win32.panicHresult("MFShutdown", hr);
}

fn hasAttr(attrs: *win32.IMFAttributes, key: *const win32.Guid) bool {
    var len: u32 = 0;
    return !attrs.GetStringLength(key, &len).failed;
}

fn attrU64(attrs: *win32.IMFAttributes, key: *const win32.Guid, comptime what: []const u8) u64 {
    var value: u64 = 0;
    const hr = attrs.GetUINT64(key, &value);
    if (hr.failed) win32.panicHresult("IMFAttributes.GetUINT64(" ++ what ++ ")", hr);
    return value;
}

/// A string attribute as UTF-8 in `buf`, cut to fit.
fn attrString(attrs: *win32.IMFAttributes, key: *const win32.Guid, buf: []u8) []const u8 {
    var wide: ?[*:0]u16 = null;
    var len: u32 = 0;
    const hr = attrs.GetAllocatedString(key, &wide, &len);
    if (hr.failed) win32.panicHresult("IMFAttributes.GetAllocatedString", hr);
    defer win32.CoTaskMemFree(wide);
    var out: usize = 0;
    var it = std.unicode.Wtf16LeIterator.init(wide.?[0..len]);
    while (it.nextCodepoint()) |cp| {
        var enc: [4]u8 = undefined;
        const n = std.unicode.wtf8Encode(cp, &enc) catch unreachable;
        if (out + n > buf.len) break;
        @memcpy(buf[out..][0..n], enc[0..n]);
        out += n;
    }
    return buf[0..out];
}

test "the reader's callback hands over each read's result, and is freed with its last reference" {
    const cb = ReaderCallback.create(std.testing.allocator);
    // The reader takes a reference, as it would.
    var unknown: *anyopaque = undefined;
    try std.testing.expectEqual(win32.S_OK, cb.iface.IUnknown.QueryInterface(win32.IID_IMFSourceReaderCallback, &unknown));
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&cb.iface)), unknown);
    try std.testing.expectEqual(win32.E_NOINTERFACE, cb.iface.IUnknown.QueryInterface(win32.IID_IMFSample, &unknown));
    try std.testing.expectEqual(null, cb.take());
    // A read ends (a gap: no sample): the event is set, and the result is there once.
    try std.testing.expectEqual(win32.S_OK, cb.iface.OnReadSample(.fromInt(0), 0, 256, 12345, null));
    try std.testing.expectEqual(0, @backingInt(win32.WaitForSingleObject(cb.event, 0)));
    const r = cb.take().?;
    try std.testing.expectEqual(256, r.flags);
    try std.testing.expectEqual(12345, r.time);
    try std.testing.expectEqual(null, cb.take());
    try std.testing.expectEqual(win32.S_OK, cb.iface.OnFlush(0));
    try std.testing.expectEqual(0, @backingInt(win32.WaitForSingleObject(cb.flushed_event, 0)));
    // With a frame: the callback keeps a reference until it's taken, and one left untaken
    // goes with the callback.
    if (!win32.MFStartup(win32.MF_VERSION, win32.MFSTARTUP_FULL).failed) {
        defer mfShutdown();
        var sample: ?*win32.IMFSample = null;
        try std.testing.expect(!win32.MFCreateSample(&sample).failed);
        const refs = struct {
            fn of(x: *win32.IMFSample) u32 {
                _ = x.IUnknown.AddRef();
                return x.IUnknown.Release();
            }
        }.of;
        try std.testing.expectEqual(1, refs(sample.?));
        _ = cb.iface.OnReadSample(.fromInt(0), 0, 0, 1, sample);
        try std.testing.expectEqual(2, refs(sample.?));
        const taken = cb.take().?;
        try std.testing.expectEqual(sample.?, taken.sample.?);
        _ = taken.sample.?.IUnknown.Release();
        try std.testing.expectEqual(1, refs(sample.?));
        // Left untaken when the callback goes.
        _ = cb.iface.OnReadSample(.fromInt(0), 0, 0, 2, sample);
        try std.testing.expectEqual(2, refs(sample.?));
        cb.release();
        try std.testing.expectEqual(0, cb.iface.IUnknown.Release());
        try std.testing.expectEqual(1, refs(sample.?));
        _ = sample.?.IUnknown.Release();
        return;
    }
    // Ours goes first, then the reader's: freed then (the testing allocator says if not).
    cb.release();
    try std.testing.expectEqual(0, cb.iface.IUnknown.Release());
}

test "waiting for a webcam's drain ends when its thread has exited" {
    var c: Capture = .{
        .id = 1,
        .symbolic_link = undefined,
        .hwnd = undefined,
        .thread = undefined,
        .gpa = std.testing.allocator,
        .stop_event = createEvent(true),
        .exited_event = createEvent(true),
        .drain_event = createEvent(false),
        .drained_event = createEvent(false),
    };
    defer for ([_]win32.HANDLE{ c.stop_event, c.drain_event, c.drained_event, c.exited_event }) |h| win32.closeHandle(h);
    // Not live, or no recorder: nothing to drain, nothing to wait for.
    c.requestDrain();
    try std.testing.expect(!c.drain_requested.load(.acquire));
    // Asked while live, the thread then failing: the wait ends at once, not at its deadline.
    var recorder: record.AudioPoolSource = undefined;
    c.recorder = .{ .source = &recorder, .start = 0 };
    c.state = .{ .live = undefined };
    c.requestDrain();
    try std.testing.expect(c.drain_requested.load(.acquire));
    _ = win32.SetEvent(c.exited_event);
    const start = record.qpc100ns();
    c.waitDrained(Capture.drainDeadline());
    try std.testing.expect(record.qpc100ns() - start < Capture.drain_wait_ms * 10_000 / 2);
    try std.testing.expect(!c.drain_requested.load(.acquire));
}

test "a webcam's capture starts, and stops at once" {
    {
        const hr = win32.CoInitializeEx(null, win32.COINIT_MULTITHREADED);
        if (hr.failed) return error.SkipZigTest;
    }
    defer win32.CoUninitialize();
    if (win32.MFStartup(win32.MF_VERSION, win32.MFSTARTUP_FULL).failed) return error.SkipZigTest;
    defer mfShutdown();
    // The first webcam, if there is one.
    var devices: Activates = .enumDevices();
    defer devices.deinit();
    if (devices.items.len == 0) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const id = allocAttrString(gpa, &devices.items[0].IMFAttributes, &win32.MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK);
    defer gpa.free(id);
    // Somewhere for its status messages.
    const hwnd = win32.CreateWindowExW(.{}, win32.L("Message"), null, .{}, 0, 0, 0, 0, win32.HWND_MESSAGE, null, null, null) orelse
        win32.panicWin32("CreateWindowEx(message-only)", win32.GetLastError());
    defer _ = win32.DestroyWindow(hwnd);

    const c = Capture.create(gpa, 1, id, hwnd);
    var destroyed = false;
    defer if (!destroyed) c.destroy(gpa);
    // Live within the first frame's allowance (opening a camera can take a few seconds).
    const deadline = record.qpc100ns() + Capture.first_frame_ms * 10_000;
    while (true) {
        const state = blk: {
            c.state_lock.lock();
            defer c.state_lock.unlock();
            break :blk c.state;
        };
        switch (state) {
            .starting => {
                try std.testing.expect(record.qpc100ns() < deadline);
                win32.Sleep(10);
            },
            .live => |l| {
                try std.testing.expect(l.format.width > 0 and l.encoder_len > 0);
                break;
            },
            .failed => |f| {
                std.debug.print("webcam failed to start: {s}\n", .{f.message.slice()});
                // Another app holding it, or camera access blocked: nothing to test here.
                // Anything else is a failure.
                if (f.unavailable) return error.SkipZigTest;
                return error.TestUnexpectedResult;
            },
        }
    }
    // Frames come, through the encoder, within the first frame's allowance.
    while (c.counts.encoded.load(.monotonic) < 5) {
        try std.testing.expect(c.isLive());
        try std.testing.expect(record.qpc100ns() < deadline + Capture.first_frame_ms * 10_000);
        win32.Sleep(10);
    }
    // Stopping doesn't wait for the camera: it used to wait forever (a read that couldn't be
    // woken), which hung quitting. Closing the camera takes a few hundred milliseconds.
    const start = record.qpc100ns();
    destroyed = true;
    c.destroy(gpa);
    const ms = (record.qpc100ns() - start) / 10_000;
    errdefer std.debug.print("stopping took {d} ms\n", .{ms});
    try std.testing.expect(ms < 1000);
}

test "format choice: smooth first, then bigger, faster, and cheaper to convert" {
    const nv12 = win32.MFVideoFormat_NV12;
    var mjpg = win32.MFVideoFormat_NV12;
    mjpg.Ints.a = std.mem.readInt(u32, "MJPG", .little);
    const f1080_5: VideoFormat = .{ .subtype = nv12, .width = 1920, .height = 1080, .fps_num = 5, .fps_den = 1 };
    const f720_30: VideoFormat = .{ .subtype = nv12, .width = 1280, .height = 720, .fps_num = 30, .fps_den = 1 };
    const f720_15: VideoFormat = .{ .subtype = nv12, .width = 1280, .height = 720, .fps_num = 15, .fps_den = 1 };
    const f720_30_mjpg: VideoFormat = .{ .subtype = mjpg, .width = 1280, .height = 720, .fps_num = 30, .fps_den = 1 };
    try std.testing.expect(f720_30.better(f1080_5));
    try std.testing.expect(!f1080_5.better(f720_30));
    try std.testing.expect(f720_30.better(f720_15));
    try std.testing.expect(f720_30.better(f720_30_mjpg));
    try std.testing.expect(!f720_30_mjpg.better(f720_30));
    // 30000/1001 is at least 15.
    try std.testing.expect((VideoFormat{ .subtype = nv12, .width = 2, .height = 2, .fps_num = 30000, .fps_den = 1001 }).atLeastFps(15));
    // No rate, or too big, isn't usable.
    try std.testing.expect(!(VideoFormat{ .subtype = nv12, .width = 640, .height = 480, .fps_num = 0, .fps_den = 1 }).usable());
    try std.testing.expect(!(VideoFormat{ .subtype = nv12, .width = 3840, .height = 2160, .fps_num = 30, .fps_den = 1 }).usable());
    try std.testing.expect(f720_30.usable());
    try std.testing.expectEqual(60, f720_30.keyframeInterval());
    try std.testing.expectEqual(1, (VideoFormat{ .subtype = nv12, .width = 2, .height = 2, .fps_num = 1, .fps_den = 3 }).keyframeInterval());
}

/// What an encoder took and gave back, for the encoder test.
const TestEncoderSink = struct {
    /// The times of the frames it took.
    taken: [64]i64 = undefined,
    taken_count: usize = 0,
    /// What it gave, in the order it gave them.
    shown: [64]i64 = undefined,
    decoded: [64]i64 = undefined,
    keyframes: [64]bool = undefined,
    count: usize = 0,

    pub fn encoded(s: *TestEncoderSink, e: Encoded, p: *Problem) error{Failed}!void {
        _ = p;
        if (e.bytes.len == 0) return error.Failed;
        s.shown[s.count] = e.time;
        s.decoded[s.count] = e.decode_time;
        s.keyframes[s.count] = e.keyframe;
        s.count += 1;
    }
};
/// An NV12 frame of `f`'s size in system memory, a pattern that moves with `n`, at `time`.
fn testNv12Frame(f: VideoFormat, n: u64, time: i64) !*win32.IMFSample {
    const len = f.width * f.height * 3 / 2;
    var buffer: ?*win32.IMFMediaBuffer = null;
    if (win32.MFCreateMemoryBuffer(len, &buffer).failed) return error.TestUnexpectedResult;
    defer _ = buffer.?.IUnknown.Release();
    var data: ?*u8 = null;
    if (buffer.?.Lock(&data, null, null).failed) return error.TestUnexpectedResult;
    const bytes = @as([*]u8, @ptrCast(data.?))[0..len];
    for (bytes, 0..) |*b, i| b.* = @truncate(i / 7 + n * 5);
    _ = buffer.?.Unlock();
    _ = buffer.?.SetCurrentLength(len);
    var sample: ?*win32.IMFSample = null;
    if (win32.MFCreateSample(&sample).failed) return error.TestUnexpectedResult;
    errdefer _ = sample.?.IUnknown.Release();
    if (sample.?.AddBuffer(buffer).failed) return error.TestUnexpectedResult;
    _ = sample.?.SetSampleTime(time);
    return sample.?;
}

/// Feeds `count` frames from number `first` (one every 1/30 s), forcing a keyframe at
/// `keyframe_at`; returns how many the encoder took.
fn testEncodeFrames(e: *Encoder, sink: *TestEncoderSink, f: VideoFormat, first: u64, count: u64, keyframe_at: ?u64, p: *Problem) !u64 {
    var taken: u64 = 0;
    for (first..first + count) |n| {
        const time: i64 = @intCast(1_000_000 + n * 333_333);
        const sample = try testNv12Frame(f, n, time);
        defer _ = sample.IUnknown.Release();
        if (keyframe_at == n) try e.forceKeyframe(p);
        if (try e.encode(.{ .sample = sample, .time = time }, sink, p)) {
            taken += 1;
            sink.taken[sink.taken_count] = time;
            sink.taken_count += 1;
        }
        // As a camera paces frames: async encoders work while we wait.
        win32.Sleep(5);
    }
    return taken;
}

test "the encoders give back every frame they take, at its time, make keyframes on request, and give everything back when drained" {
    {
        const hr = win32.CoInitializeEx(null, win32.COINIT_MULTITHREADED);
        if (hr.failed) return error.SkipZigTest;
    }
    defer win32.CoUninitialize();
    // Windows without Media Foundation (Server without its feature): nothing to test.
    if (win32.MFStartup(win32.MF_VERSION, win32.MFSTARTUP_FULL).failed) return error.SkipZigTest;
    defer mfShutdown();
    var encoders: Activates = .enumH264Encoders();
    const count = encoders.items.len;
    encoders.deinit();
    if (count == 0) return error.SkipZigTest;
    const f: VideoFormat = .{ .subtype = win32.MFVideoFormat_NV12, .width = 640, .height = 480, .fps_num = 30, .fps_den = 1 };
    // Every one listed: the best (the GPU's, where there is one) records, but a machine's
    // others are what another machine's best may be. The last is Windows' software one, which
    // makes B-frames: its frames come out in another order than they go in.
    for (0..count) |index| {
        errdefer std.debug.print("encoder {d} of {d}\n", .{ index, count });
        var p: Problem = undefined;
        errdefer std.debug.print("problem: {f}\n", .{p});
        var gpu: ?Gpu = null;
        defer if (gpu) |*g| g.deinit();
        var e: Encoder = try .createAt(index, &gpu, &p);
        defer e.destroy();
        try e.start(f, &p);
        var sink: TestEncoderSink = .{};
        errdefer for (sink.shown[0..sink.count], sink.decoded[0..sink.count], sink.keyframes[0..sink.count]) |t, d, k|
            std.debug.print("  shown {d} decoded {d}{s}\n", .{ t, d, if (k) " keyframe" else "" });
        const taken = try testEncodeFrames(&e, &sink, f, 0, 30, 17, &p);
        try e.drain(&sink, &p);
        try std.testing.expect(!e.isDraining());
        try std.testing.expect(taken >= 10);
        try testEncodedAll(&sink);
        // The first frame and the forced one are keyframes, no others (the keyframe interval
        // is 60 frames). The forced one is the first taken from 17 on (a busy encoder may
        // refuse 17 itself: the next it takes is made one).
        const forced = for (sink.taken[0..sink.taken_count]) |t| {
            if (t >= 1_000_000 + 17 * 333_333) break t;
        } else return error.TestUnexpectedResult;
        for (sink.shown[0..sink.count], sink.keyframes[0..sink.count], 0..) |t, k, i|
            try std.testing.expectEqual(i == 0 or t == forced, k);
        // It takes frames after a drain, and gives them all back again.
        const more = try testEncodeFrames(&e, &sink, f, 30, 10, null, &p);
        try e.drain(&sink, &p);
        try std.testing.expect(!e.isDraining());
        try std.testing.expect(more >= 3);
        try testEncodedAll(&sink);
    }
}

/// Muxes what an encoder gives into an MP4, for the playback test.
const TestMuxSink = struct {
    gpa: std.mem.Allocator,
    muxer: mp4.Muxer(u64) = .{ .width = 640, .height = 480, .nominal_duration = 333_333 },
    file: std.Io.Writer.Allocating,
    frame: std.ArrayList(u8) = .empty,
    /// The frames it gave, and whether any came out shown before one given ahead of it.
    count: u64 = 0,
    reordered: bool = false,
    last_shown: i64 = std.math.minInt(i64),
    mux_error: ?anyerror = null,

    pub fn encoded(s: *TestMuxSink, e: Encoded, p: *Problem) error{Failed}!void {
        if (e.time < s.last_shown) s.reordered = true;
        s.last_shown = @max(s.last_shown, e.time);
        // As the recorder journals it: its parameter sets first, if it needed them.
        s.frame.clearRetainingCapacity();
        s.frame.appendSlice(s.gpa, e.parameter_sets) catch @panic("out of memory");
        s.frame.appendSlice(s.gpa, e.bytes) catch @panic("out of memory");
        s.muxer.add(s.gpa, &s.file.writer, s.frame.items, @intCast(e.time), e.decode_time, e.keyframe, s.count) catch |err| {
            s.mux_error = err;
            p.* = .{ .encoder_misbehaved = "its frame couldn't be muxed" };
            return error.Failed;
        };
        s.count += 1;
    }
};

test "a webcam's MP4 with B-frames plays back: every frame decodes, shown when it was captured" {
    {
        const hr = win32.CoInitializeEx(null, win32.COINIT_MULTITHREADED);
        if (hr.failed) return error.SkipZigTest;
    }
    defer win32.CoUninitialize();
    if (win32.MFStartup(win32.MF_VERSION, win32.MFSTARTUP_FULL).failed) return error.SkipZigTest;
    defer mfShutdown();
    var encoders: Activates = .enumH264Encoders();
    const count = encoders.items.len;
    encoders.deinit();
    if (count == 0) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const f: VideoFormat = .{ .subtype = win32.MFVideoFormat_NV12, .width = 640, .height = 480, .fps_num = 30, .fps_den = 1 };

    // Windows' software encoder (listed last), which makes B-frames.
    var p: Problem = undefined;
    errdefer std.debug.print("problem: {f}\n", .{p});
    var gpu: ?Gpu = null;
    defer if (gpu) |*g| g.deinit();
    var e: Encoder = try .createAt(count - 1, &gpu, &p);
    defer e.destroy();
    try e.start(f, &p);
    var sink: TestMuxSink = .{ .gpa = gpa, .file = .init(gpa) };
    defer {
        sink.muxer.deinit(gpa);
        sink.file.deinit();
        sink.frame.deinit(gpa);
    }
    errdefer if (sink.mux_error) |err| std.debug.print("mux error: {t}\n", .{err});
    const frames = 90;
    var taken: [frames]i64 = undefined;
    var taken_count: usize = 0;
    for (0..frames) |n| {
        const time: i64 = @intCast(1_000_000 + n * 333_333);
        const sample = try testNv12Frame(f, n, time);
        defer _ = sample.IUnknown.Release();
        if (try e.encode(.{ .sample = sample, .time = time }, &sink, &p)) {
            taken[taken_count] = time;
            taken_count += 1;
        }
        win32.Sleep(2);
    }
    try e.drain(&sink, &p);
    try std.testing.expectEqual(taken_count, sink.count);
    // It's the B-frames' case this tests.
    try std.testing.expect(sink.reordered);
    try sink.muxer.finish(gpa, &sink.file.writer, null);
    const bytes = sink.file.written();
    const patches = sink.muxer.patches(&.{});
    @memcpy(bytes[patches.mvhd_duration.offset..][0..4], &patches.mvhd_duration.bytes);
    @memcpy(bytes[patches.tkhd_duration.offset..][0..4], &patches.tkhd_duration.bytes);
    @memcpy(bytes[patches.mehd_duration.offset..][0..8], &patches.mehd_duration.bytes);
    @memcpy(bytes[patches.tags.offset..][0..mp4.tags_area], &patches.tags.bytes);

    // Into a file, read back by Media Foundation's MP4 reader and H.264 decoder.
    var path_buf: [win32.MAX_PATH]u16 = undefined;
    const path = testTempFile(&path_buf, "BlackBoxTest-bframes.mp4");
    {
        const file = win32.CreateFileW(path, .{ .FILE_WRITE_DATA = 1 }, .{}, null, .CREATE_ALWAYS, .{ .FILE_ATTRIBUTE_NORMAL = 1 }, null);
        if (file == win32.INVALID_HANDLE_VALUE) win32.panicWin32("CreateFile(test mp4)", win32.GetLastError());
        defer win32.closeHandle(file);
        var written: u32 = 0;
        if (0 == win32.WriteFile(file, bytes.ptr, @intCast(bytes.len), &written, null) or written != bytes.len)
            win32.panicWin32("WriteFile(test mp4)", win32.GetLastError());
    }
    defer _ = win32.DeleteFileW(path);
    var reader: ?*win32.IMFSourceReader = null;
    try check(&p, win32.MFCreateSourceReaderFromURL(path, null, &reader), "Opening the test MP4");
    defer _ = reader.?.IUnknown.Release();
    // Decoded: the reader puts the H.264 decoder in.
    {
        var t: ?*win32.IMFMediaType = null;
        try check(&p, win32.MFCreateMediaType(&t), "Creating a media type");
        defer _ = t.?.IUnknown.Release();
        try check(&p, t.?.IMFAttributes.SetGUID(&win32.MF_MT_MAJOR_TYPE, &win32.MFMediaType_Video), "Setting a media type");
        try check(&p, t.?.IMFAttributes.SetGUID(&win32.MF_MT_SUBTYPE, &win32.MFVideoFormat_NV12), "Setting a media type");
        try check(&p, reader.?.SetCurrentMediaType(video_stream, null, t), "Asking for decoded frames");
    }
    var shown: [frames]i64 = undefined;
    var decoded: usize = 0;
    while (true) {
        var flags: u32 = 0;
        var time: i64 = 0;
        var sample: ?*win32.IMFSample = null;
        try check(&p, reader.?.ReadSample(video_stream, 0, null, &flags, &time, &sample), "Reading the test MP4");
        if (sample) |s| {
            defer _ = s.IUnknown.Release();
            try std.testing.expect(decoded < frames);
            shown[decoded] = time;
            decoded += 1;
        }
        if (flags & @as(u32, @bitCast(@backingInt(win32.MF_SOURCE_READERF_ENDOFSTREAM))) != 0) break;
    }
    // Every frame, each at the time it was captured.
    errdefer std.debug.print("decoded {d} of {d} frames, shown at: {any}\n", .{ decoded, taken_count, shown[0..decoded] });
    try std.testing.expectEqualSlices(i64, taken[0..taken_count], shown[0..decoded]);
}

test "a webcam's file shows NO VIDEO, its encoder's, before its first frame, in a gap and to the end, in software and GPU decoders" {
    {
        const hr = win32.CoInitializeEx(null, win32.COINIT_MULTITHREADED);
        if (hr.failed) return error.SkipZigTest;
    }
    defer win32.CoUninitialize();
    if (win32.MFStartup(win32.MF_VERSION, win32.MFSTARTUP_FULL).failed) return error.SkipZigTest;
    defer mfShutdown();
    var encoders: Activates = .enumH264Encoders();
    const count = encoders.items.len;
    encoders.deinit();
    if (count == 0) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const f: VideoFormat = .{ .subtype = win32.MFVideoFormat_NV12, .width = 640, .height = 480, .fps_num = 30, .fps_den = 1 };
    var p: Problem = undefined;
    errdefer std.debug.print("problem: {f}\n", .{p});

    // The best encoder, as a webcam records with, and its NO VIDEO.
    var gpu: ?Gpu = null;
    defer if (gpu) |*g| g.deinit();
    var e: Encoder = try .create(&gpu, &p);
    defer e.destroy();
    try e.start(f, &p);
    const nov = try makeNoVideo(gpa, f, &p);
    defer gpa.free(nov);
    var sink: TestMuxSink = .{ .gpa = gpa, .file = .init(gpa) };
    defer {
        sink.muxer.deinit(gpa);
        sink.file.deinit();
        sink.frame.deinit(gpa);
    }
    errdefer if (sink.mux_error) |err| std.debug.print("mux error: {t}\n", .{err});
    sink.muxer.novideo = nov;
    // Frames from 1 s (NO VIDEO before), a gap of 3 s, frames again, and NO VIDEO to 7 s.
    const frame_time = 333_333;
    for ([2]u64{ 10_000_000, 40_000_000 }, 0..) |from, pass| {
        if (pass == 1) {
            try sink.muxer.pause(gpa, &sink.file.writer);
            try e.forceKeyframe(&p);
        }
        for (0..30) |n| {
            const time: i64 = @intCast(from + n * frame_time);
            const sample = try testNv12Frame(f, n, time);
            defer _ = sample.IUnknown.Release();
            // An async encoder may be busy: the frame's dropped, as a webcam's is.
            _ = try e.encode(.{ .sample = sample, .time = time }, &sink, &p);
            win32.Sleep(5);
        }
        try e.drain(&sink, &p);
    }
    try sink.muxer.pause(gpa, &sink.file.writer);
    try sink.muxer.finish(gpa, &sink.file.writer, 70_000_000);
    const bytes = sink.file.written();
    const patches = sink.muxer.patches(&.{});
    @memcpy(bytes[patches.mehd_duration.offset..][0..8], &patches.mehd_duration.bytes);

    var path_buf: [win32.MAX_PATH]u16 = undefined;
    const path = testTempFile(&path_buf, "BlackBoxTest-novideo.mp4");
    {
        const h = win32.CreateFileW(path, .{ .FILE_WRITE_DATA = 1 }, .{}, null, .CREATE_ALWAYS, .{ .FILE_ATTRIBUTE_NORMAL = 1 }, null);
        if (h == win32.INVALID_HANDLE_VALUE) win32.panicWin32("CreateFile(test mp4)", win32.GetLastError());
        defer win32.closeHandle(h);
        var written: u32 = 0;
        if (0 == win32.WriteFile(h, bytes.ptr, @intCast(bytes.len), &written, null) or written != bytes.len)
            win32.panicWin32("WriteFile(test mp4)", win32.GetLastError());
    }
    defer _ = win32.DeleteFileW(path);

    // A sample of the letters (the first, at the N's top left) and of the ground.
    const ink_at: [2]u32 = blk: {
        for (0..f.height) |y| for (0..f.width) |x| {
            if (novideo.luma(f.width, f.height, @intCast(x), @intCast(y)) == novideo.ink) break :blk .{ @intCast(x + 2), @intCast(y + 2) };
        };
        unreachable;
    };
    for ([_]bool{ false, true }) |on_gpu| {
        errdefer std.debug.print("decoded on the {s}\n", .{if (on_gpu) "GPU" else "CPU"});
        var decode_gpu: ?Gpu = null;
        defer if (decode_gpu) |*g| g.deinit();
        var attrs: ?*win32.IMFAttributes = null;
        try check(&p, win32.MFCreateAttributes(&attrs, 2), "Creating attributes");
        defer _ = attrs.?.IUnknown.Release();
        if (on_gpu) {
            // As a player does: decoded by the GPU.
            decode_gpu = try .init(null, &p);
            try check(&p, attrs.?.SetUnknown(&win32.MF_SOURCE_READER_D3D_MANAGER, &decode_gpu.?.manager.IUnknown), "Setting the GPU");
            try check(&p, attrs.?.SetUINT32(&win32.MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, 1), "Setting the GPU");
        }
        var reader: ?*win32.IMFSourceReader = null;
        try check(&p, win32.MFCreateSourceReaderFromURL(path, attrs, &reader), "Opening the test MP4");
        defer _ = reader.?.IUnknown.Release();
        {
            var t: ?*win32.IMFMediaType = null;
            try check(&p, win32.MFCreateMediaType(&t), "Creating a media type");
            defer _ = t.?.IUnknown.Release();
            try check(&p, t.?.IMFAttributes.SetGUID(&win32.MF_MT_MAJOR_TYPE, &win32.MFMediaType_Video), "Setting a media type");
            try check(&p, t.?.IMFAttributes.SetGUID(&win32.MF_MT_SUBTYPE, &win32.MFVideoFormat_NV12), "Setting a media type");
            try check(&p, reader.?.SetCurrentMediaType(video_stream, null, t), "Asking for decoded frames");
        }
        // How many of NO VIDEO's frames each stretch without video has: before the first
        // frame (to 1 s), the gap (2 s to 4 s), after the last (5 s to 7 s). NO VIDEO is at
        // the webcam's frame rate.
        var novideo_in = [3]u32{ 0, 0, 0 };
        var last_novideo = false;
        while (true) {
            var flags: u32 = 0;
            var time: i64 = 0;
            var sample: ?*win32.IMFSample = null;
            try check(&p, reader.?.ReadSample(video_stream, 0, null, &flags, &time, &sample), "Reading the test MP4");
            if (sample) |s| {
                defer _ = s.IUnknown.Release();
                var buffer: ?*win32.IMFMediaBuffer = null;
                try check(&p, s.ConvertToContiguousBuffer(&buffer), "Reading a decoded frame");
                defer _ = buffer.?.IUnknown.Release();
                var data: ?*u8 = null;
                var len: u32 = 0;
                try check(&p, buffer.?.Lock(&data, null, &len), "Reading a decoded frame");
                defer _ = buffer.?.Unlock();
                const y_plane = @as([*]const u8, @ptrCast(data.?))[0..len];
                // Encoded, not exact: near what was drawn, across the picture (an 8x8 grid,
                // and the letters' first sample).
                var is_novideo = @abs(@as(i32, y_plane[ink_at[1] * f.width + ink_at[0]]) - novideo.ink) <= 24;
                for (0..8) |gy| for (0..8) |gx| {
                    const x: u32 = @intCast(gx * f.width / 8 + f.width / 16);
                    const y: u32 = @intCast(gy * f.height / 8 + f.height / 16);
                    if (@abs(@as(i32, y_plane[y * f.width + x]) - novideo.luma(f.width, f.height, x, y)) > 24) is_novideo = false;
                };
                errdefer std.debug.print("a frame at {d} ms {s} NO VIDEO\n", .{ @divTrunc(time, 10_000), if (is_novideo) "is" else "isn't" });
                // The webcam's frames (1 s to 1.97 s, 4 s to 4.97 s) are its; between, NO VIDEO.
                const stretch: ?usize = if (time < 10_000_000) 0 else if (time >= 20_000_000 and time < 40_000_000) 1 else if (time >= 50_000_000) 2 else null;
                if (stretch) |i| {
                    try std.testing.expect(is_novideo);
                    novideo_in[i] += 1;
                } else if (time < 19_700_000 or (time >= 40_000_000 and time < 49_700_000)) try std.testing.expect(!is_novideo);
                last_novideo = is_novideo;
            }
            if (flags & @as(u32, @bitCast(@backingInt(win32.MF_SOURCE_READERF_ENDOFSTREAM))) != 0) break;
        }
        errdefer std.debug.print("NO VIDEO frames in each stretch: {any}\n", .{novideo_in});
        // A frame each frame time (to one more: a frame time doesn't divide a second).
        const per_second = 10_000_000 / noVideoTiming(f).interval;
        for (novideo_in, [3]u32{ 1, 2, 2 }) |n, seconds| try std.testing.expect(n >= seconds * per_second and n <= seconds * per_second + 1);
        try std.testing.expect(last_novideo);
    }
}
/// A file named `name` in the temp folder.
fn testTempFile(buf: *[win32.MAX_PATH]u16, name: []const u8) [:0]const u16 {
    const n = win32.GetTempPathW(buf.len, @ptrCast(buf));
    if (n == 0 or n + name.len >= buf.len) win32.panicWin32("GetTempPath", win32.GetLastError());
    for (name, 0..) |c, i| buf[n + i] = c;
    buf[n + name.len] = 0;
    return buf[0 .. n + name.len :0];
}

/// Every frame the encoder took came back once, at the time it went in (in whatever order),
/// each decoded no later than it's shown, decode times in the order it gave them.
fn testEncodedAll(s: *TestEncoderSink) !void {
    try std.testing.expectEqual(s.taken_count, s.count);
    var shown: [64]i64 = undefined;
    @memcpy(shown[0..s.count], s.shown[0..s.count]);
    std.mem.sort(i64, shown[0..s.count], {}, std.sort.asc(i64));
    try std.testing.expectEqualSlices(i64, s.taken[0..s.taken_count], shown[0..s.count]);
    for (s.decoded[0..s.count], s.shown[0..s.count], 0..) |d, t, i| {
        try std.testing.expect(d <= t);
        if (i > 0) try std.testing.expect(d > s.decoded[i - 1]);
    }
}
const std = @import("std");
const win32 = @import("win32").everything;
const mp4 = @import("mp4.zig");
const novideo = @import("novideo.zig");
const wintrace = @import("wintrace");
const bb = @import("bb.zig");
const record = @import("record.zig");
const wasapi = @import("wasapi.zig");
