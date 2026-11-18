//! Audio capture with WASAPI, one thread per source. Part of the Windows platform layer.
//!
//! The thread opens the device the user picked (see listDevices) in shared mode, as the
//! device delivers it: its own format, no resampling, no gain. A microphone is captured
//! directly; an output (system audio) by loopback: what Windows mixes to it, as it plays. The
//! thread measures levels into a bb.Meter and, while recording, passes packets to the
//! recorder. It reports how it's going (live, or why it failed) by setting its status and
//! posting `status_msg` to the window, whose handler passes it on to bb.

/// What a capture records from.
pub const Endpoint = enum {
    microphone,
    /// An output: speakers, headphones. Captured by loopback.
    output,

    /// For messages to the user.
    fn noun(e: Endpoint) []const u8 {
        return switch (e) {
            .microphone => "microphone",
            .output => "output",
        };
    }

    fn flow(e: Endpoint) win32.EDataFlow {
        return switch (e) {
            .microphone => win32.eCapture,
            .output => win32.eRender,
        };
    }
};

/// Lists the active endpoints of a kind into bb (bb.addDevice), their ids being the endpoint
/// ids for Capture.create. On the window's thread, which must have COM initialized.
pub fn listDevices(gpa: std.mem.Allocator, endpoint: Endpoint) void {
    var enumerator: *win32.IMMDeviceEnumerator = undefined;
    {
        const hr = win32.CoCreateInstance(win32.CLSID_MMDeviceEnumerator, null, win32.CLSCTX_ALL, win32.IID_IMMDeviceEnumerator, @ptrCast(&enumerator));
        if (hr.failed) win32.panicHresult("CoCreateInstance(MMDeviceEnumerator)", hr);
    }
    defer _ = enumerator.IUnknown.Release();
    var collection: ?*win32.IMMDeviceCollection = null;
    {
        const hr = enumerator.EnumAudioEndpoints(endpoint.flow(), win32.DEVICE_STATE_ACTIVE, &collection);
        if (hr.failed) win32.panicHresult("EnumAudioEndpoints", hr);
    }
    defer _ = collection.?.IUnknown.Release();
    // The default device's id, to mark it. None when there are no devices of the kind.
    var default_id: ?[*:0]u16 = null;
    {
        var default: ?*win32.IMMDevice = null;
        const hr = enumerator.GetDefaultAudioEndpoint(endpoint.flow(), win32.eConsole, &default);
        if (hr.failed and hr != hresult_not_found) win32.panicHresult("GetDefaultAudioEndpoint", hr);
        if (default) |d| {
            defer _ = d.IUnknown.Release();
            const id_hr = d.GetId(&default_id);
            if (id_hr.failed) win32.panicHresult("IMMDevice.GetId", id_hr);
        }
    }
    defer win32.CoTaskMemFree(default_id);
    var count: u32 = undefined;
    {
        const hr = collection.?.GetCount(&count);
        if (hr.failed) win32.panicHresult("IMMDeviceCollection.GetCount", hr);
    }
    for (0..count) |i| {
        var device: ?*win32.IMMDevice = null;
        {
            const hr = collection.?.Item(@intCast(i), &device);
            if (hr.failed) win32.panicHresult("IMMDeviceCollection.Item", hr);
        }
        defer _ = device.?.IUnknown.Release();

        var id: ?[*:0]u16 = null;
        {
            const hr = device.?.GetId(&id);
            if (hr.failed) win32.panicHresult("IMMDevice.GetId", hr);
        }
        defer win32.CoTaskMemFree(id);

        var props: ?*win32.IPropertyStore = null;
        {
            const hr = device.?.OpenPropertyStore(win32.STGM_READ, &props);
            if (hr.failed) win32.panicHresult("IMMDevice.OpenPropertyStore", hr);
        }
        defer _ = props.?.IUnknown.Release();
        var name: win32.PROPVARIANT = std.mem.zeroes(win32.PROPVARIANT);
        {
            const hr = props.?.GetValue(&win32.PKEY_Device_FriendlyName, &name);
            if (hr.failed) win32.panicHresult("GetValue(PKEY_Device_FriendlyName)", hr);
        }
        defer _ = win32.PropVariantClear(&name);
        const name_wide = name.Anonymous.Anonymous.Anonymous.pwszVal orelse
            std.debug.panic("audio device {f} has no name", .{std.unicode.fmtUtf16Le(std.mem.span(id.?))});

        // The format the device runs at in shared mode, Sound settings' "Default Format".
        var device_format: win32.PROPVARIANT = std.mem.zeroes(win32.PROPVARIANT);
        {
            const hr = props.?.GetValue(&win32.PKEY_AudioEngine_DeviceFormat, &device_format);
            if (hr.failed) win32.panicHresult("GetValue(PKEY_AudioEngine_DeviceFormat)", hr);
        }
        defer _ = win32.PropVariantClear(&device_format);
        const format: ?bb.AudioFormat = blk: {
            const v = &device_format.Anonymous.Anonymous;
            if (v.vt != win32.VT_BLOB or v.Anonymous.blob.cbSize < @sizeOf(win32.WAVEFORMATEX)) break :blk null;
            break :blk audioFormat(@ptrCast(@alignCast(v.Anonymous.blob.pBlobData.?)));
        };

        // What it physically is, as the driver says (from the jack or USB descriptors).
        var form_factor: win32.PROPVARIANT = std.mem.zeroes(win32.PROPVARIANT);
        {
            const hr = props.?.GetValue(&win32.PKEY_AudioEndpoint_FormFactor, &form_factor);
            if (hr.failed) win32.panicHresult("GetValue(PKEY_AudioEndpoint_FormFactor)", hr);
        }
        defer _ = win32.PropVariantClear(&form_factor);
        const form: ?bb.Device.Form = blk: {
            const v = &form_factor.Anonymous.Anonymous;
            // Absent (VT_EMPTY) when the driver doesn't say.
            if (v.vt != win32.VT_UI4) break :blk null;
            const ff: i32 = @bitCast(v.Anonymous.ulVal);
            break :blk if (ff == @intFromEnum(win32.Speakers))
                .speakers
            else if (ff == @intFromEnum(win32.Headphones))
                .headphones
            else if (ff == @intFromEnum(win32.Headset))
                .headset
            else if (ff == @intFromEnum(win32.Handset))
                .handset
            else if (ff == @intFromEnum(win32.Microphone))
                .microphone
            else if (ff == @intFromEnum(win32.DigitalAudioDisplayDevice))
                .display
            else
                // Line level, S/PDIF, digital passthrough, network, unknown: nothing to draw.
                null;
        };

        bb.addDevice(.{
            .name = std.unicode.wtf16LeToWtf8Alloc(gpa, std.mem.span(name_wide)) catch @panic("out of memory"),
            .id = std.unicode.wtf16LeToWtf8Alloc(gpa, std.mem.span(id.?)) catch @panic("out of memory"),
            .format = format,
            .form = form,
            .default = if (default_id) |d| std.mem.eql(u16, std.mem.span(d), std.mem.span(id.?)) else false,
        });
    }
}

/// Live peak levels of devices, for the devices menu while it's open: each device's own meter
/// (IAudioMeterInformation, what Sound settings' green bars show). An output's is read as is,
/// changing nothing about it. A microphone's only measures while something captures, so each
/// gets a capture stream whose audio is thrown away, as Sound settings' Recording tab does;
/// that lights Windows' microphone indicator while the menu is open. Not Bluetooth ones:
/// capturing switches a classic Bluetooth headset to call quality, for whatever it's playing
/// too. On a thread of its own, since opening a device can take a while: the menu shows at
/// once and each level appears as its device answers. Everything it holds goes in stop.
pub const DeviceMeters = struct {
    gpa: std.mem.Allocator,
    endpoint: Endpoint,
    thread: std.Thread,
    stop_event: win32.HANDLE,
    /// The devices' endpoint ids, each 0-terminated, one after another.
    ids: []u16,
    /// One per device, for bb.setDeviceLevels.
    levels: []bb.DeviceLevel,

    /// How often levels are read: about a frame.
    const poll_ms = 15;
    /// How much a held peak falls each poll when nothing louder comes, about 20 dB a second,
    /// so short peaks stay visible.
    const fall = 0.966;

    /// Meters `devices` (from listDevices for `endpoint`), in order.
    pub fn start(gpa: std.mem.Allocator, endpoint: Endpoint, devices: []const bb.Device) *DeviceMeters {
        var ids_len: usize = 0;
        for (devices) |d| ids_len += (std.unicode.calcWtf16LeLen(d.id) catch unreachable) + 1; // listDevices made it from UTF-16
        const m = gpa.create(DeviceMeters) catch @panic("out of memory");
        m.* = .{
            .gpa = gpa,
            .endpoint = endpoint,
            .thread = undefined,
            .stop_event = win32.CreateEventW(null, 1, 0, null) orelse win32.panicWin32("CreateEvent", win32.GetLastError()),
            .ids = gpa.alloc(u16, ids_len) catch @panic("out of memory"),
            .levels = gpa.alloc(bb.DeviceLevel, devices.len) catch @panic("out of memory"),
        };
        var at: usize = 0;
        for (devices) |d| {
            at += std.unicode.wtf8ToWtf16Le(m.ids[at..], d.id) catch unreachable;
            m.ids[at] = 0;
            at += 1;
        }
        @memset(m.levels, .init(bb.no_level));
        m.thread = std.Thread.spawn(.{}, poll, .{m}) catch |e| std.debug.panic("spawning the device meter thread failed: {t}", .{e});
        return m;
    }

    /// Stops the thread (it closes the devices) and frees everything.
    pub fn stop(m: *DeviceMeters) void {
        if (0 == win32.SetEvent(m.stop_event)) win32.panicWin32("SetEvent", win32.GetLastError());
        m.thread.join();
        win32.closeHandle(m.stop_event);
        m.gpa.free(m.ids);
        m.gpa.free(m.levels);
        m.gpa.destroy(m);
    }

    fn stopped(m: *DeviceMeters, wait_ms: u32) bool {
        return switch (@intFromEnum(win32.WaitForSingleObject(m.stop_event, wait_ms))) {
            0 => true,
            @intFromEnum(win32.WAIT_TIMEOUT) => false,
            else => win32.panicWin32("WaitForSingleObject", win32.GetLastError()),
        };
    }

    /// A device being metered: its meter (null if it couldn't be opened, or isn't metered:
    /// it shows no level), and for a microphone the capture that makes the meter measure.
    const Slot = struct {
        meter: ?*win32.IAudioMeterInformation = null,
        client: ?*win32.IAudioClient = null,
        capture: ?*win32.IAudioCaptureClient = null,
        held: f32 = 0,

        fn close(s: *Slot) void {
            if (s.client) |c| _ = c.Stop();
            if (s.capture) |c| _ = c.IUnknown.Release();
            if (s.client) |c| _ = c.IUnknown.Release();
            if (s.meter) |meter| _ = meter.IUnknown.Release();
            s.* = .{};
        }

        /// Reads the meter, and throws away what the capture has. False if the device is gone.
        fn read(s: *Slot) bool {
            if (s.capture) |cc| while (true) {
                var frames: u32 = undefined;
                if (cc.GetNextPacketSize(&frames).failed) return false;
                if (frames == 0) break;
                var data: ?*u8 = null;
                var flags: u32 = undefined;
                if (cc.GetBuffer(&data, &frames, &flags, null, null).failed) return false;
                if (cc.ReleaseBuffer(frames).failed) return false;
            };
            var peak: f32 = undefined;
            if (s.meter.?.GetPeakValue(&peak).failed) return false;
            s.held = @max(peak, s.held * fall);
            return true;
        }
    };

    fn poll(m: *DeviceMeters) void {
        var guarantee: u32 = wintrace.stack_guarantee;
        if (0 == wintrace.SetThreadStackGuarantee(&guarantee)) win32.panicWin32("SetThreadStackGuarantee", win32.GetLastError());
        {
            const hr = win32.CoInitializeEx(null, win32.COINIT_MULTITHREADED);
            if (hr.failed) win32.panicHresult("CoInitializeEx", hr);
        }
        defer win32.CoUninitialize();
        var enumerator: *win32.IMMDeviceEnumerator = undefined;
        {
            const hr = win32.CoCreateInstance(win32.CLSID_MMDeviceEnumerator, null, win32.CLSCTX_ALL, win32.IID_IMMDeviceEnumerator, @ptrCast(&enumerator));
            if (hr.failed) win32.panicHresult("CoCreateInstance(MMDeviceEnumerator)", hr);
        }
        defer _ = enumerator.IUnknown.Release();

        const slots = m.gpa.alloc(Slot, m.levels.len) catch @panic("out of memory");
        defer m.gpa.free(slots);
        @memset(slots, .{});
        defer for (slots) |*s| s.close();

        // Opened one at a time, reading those already open between, so slow ones don't hold
        // up the rest.
        var opened: usize = 0;
        var id_at: usize = 0;
        while (!m.stopped(if (opened < slots.len) 0 else poll_ms)) {
            if (opened < slots.len) {
                const id: [*:0]const u16 = @ptrCast(m.ids[id_at..].ptr);
                id_at += std.mem.len(id) + 1;
                open(&slots[opened], enumerator, id, m.endpoint);
                opened += 1;
            }
            for (slots[0..opened], m.levels[0..opened]) |*s, *level| {
                if (s.meter == null) continue;
                if (!s.read()) {
                    // Gone (unplugged): no level from now on.
                    s.close();
                    level.store(bb.no_level, .monotonic);
                    continue;
                }
                level.store(@bitCast(s.held), .monotonic);
            }
        }
    }

    /// Leaves the slot empty if the device is gone, can't be opened, or isn't metered.
    fn open(s: *Slot, enumerator: *win32.IMMDeviceEnumerator, id: [*:0]const u16, endpoint: Endpoint) void {
        var device: ?*win32.IMMDevice = null;
        if (enumerator.GetDevice(id, &device).failed) return;
        defer _ = device.?.IUnknown.Release();
        if (endpoint == .microphone) {
            if (isBluetooth(device.?)) return;
            var client: *win32.IAudioClient = undefined;
            if (device.?.Activate(win32.IID_IAudioClient, win32.CLSCTX_ALL, null, @ptrCast(&client)).failed) return;
            s.client = client;
            var format: ?*win32.WAVEFORMATEX = null;
            if (client.GetMixFormat(&format).failed) return s.close();
            defer win32.CoTaskMemFree(format);
            if (client.Initialize(.SHARED, 0, 1000 * hns_per_ms, 0, format, null).failed) return s.close();
            var cc: *win32.IAudioCaptureClient = undefined;
            if (client.GetService(win32.IID_IAudioCaptureClient, @ptrCast(&cc)).failed) return s.close();
            s.capture = cc;
            if (client.Start().failed) return s.close();
        }
        var meter: *win32.IAudioMeterInformation = undefined;
        if (device.?.Activate(win32.IID_IAudioMeterInformation, win32.CLSCTX_ALL, null, @ptrCast(&meter)).failed) return s.close();
        s.meter = meter;
    }

    /// Whether the endpoint is on a Bluetooth adapter: the device its connector is wired to
    /// is one Windows' Bluetooth enumerators made (classic BTHENUM, hands-free BTHHFENUM, Low
    /// Energy BTHLE...). False when that can't be told: software devices have no adapter.
    fn isBluetooth(device: *win32.IMMDevice) bool {
        var topology: *win32.IDeviceTopology = undefined;
        if (device.Activate(win32.IID_IDeviceTopology, win32.CLSCTX_ALL, null, @ptrCast(&topology)).failed) return false;
        defer _ = topology.IUnknown.Release();
        var connector: ?*win32.IConnector = null;
        if (topology.GetConnector(0, &connector).failed) return false;
        defer _ = connector.?.IUnknown.Release();
        var other: ?*win32.IConnector = null;
        if (connector.?.GetConnectedTo(&other).failed) return false;
        defer _ = other.?.IUnknown.Release();
        var part: *win32.IPart = undefined;
        if (other.?.IUnknown.QueryInterface(win32.IID_IPart, @ptrCast(&part)).failed) return false;
        defer _ = part.IUnknown.Release();
        var adapter: ?*win32.IDeviceTopology = null;
        if (part.GetTopologyObject(&adapter).failed) return false;
        defer _ = adapter.?.IUnknown.Release();
        var adapter_id: ?[*:0]u16 = null;
        if (adapter.?.GetDeviceId(&adapter_id).failed) return false;
        defer win32.CoTaskMemFree(adapter_id);
        // Plain ASCII, so a UTF-16 search for its letters, any case.
        const wide = std.mem.span(adapter_id.?);
        const needle = "BTH";
        var i: usize = 0;
        while (i + needle.len <= wide.len) : (i += 1) {
            for (needle, wide[i..][0..needle.len]) |n, w| {
                if (w > 0x7F or std.ascii.toUpper(@intCast(w)) != n) break;
            } else return true;
        }
        return false;
    }
};

/// Posted to the window when a capture's status changes. wparam is the source id.
pub const status_msg = win32.WM_APP + 1;

pub const Capture = struct {
    /// Which bb source this is for.
    id: u32,
    endpoint: Endpoint,
    /// The endpoint to open.
    device_id: [:0]const u16,
    hwnd: win32.HWND,
    stop_event: win32.HANDLE,
    thread: std.Thread,
    /// Only this capture's thread writes it.
    meter: bb.Meter = .{},
    /// Set by the thread before it posts status_msg; read on the window's thread after.
    status: std.atomic.Value(Status) = .init(.starting),
    /// Why it failed, written before status becomes .failed.
    failure: bb.Message = .{},
    /// The format we receive, and whether it's raw (no Windows effects), written before
    /// status becomes .live.
    format: bb.AudioFormat = undefined,
    raw: bool = false,
    /// The samples as they come, for a recorder. Written before status becomes .live.
    input: record.Input = undefined,
    gpa: std.mem.Allocator,
    /// The recorder this capture's packets go to while recording. Set and taken on the window's
    /// thread (attachRecorder, detachRecorder), used by the capture thread, under the lock.
    recorder_lock: record.Lock = .{},
    recorder: ?*record.AudioPoolSource = null,

    pub const Status = enum(u8) { starting, live, failed };

    /// Allocates a capture and starts its thread. Stop it with `destroy`. `device_id` is one
    /// from listDevices.
    pub fn create(gpa: std.mem.Allocator, id: u32, endpoint: Endpoint, device_id: []const u8, hwnd: win32.HWND) *Capture {
        const c = gpa.create(Capture) catch @panic("out of memory");
        c.* = .{
            .id = id,
            .endpoint = endpoint,
            .device_id = std.unicode.wtf8ToWtf16LeAllocZ(gpa, device_id) catch |e| switch (e) {
                error.OutOfMemory => @panic("out of memory"),
                error.InvalidWtf8 => unreachable, // listDevices made it from UTF-16
            },
            .hwnd = hwnd,
            .stop_event = win32.CreateEventW(null, 1, 0, null) orelse win32.panicWin32("CreateEvent", win32.GetLastError()),
            .thread = undefined,
            .gpa = gpa,
        };
        c.thread = std.Thread.spawn(.{}, run, .{c}) catch |e| std.debug.panic("spawning the capture thread failed: {t}", .{e});
        return c;
    }

    /// Stops the thread and frees the capture.
    pub fn destroy(c: *Capture, gpa: std.mem.Allocator) void {
        if (0 == win32.SetEvent(c.stop_event)) win32.panicWin32("SetEvent", win32.GetLastError());
        c.thread.join();
        win32.closeHandle(c.stop_event);
        gpa.free(c.device_id);
        gpa.destroy(c);
    }

    /// The status for bb. Call on the window's thread, after status_msg.
    pub fn sourceStatus(c: *const Capture) bb.SourceStatus {
        return switch (c.status.load(.acquire)) {
            .starting => .starting,
            .live => .{ .live = .{ .audio = .{ .format = c.format, .raw = c.raw } } },
            .failed => .{ .failed = c.failure },
        };
    }

    /// From the window's thread, once live (the recorder takes `input`).
    pub fn attachRecorder(c: *Capture, r: *record.AudioPoolSource) void {
        c.recorder_lock.lock();
        defer c.recorder_lock.unlock();
        std.debug.assert(c.recorder == null);
        c.recorder = r;
    }

    /// From the window's thread. After this the capture thread doesn't touch the recorder.
    pub fn detachRecorder(c: *Capture) ?*record.AudioPoolSource {
        c.recorder_lock.lock();
        defer c.recorder_lock.unlock();
        defer c.recorder = null;
        return c.recorder;
    }

    fn setStatus(c: *Capture, status: Status) void {
        c.status.store(status, .release);
        if (0 == win32.PostMessageW(c.hwnd, status_msg, c.id, 0)) win32.panicWin32("PostMessage(capture status)", win32.GetLastError());
    }

    /// Ends the capture with a message for the user.
    fn fail(c: *Capture, comptime fmt: []const u8, args: anytype) error{Failed} {
        c.failure = .init(fmt, args);
        c.setStatus(.failed);
        return error.Failed;
    }

    /// Fails with a message for the user if `hr` failed: plain words for what we expect to
    /// happen, otherwise what failed and the code.
    fn check(c: *Capture, hr: win32.HRESULT, comptime what: []const u8) error{Failed}!void {
        if (!hr.failed) return;
        const noun = c.endpoint.noun();
        if (hr == hresult_not_found) return c.fail("The {s} isn't connected", .{noun});
        if (hr == win32.E_ACCESSDENIED) return switch (c.endpoint) {
            .microphone => c.fail("Windows is blocking microphone access, see Settings > Privacy > Microphone", .{}),
            .output => c.fail("Windows denied access to the output", .{}),
        };
        if (hr == win32.AUDCLNT_E_DEVICE_INVALIDATED) return c.fail("The {s} was disconnected", .{noun});
        if (hr == win32.AUDCLNT_E_DEVICE_IN_USE) return c.fail("Another app is using the {s} exclusively", .{noun});
        return c.fail(what ++ " failed for the {s}, error 0x{X:0>8}", .{ noun, @as(u32, @bitCast(hr)) });
    }
};

/// HRESULT_FROM_WIN32(ERROR_NOT_FOUND): what GetDevice returns for a device that's gone.
const hresult_not_found: win32.HRESULT = @bitCast(@as(u32, 0x80070490));

fn run(c: *Capture) void {
    // Like main, leaves room to report a stack overflow on this thread.
    var guarantee: u32 = wintrace.stack_guarantee;
    if (0 == wintrace.SetThreadStackGuarantee(&guarantee)) win32.panicWin32("SetThreadStackGuarantee", win32.GetLastError());
    {
        const hr = win32.CoInitializeEx(null, win32.COINIT_MULTITHREADED);
        if (hr.failed) win32.panicHresult("CoInitializeEx", hr);
    }
    defer win32.CoUninitialize();
    // Real-time scheduling from the Multimedia Class Scheduler (MMCSS), Microsoft's way for
    // audio threads: we must keep up with the device or audio is lost.
    var task_index: u32 = 0;
    const mmcss = win32.AvSetMmThreadCharacteristicsW(win32.L("Pro Audio"), &task_index) orelse {
        c.fail("Couldn't give the microphone's thread audio priority (MMCSS error {d})", .{@intFromEnum(win32.GetLastError())}) catch {};
        return;
    };
    defer if (0 == win32.AvRevertMmThreadCharacteristics(mmcss)) win32.panicWin32("AvRevertMmThreadCharacteristics", win32.GetLastError());
    capture(c) catch |e| switch (e) {
        error.Failed => {}, // reported
    };
}

fn capture(c: *Capture) error{Failed}!void {
    var enumerator: *win32.IMMDeviceEnumerator = undefined;
    try c.check(win32.CoCreateInstance(win32.CLSID_MMDeviceEnumerator, null, win32.CLSCTX_ALL, win32.IID_IMMDeviceEnumerator, @ptrCast(&enumerator)), "Creating the device enumerator");
    defer _ = enumerator.IUnknown.Release();

    var device: ?*win32.IMMDevice = null;
    try c.check(enumerator.GetDevice(c.device_id, &device), "Finding the device");
    defer _ = device.?.IUnknown.Release();

    var client2: *win32.IAudioClient2 = undefined;
    try c.check(device.?.Activate(win32.IID_IAudioClient2, win32.CLSCTX_ALL, null, @ptrCast(&client2)), "Opening the device");
    defer _ = client2.IUnknown.Release();
    const client = &client2.IAudioClient;

    // Loopback: what Windows mixes to the output, captured as it plays.
    const loopback = c.endpoint == .output;
    // Raw: the audio engine skips the effects (noise suppression, echo cancellation and the
    // like) between the device and us, where the device allows it. Before Initialize, and
    // before GetMixFormat, which can depend on it. Microphones only: loopback captures the
    // mix, before the output's own effects.
    c.raw = !loopback and try rawSupported(c, device.?);
    if (c.raw) {
        const props: win32.AudioClientProperties = .{
            .cbSize = @sizeOf(win32.AudioClientProperties),
            .bIsOffload = 0,
            .eCategory = .Other,
            .Options = win32.AUDCLNT_STREAMOPTIONS_RAW,
        };
        try c.check(client2.SetClientProperties(&props), "Asking for raw audio");
    }

    var format: ?*win32.WAVEFORMATEX = null;
    try c.check(client.GetMixFormat(&format), "Getting the format");
    defer win32.CoTaskMemFree(format);
    const f = format.?;
    const sample: SampleType = sampleType(f) orelse
        return c.fail("Unsupported {s} format (tag {d}, {d} bits)", .{ c.endpoint.noun(), f.wFormatTag, f.wBitsPerSample });
    // TODO: record devices with more than 8 channels. FLAC stores at most 8 per file; they can
    // be supported by writing several files per track (channels 1-8, 9-16, ...), all fed by
    // the track's one aligner so they stay in sync. See TODO.md.
    if (f.nChannels > flac.max_channels)
        return c.fail("Devices with more than {d} channels aren't supported yet (this one has {d})", .{ flac.max_channels, f.nChannels });

    const data_event = win32.CreateEventW(null, 0, 0, null) orelse win32.panicWin32("CreateEvent", win32.GetLastError());
    defer win32.closeHandle(data_event);
    // How late this thread can be before audio is lost. Latency doesn't matter to us (packets
    // still come every engine period, ~10ms, whatever the buffer size), so it's generous.
    const stream_flags = win32.AUDCLNT_STREAMFLAGS_EVENTCALLBACK | if (loopback) win32.AUDCLNT_STREAMFLAGS_LOOPBACK else 0;
    try c.check(client.Initialize(.SHARED, stream_flags, 1000 * hns_per_ms, 0, f, null), "Starting");
    try c.check(client.SetEventHandle(data_event), "Starting");
    var capture_client: *win32.IAudioCaptureClient = undefined;
    try c.check(client.GetService(win32.IID_IAudioCaptureClient, @ptrCast(&capture_client)), "Starting");
    defer _ = capture_client.IUnknown.Release();
    // Loopback delivers nothing while nothing plays, so packets (and their timestamps) would
    // stop; silence played into the output keeps them coming, as OBS does. Stopped after the
    // capture (defers run in reverse).
    const silence: ?*win32.IAudioClient = if (loopback) try playSilence(c, device.?, f) else null;
    defer if (silence) |s| {
        _ = s.Stop();
        _ = s.IUnknown.Release();
    };
    try c.check(client.Start(), "Starting");
    defer _ = client.Stop();
    // A format sampleType knows, so audioFormat does too.
    c.format = audioFormat(f).?;
    c.input = .{ .sample = sample, .channels = @intCast(f.nChannels), .rate = f.nSamplesPerSec, .block_align = f.nBlockAlign };
    c.setStatus(.live);

    // Sized by the device's channels: allocated once per capture.
    const filters = c.gpa.alloc(KWeighting, f.nChannels) catch @panic("out of memory");
    defer c.gpa.free(filters);
    @memset(filters, .init(@floatFromInt(f.nSamplesPerSec)));
    const frame = c.gpa.alloc(f32, f.nChannels) catch @panic("out of memory");
    defer c.gpa.free(frame);
    var levels: Levels = .{ .frames_per_bucket = f.nSamplesPerSec * bb.Meter.bucket_ms / 1000, .filters = filters, .frame = frame };
    const handles = [_]?win32.HANDLE{ c.stop_event, data_event };
    while (true) {
        // The device delivers a packet every ~10ms even in silence; two seconds without one
        // means it stopped.
        const result = win32.WaitForMultipleObjects(handles.len, &handles, 0, 2000);
        switch (@intFromEnum(result)) {
            0 => return, // stop_event
            1 => {},
            @intFromEnum(win32.WAIT_TIMEOUT) => return c.fail("The {s} stopped sending audio", .{c.endpoint.noun()}),
            else => win32.panicWin32("WaitForMultipleObjects", win32.GetLastError()),
        }
        while (true) {
            var packet_frames: u32 = undefined;
            try c.check(capture_client.GetNextPacketSize(&packet_frames), "Reading");
            if (packet_frames == 0) break;
            var data: ?*u8 = null;
            var frames: u32 = undefined;
            var flags: u32 = undefined;
            var device_position: u64 = undefined;
            var qpc: u64 = undefined;
            try c.check(capture_client.GetBuffer(&data, &frames, &flags, &device_position, &qpc), "Reading");
            // TODO: show lost audio on the track (recording.json counts it: gaps, gap_frames).
            const silent = flags & @as(u32, @bitCast(win32.AUDCLNT_BUFFERFLAGS_SILENT)) != 0;
            const bytes: ?[]const u8 = if (silent) null else @as([*]const u8, @ptrCast(data.?))[0 .. @as(usize, frames) * f.nBlockAlign];
            if (bytes) |b| levels.add(&c.meter, sample, b) else levels.addSilence(&c.meter, frames);
            {
                c.recorder_lock.lock();
                defer c.recorder_lock.unlock();
                if (c.recorder) |r| r.push(bytes, frames, device_position, qpc, .{
                    .timestamp_error = flags & @as(u32, @bitCast(win32.AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR)) != 0,
                    .discontinuity = flags & @as(u32, @bitCast(win32.AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY)) != 0,
                });
            }
            try c.check(capture_client.ReleaseBuffer(frames), "Reading");
        }
    }
}

const hns_per_ms = 10_000;

/// Starts a stream of silence into the output, which keeps its loopback capture delivering
/// packets while nothing else plays. One buffer of silence, then it runs dry: the stream stays
/// open and running, which is all the audio engine needs to keep mixing the output.
fn playSilence(c: *Capture, device: *win32.IMMDevice, f: *const win32.WAVEFORMATEX) error{Failed}!*win32.IAudioClient {
    var client: *win32.IAudioClient = undefined;
    try c.check(device.Activate(win32.IID_IAudioClient, win32.CLSCTX_ALL, null, @ptrCast(&client)), "Opening the device to play silence");
    errdefer _ = client.IUnknown.Release();
    try c.check(client.Initialize(.SHARED, 0, 1000 * hns_per_ms, 0, f, null), "Starting silence");
    var frames: u32 = undefined;
    try c.check(client.GetBufferSize(&frames), "Starting silence");
    var render: *win32.IAudioRenderClient = undefined;
    try c.check(client.GetService(win32.IID_IAudioRenderClient, @ptrCast(&render)), "Starting silence");
    defer _ = render.IUnknown.Release();
    var data: ?*u8 = null;
    try c.check(render.GetBuffer(frames, &data), "Starting silence");
    try c.check(render.ReleaseBuffer(frames, @bitCast(win32.AUDCLNT_BUFFERFLAGS_SILENT)), "Starting silence");
    try c.check(client.Start(), "Starting silence");
    return client;
}

/// Whether the device can deliver raw audio, see AUDCLNT_STREAMOPTIONS_RAW.
fn rawSupported(c: *Capture, device: *win32.IMMDevice) error{Failed}!bool {
    var props: ?*win32.IPropertyStore = null;
    try c.check(device.OpenPropertyStore(win32.STGM_READ, &props), "Reading the properties");
    defer _ = props.?.IUnknown.Release();
    var value: win32.PROPVARIANT = std.mem.zeroes(win32.PROPVARIANT);
    try c.check(props.?.GetValue(&win32.PKEY_Devices_AudioDevice_RawProcessingSupported, &value), "Reading the properties");
    defer _ = win32.PropVariantClear(&value);
    // Absent (VT_EMPTY) when the driver doesn't say: then it isn't supported.
    const v = &value.Anonymous.Anonymous;
    return v.vt == win32.VT_BOOL and v.Anonymous.boolVal != 0;
}

/// Null for formats other than integer PCM and float.
fn audioFormat(f: *const win32.WAVEFORMATEX) ?bb.AudioFormat {
    var sample: bb.AudioFormat.SampleKind = switch (f.wFormatTag) {
        win32.WAVE_FORMAT_PCM => .integer,
        win32.WAVE_FORMAT_IEEE_FLOAT => .float,
        win32.WAVE_FORMAT_EXTENSIBLE => undefined,
        else => return null,
    };
    var bits = f.wBitsPerSample;
    if (f.wFormatTag == win32.WAVE_FORMAT_EXTENSIBLE) {
        const ext: *align(1) const win32.WAVEFORMATEXTENSIBLE = @ptrCast(f);
        const sub = std.mem.asBytes(&ext.SubFormat);
        sample = if (std.mem.eql(u8, sub, std.mem.asBytes(win32.CLSID_KSDATAFORMAT_SUBTYPE_IEEE_FLOAT)))
            .float
        else if (std.mem.eql(u8, sub, std.mem.asBytes(win32.CLSID_KSDATAFORMAT_SUBTYPE_PCM)))
            .integer
        else
            return null;
        // E.g. 24 bits carried in 32.
        if (ext.Samples.wValidBitsPerSample != 0) bits = ext.Samples.wValidBitsPerSample;
    }
    return .{ .sample = sample, .bits = bits, .rate = f.nSamplesPerSec, .channels = f.nChannels };
}

pub const SampleType = enum { f32, i16, i24, i32 };

fn sampleType(f: *const win32.WAVEFORMATEX) ?SampleType {
    const is_float, const is_pcm = switch (f.wFormatTag) {
        win32.WAVE_FORMAT_IEEE_FLOAT => .{ true, false },
        win32.WAVE_FORMAT_PCM => .{ false, true },
        win32.WAVE_FORMAT_EXTENSIBLE => blk: {
            const ext: *const win32.WAVEFORMATEXTENSIBLE = @ptrCast(f);
            break :blk .{
                std.mem.eql(u8, std.mem.asBytes(&ext.SubFormat), std.mem.asBytes(win32.CLSID_KSDATAFORMAT_SUBTYPE_IEEE_FLOAT)),
                std.mem.eql(u8, std.mem.asBytes(&ext.SubFormat), std.mem.asBytes(win32.CLSID_KSDATAFORMAT_SUBTYPE_PCM)),
            };
        },
        else => return null,
    };
    if (is_float and f.wBitsPerSample == 32) return .f32;
    if (is_pcm) return switch (f.wBitsPerSample) {
        16 => .i16,
        24 => .i24,
        32 => .i32,
        else => null,
    };
    return null;
}

/// Turns samples into a meter's buckets: the largest magnitude over all channels, and the
/// momentary loudness (ITU-R BS.1770: K-weighted, summed over channels, averaged over the
/// last Meter.loudness_ms).
const Levels = struct {
    frames_per_bucket: u32,
    /// One per channel.
    filters: []KWeighting,
    /// Room for one frame's samples, one per channel.
    frame: []f32,
    peak: f32 = 0,
    /// Sum over this bucket's frames of the K-weighted samples squared, summed over channels.
    energy: f64 = 0,
    frames: u32 = 0,
    /// Each recent bucket's mean square, for the loudness window.
    window: [window_len]f64 = @splat(0),
    window_next: usize = 0,

    const window_len = bb.Meter.loudness_ms / bb.Meter.bucket_ms;

    /// `samples` is one frame, a sample per channel, 1.0 being full scale.
    fn addFrame(l: *Levels, meter: *bb.Meter, samples: []const f32) void {
        for (samples, l.filters) |s, *filter| {
            l.peak = @max(l.peak, @abs(s));
            const z = filter.apply(s);
            l.energy += z * z;
        }
        l.frames += 1;
        if (l.frames < l.frames_per_bucket) return;

        l.window[l.window_next] = l.energy / @as(f64, @floatFromInt(l.frames));
        l.window_next = (l.window_next + 1) % window_len;
        var sum: f64 = 0;
        for (l.window) |ms| sum += ms;
        meter.push(l.peak, @floatCast(@sqrt(sum / window_len)));
        l.peak = 0;
        l.energy = 0;
        l.frames = 0;
    }

    fn addSilence(l: *Levels, meter: *bb.Meter, frames: u32) void {
        // Zeros still pass through the filters, they have memory.
        @memset(l.frame, 0);
        for (0..frames) |_| l.addFrame(meter, l.frame);
    }

    fn add(l: *Levels, meter: *bb.Meter, sample: SampleType, bytes: []const u8) void {
        switch (sample) {
            inline else => |t| {
                const size = sampleSize(t);
                const frame_size = size * l.frame.len;
                var i: usize = 0;
                while (i + frame_size <= bytes.len) : (i += frame_size) {
                    for (l.frame, 0..) |*s, ch| s.* = sampleValue(t, bytes[i + ch * size ..][0..size]);
                    l.addFrame(meter, l.frame);
                }
            },
        }
    }
};

/// ITU-R BS.1770's K-weighting for one channel: a high shelf (the head's effect) then a high
/// pass, as two biquads. Coefficients for any sample rate, as libebur128 derives them.
const KWeighting = struct {
    shelf: Biquad,
    high_pass: Biquad,

    fn init(rate: f64) KWeighting {
        const shelf: Biquad = blk: {
            const f0 = 1681.974450955533;
            const gain_db = 3.999843853973347;
            const q = 0.7071752369554196;
            const k = @tan(std.math.pi * f0 / rate);
            const vh = std.math.pow(f64, 10, gain_db / 20.0);
            const vb = std.math.pow(f64, vh, 0.4996667741545416);
            const a0 = 1 + k / q + k * k;
            break :blk .{
                .b0 = (vh + vb * k / q + k * k) / a0,
                .b1 = 2 * (k * k - vh) / a0,
                .b2 = (vh - vb * k / q + k * k) / a0,
                .a1 = 2 * (k * k - 1) / a0,
                .a2 = (1 - k / q + k * k) / a0,
            };
        };
        const high_pass: Biquad = blk: {
            const f0 = 38.13547087602444;
            const q = 0.5003270373238773;
            const k = @tan(std.math.pi * f0 / rate);
            const a0 = 1 + k / q + k * k;
            break :blk .{ .b0 = 1, .b1 = -2, .b2 = 1, .a1 = 2 * (k * k - 1) / a0, .a2 = (1 - k / q + k * k) / a0 };
        };
        return .{ .shelf = shelf, .high_pass = high_pass };
    }

    fn apply(k: *KWeighting, x: f32) f64 {
        return k.high_pass.apply(k.shelf.apply(x));
    }
};

/// Transposed direct form II.
const Biquad = struct {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
    z1: f64 = 0,
    z2: f64 = 0,

    fn apply(f: *Biquad, x: f64) f64 {
        const y = f.b0 * x + f.z1;
        f.z1 = f.b1 * x - f.a1 * y + f.z2;
        f.z2 = f.b2 * x - f.a2 * y;
        return y;
    }
};

pub fn sampleSize(comptime t: SampleType) comptime_int {
    return switch (t) {
        .f32, .i32 => 4,
        .i16 => 2,
        .i24 => 3,
    };
}

/// A sample, 1.0 being full scale: for integers, the largest positive value, so a sample at
/// either end of the range has a magnitude of 1.0 or more, counted as clipped.
fn sampleValue(comptime t: SampleType, b: *const [sampleSize(t)]u8) f32 {
    return switch (t) {
        .f32 => @bitCast(std.mem.readInt(u32, b, .little)),
        inline .i16, .i24, .i32 => |int| blk: {
            const I = switch (int) {
                .i16 => i16,
                .i24 => i24,
                .i32 => i32,
                else => comptime unreachable,
            };
            const v: f64 = @floatFromInt(std.mem.readInt(I, b, .little));
            break :blk @floatCast(v / std.math.maxInt(I));
        },
    };
}

const std = @import("std");
const win32 = @import("win32").everything;
const wintrace = @import("wintrace");
const bb = @import("bb.zig");
const flac = @import("flac.zig");
const record = @import("record.zig");
