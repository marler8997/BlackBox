//! Black Box app logic, independent of the platform layer (src/win32.zig).
//! The platform layer feeds in events and facts (time, input, disk info) and provides a
//! painter; this module decides what's on screen and where.

/// Facts about the disk recordings go to, supplied by the platform layer.
pub const Disk = struct {
    /// Folder recordings are saved to.
    out_dir: []const u8 = "",
    is_system: bool = false,
    free: u64 = 0,
    total: u64 = 0,
};

pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn contains(r: Rect, x: i32, y: i32) bool {
        return x >= r.left and x < r.right and y >= r.top and y < r.bottom;
    }
    pub fn inset(r: Rect, dx: i32, dy: i32) Rect {
        return .{ .left = r.left + dx, .top = r.top + dy, .right = r.right - dx, .bottom = r.bottom - dy };
    }
};

/// Straight (not premultiplied) color. `a` is opacity: every item picks its own.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,
};

pub const Font = enum {
    title,
    normal,
    small,
    /// Bold, for numbers in badges. The platform centers digits in their rect.
    badge,
    /// For `Icon`s, see Painter.icon.
    icon,
    icon_small,

    /// Pixel size at 96 DPI.
    pub fn px(f: Font) i32 {
        return switch (f) {
            .title => 28,
            .normal => 16,
            .small => 13,
            .badge => 10,
            .icon => 30,
            .icon_small => 16,
        };
    }
};

pub const Align = enum { left, center, right };

pub const Icon = enum { screen, speaker, webcam, microphone, headphones, headset, handset, display, pin, pinned, collapse, expand, more, minimize, check };

const color = struct {
    const window: Color = .{ .r = 24, .g = 24, .b = 28, .a = 240 };
    const divider: Color = .{ .r = 255, .g = 255, .b = 255, .a = 40 };
    const text: Color = .{ .r = 235, .g = 235, .b = 240 };
    const dim: Color = .{ .r = 175, .g = 175, .b = 185 };
    /// Quieter than dim: supporting numbers beside what they explain.
    const faint: Color = .{ .r = 125, .g = 125, .b = 135 };
    const amber: Color = .{ .r = 240, .g = 170, .b = 40 };
    const button: Color = .{ .r = 70, .g = 70, .b = 82, .a = 235 };
    const button_hot: Color = .{ .r = 95, .g = 95, .b = 110, .a = 245 };
    const button_pressed: Color = .{ .r = 58, .g = 58, .b = 68, .a = 245 };
    const tile: Color = .{ .r = 255, .g = 255, .b = 255, .a = 18 };
    const tile_hot: Color = .{ .r = 255, .g = 255, .b = 255, .a = 40 };
    const tile_pressed: Color = .{ .r = 255, .g = 255, .b = 255, .a = 26 };
    const video: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const menu: Color = .{ .r = 50, .g = 50, .b = 58, .a = 250 };
    /// Recording, and audio that clipped: nothing else is this red.
    const record: Color = .{ .r = 230, .g = 40, .b = 40 };
    const disabled: Color = .{ .r = 110, .g = 110, .b = 118 };
    /// A track's name over its lane, see paintTrackLabel.
    const label: Color = .{ .r = 235, .g = 235, .b = 240, .a = 170 };
    const label_shadow: Color = .{ .r = 0, .g = 0, .b = 0, .a = 150 };
    /// A menu row's checkmark: already added, or on.
    const check: Color = .{ .r = 90, .g = 200, .b = 120 };
    /// Black Box's accent, after the orange of flight recorders (the "black boxes" it's named
    /// after), muted to sit quietly in the dark theme: behind a menu row's tag ("Default").
    const accent: Color = .{ .r = 160, .g = 88, .b = 45 };
    /// Behind the levels' loud and close-to-clipping zones, see paintLevels.
    const loud_band: Color = .{ .r = 225, .g = 205, .b = 70, .a = 22 };
    const hot_band: Color = .{ .r = 230, .g = 40, .b = 40, .a = 30 };
};

/// The kinds of things Black Box can record.
pub const SourceKind = enum {
    screen,
    webcam,
    system_audio,
    microphone,

    fn isVideo(k: SourceKind) bool {
        return switch (k) {
            .screen, .webcam => true,
            .system_audio, .microphone => false,
        };
    }

    /// Whether adding one first asks which device.
    fn hasDevice(k: SourceKind) bool {
        return switch (k) {
            .microphone, .system_audio, .webcam => true,
            // TODO: pick which screen/window.
            .screen => false,
        };
    }

    /// Shown in a device menu that has none.
    fn noDevices(k: SourceKind) []const u8 {
        return switch (k) {
            .screen => "No screens found",
            .system_audio => "No outputs found",
            .webcam => "No webcams found",
            .microphone => "No microphones found",
        };
    }

    fn title(k: SourceKind) []const u8 {
        return switch (k) {
            .screen => "Screen",
            .system_audio => "System Audio",
            .webcam => "Webcam",
            .microphone => "Microphone",
        };
    }
    fn icon(k: SourceKind) Icon {
        return switch (k) {
            .screen => .screen,
            .system_audio => .speaker,
            .webcam => .webcam,
            .microphone => .microphone,
        };
    }

    /// Beside the add buttons while the mouse is over this kind's.
    fn addHint(k: SourceKind) []const u8 {
        return switch (k) {
            .screen => "Add Screen",
            .system_audio => "Add System Audio",
            .webcam => "Add Webcam",
            .microphone => "Add Microphone",
        };
    }

    /// Not recordable yet: its add button opens a menu saying so, see Menu.todo.
    fn todo(k: SourceKind) ?[]const u8 {
        return switch (k) {
            .screen => "TODO: implement screen recording",
            .webcam, .system_audio, .microphone => null,
        };
    }
};

/// The add buttons, left to right.
const add_order = [_]SourceKind{ .microphone, .system_audio, .screen, .webcam };

/// What the mouse is over.
const Hot = union(enum) {
    none,
    button,
    /// The add button for a kind of source.
    add: SourceKind,
    pin_button,
    collapse_button,
    more_button,
    minimize_button,
    /// A track's icon (by source id), which opens its menu.
    track: u32,
};

/// A menu the platform shows in its own popup window, so it can extend past ours (even when
/// collapsed). Its painting and input use the popup's coordinates.
pub const Menu = union(enum) {
    more,
    /// For the source with this id.
    track: u32,
    /// The devices to add a source of this kind from, see takeDeviceListRequest.
    devices: SourceKind,
    /// This kind can't be recorded yet (SourceKind.todo).
    todo: SourceKind,
};

/// Something to capture from, as the platform lists it. Both strings are allocated with the
/// allocator given to init, and freed by whoever holds the Device.
pub const Device = struct {
    /// For the user, e.g. "Microphone (USB Audio)".
    name: []const u8,
    /// The platform's own, for opening it.
    id: []const u8,
    /// The format it runs at, if the platform knows it.
    format: ?AudioFormat,
    /// What it physically is, if the platform knows: its icon.
    form: ?Form = null,
    /// The system's default device of its kind.
    default: bool = false,

    pub const Form = enum {
        speakers,
        headphones,
        /// Headphones with a microphone.
        headset,
        /// A phone-style handset.
        handset,
        microphone,
        /// A monitor or TV's speakers (HDMI, DisplayPort).
        display,
    };

    fn deinit(d: Device) void {
        gpa.free(d.name);
        gpa.free(d.id);
    }

    /// The device menu's order: by form (as Form lists them, unknown last), then by name
    /// ignoring case.
    fn before(a: *const Device, b: *const Device) bool {
        const fa = if (a.form) |f| @intFromEnum(f) else std.enums.values(Form).len;
        const fb = if (b.form) |f| @intFromEnum(f) else std.enums.values(Form).len;
        if (fa != fb) return fa < fb;
        return std.ascii.lessThanIgnoreCase(a.name, b.name);
    }

    /// Its form's icon, else its kind's. A headset is both an input and an output (each its
    /// own device, with the same form): its microphone shows the headset with its boom mic,
    /// its output just the headphones, so their tracks tell apart.
    fn icon(d: *const Device, kind: SourceKind) Icon {
        const form = d.form orelse return kind.icon();
        return switch (form) {
            .speakers => .speaker,
            .headphones, .headset => if (kind == .microphone) .headset else .headphones,
            .handset => .handset,
            .microphone => .microphone,
            .display => .display,
        };
    }
};

/// An audio stream's format.
pub const AudioFormat = struct {
    sample: SampleKind,
    /// Significant bits per sample: 24 carried in 32 is 24.
    bits: u16,
    rate: u32,
    channels: u16,

    pub const SampleKind = enum { integer, float };

    const parts = [_]maxstring.StringPart(.utf8){
        .{ .runtime_value = .{ .name = "bits", .type = u16 } },
        .{ .static = "-bit " },
        .{ .runtime_value = .{ .name = "sample", .type = SampleKind } },
        .{ .static = ", " },
        .{ .runtime_value = .{ .name = "rate", .type = u32 } },
        .{ .static = " Hz, " },
        .{ .runtime_value = .{ .name = "channels", .type = u16 } },
        .{ .static = " ch" },
    };
    /// E.g. "24-bit integer, 48000 Hz, 2 ch".
    pub const Text = maxstring.MaxString(.utf8, .no_sentinel, &parts);
    const CapturedAsText = maxstring.MaxString(.utf8, .no_sentinel, &([_]maxstring.StringPart(.utf8){.{ .static = "Captured as " }} ++ parts));

    pub fn text(f: AudioFormat) Text.Formatted {
        return Text.format(.{ .bits = f.bits, .sample = f.sample, .rate = f.rate, .channels = f.channels });
    }
    fn capturedAsText(f: AudioFormat) CapturedAsText.Formatted {
        return CapturedAsText.format(.{ .bits = f.bits, .sample = f.sample, .rate = f.rate, .channels = f.channels });
    }
};

/// A track's menu.
const TrackItem = enum {
    clear_clips,
    remove,
};

/// The lines of a track's menu.
const TrackRow = enum {
    name,
    device_format,
    captured_as,
    /// Video: what the camera sends.
    camera_format,
    effects,
    /// Video: what encodes it, and where.
    encoder,
    /// Video: the GPU encoding it.
    gpu,
    /// Video: the encoder's target bitrate.
    bitrate,
    /// Video: frames encoded and dropped.
    frames,
    /// Debug: the recording ring's size.
    buffer,
    clips,
    remove,
};

/// The open track menu's rows for `src`: those its kind has.
fn trackRows(src: *const Source, buf: *[std.enums.values(TrackRow).len]TrackRow) []const TrackRow {
    var n: usize = 0;
    for (std.enums.values(TrackRow)) |row| {
        // By kind only, never by state: the same track always has the same rows, those that
        // don't apply right now are disabled.
        const applies = switch (row) {
            .name, .remove, .captured_as, .buffer => true,
            // A webcam's device has no audio format.
            .device_format => src.kind.hasDevice() and !src.kind.isVideo(),
            .effects, .clips => !src.kind.isVideo(),
            .encoder, .gpu, .bitrate, .frames => src.kind.isVideo(),
            .camera_format => src.kind == .webcam,
        };
        if (!applies) continue;
        buf[n] = row;
        n += 1;
    }
    return buf[0..n];
}

/// The "â‹¯" menu.
const MoreItem = enum {
    exclude_from_capture,
    quit,

    pub fn title(i: MoreItem) []const u8 {
        return switch (i) {
            .exclude_from_capture => "Exclude Window from Capture",
            .quit => "Quit",
        };
    }
};

/// One thing being recorded.
pub const Source = struct {
    kind: SourceKind,
    /// Unique for the life of the program; the platform matches its captures to sources by it.
    id: u32,
    /// Which one, for kinds that have devices (SourceKind.hasDevice).
    device: ?Device,
    status: SourceStatus = .starting,
    /// Owned by the platform's capture, see setSourceMeter.
    meter: ?*const Meter = null,
    /// A webcam's frames so far, owned by its capture, see setSourceVideoCounts.
    video_counts: ?*const VideoCounts = null,
    /// The meter's clip count when the user last cleared the clip warning.
    clips_cleared: u32 = 0,
    /// Why recording this source failed, see setSourceRecordError.
    record_error: ?Message = null,
    /// Debug: its recording ring, while recording, see setSourceBuffer.
    buffer: ?Buffer = null,
    /// Where its track icon was last painted, for hit testing.
    track_button: Rect = empty_rect,

    /// Its level lane as last painted: its width and complete columns, see frameChanged.
    painted_width: u64 = 0,
    painted_columns: u64 = 0,

    /// What the user knows it as.
    pub fn name(s: *const Source) []const u8 {
        return if (s.device) |d| d.name else s.kind.title();
    }

    /// Its device's icon (what the device is), else its kind's.
    fn icon(s: *const Source) Icon {
        return if (s.device) |*d| d.icon(s.kind) else s.kind.icon();
    }

    /// Times it clipped since the user last cleared the warning. Sticky, so a clip isn't
    /// missed when it scrolls out of view, or happens while nobody's looking.
    /// A webcam's frames so far, none for other sources.
    fn frameCounts(s: *const Source) FrameCounts {
        const vc = s.video_counts orelse return .{};
        return .{ .encoded = vc.encoded.load(.monotonic), .dropped = vc.dropped.load(.monotonic) };
    }

    fn clips(s: *const Source) u32 {
        const meter = s.meter orelse return 0;
        return meter.clips.load(.monotonic) - s.clips_cleared;
    }
};

/// How capturing a source is going, as reported by the platform.
pub const SourceStatus = union(enum) {
    starting,
    live: Live,
    failed: Message,

    pub const Live = union(enum) {
        audio: AudioLive,
        video: VideoLive,
    };

    pub const AudioLive = struct {
        /// What we receive, which may differ from the device's (Device.format): Windows'
        /// shared mode converts.
        format: AudioFormat,
        /// Whether Windows' audio effects are bypassed. Not when the device doesn't allow it.
        raw: bool,
    };

    pub const VideoLive = struct {
        format: VideoFormat,
        /// The encoder's target, bits per second.
        bitrate: u32,
        path: EncodePath,
        encoder_buf: [64]u8 = undefined,
        encoder_len: u8 = 0,
        /// The GPU the encoder runs on (its adapter's name); none for software.
        gpu_buf: [64]u8 = undefined,
        gpu_len: u8 = 0,
        /// What the camera sends (e.g. "MJPG"), and whether it's converted for the encoder.
        camera_format_buf: [36]u8 = undefined,
        camera_format_len: u8 = 0,
        camera_converted: bool = false,

        pub fn encoder(v: *const VideoLive) []const u8 {
            return v.encoder_buf[0..v.encoder_len];
        }
        pub fn gpu(v: *const VideoLive) []const u8 {
            return v.gpu_buf[0..v.gpu_len];
        }
        pub fn cameraFormat(v: *const VideoLive) []const u8 {
            return v.camera_format_buf[0..v.camera_format_len];
        }
    };

    /// Where a video's frames are encoded.
    pub const EncodePath = enum {
        /// By the GPU, the frames never leaving it.
        gpu,
        /// By the GPU's encoder, from frames in system memory (it doesn't take textures).
        hardware,
        /// By the CPU.
        software,

        fn note(e: EncodePath) []const u8 {
            return switch (e) {
                .gpu => "GPU",
                .hardware => "Hardware",
                .software => "Software",
            };
        }
    };
};

/// A video stream's format: its size and frames per second (a fraction).
pub const VideoFormat = struct {
    width: u32,
    height: u32,
    fps_num: u32,
    fps_den: u32,

    /// E.g. "Captured as 1920x1080 at 30 fps", the rate rounded.
    const CapturedAsText = maxstring.MaxString(.utf8, .no_sentinel, &.{
        .{ .static = "Captured as " },
        .{ .runtime_value = .{ .name = "width", .type = u32 } },
        .{ .static = "x" },
        .{ .runtime_value = .{ .name = "height", .type = u32 } },
        .{ .static = " at " },
        .{ .runtime_value = .{ .name = "fps", .type = u32 } },
        .{ .static = " fps" },
    });

    fn capturedAsText(f: VideoFormat) CapturedAsText.Formatted {
        const fps = if (f.fps_den == 0) 0 else (f.fps_num + f.fps_den / 2) / f.fps_den;
        return CapturedAsText.format(.{ .width = f.width, .height = f.height, .fps = fps });
    }
};

/// Text for the user, in a fixed buffer so statuses can be copied around.
pub const Message = struct {
    buf: [200]u8 = undefined,
    len: u8 = 0,

    /// Truncates text that doesn't fit.
    pub fn init(comptime fmt: []const u8, args: anytype) Message {
        var m: Message = .{};
        const text = std.fmt.bufPrint(&m.buf, fmt, args) catch blk: {
            m.buf[m.buf.len - 3 ..].* = "...".*;
            break :blk &m.buf;
        };
        m.len = @intCast(text.len);
        return m;
    }
    pub fn slice(m: *const Message) []const u8 {
        return m.buf[0..m.len];
    }
};

/// Recent audio levels, a Bucket per `bucket_ms` of audio, newest last, and how often it
/// clipped. Written by one capture thread and read while painting, so the shared fields are
/// atomic. Levels are as recorded: no gain or scaling.
pub const Meter = struct {
    pub const bucket_ms = 10;
    /// How many buckets are kept, ~41 seconds.
    pub const len = 4096;
    /// Momentary loudness's window (ITU-R BS.1770 / EBU R128).
    pub const loudness_ms = 400;

    /// Each a Bucket, packed so a bucket is written in one store.
    buckets: [len]std.atomic.Value(u32) = @splat(.init(0)),
    /// Buckets written so far.
    count: std.atomic.Value(u64) = .init(0),
    /// How many times the audio clipped: each run of clipped buckets counts once.
    clips: std.atomic.Value(u32) = .init(0),
    /// Whether the last bucket clipped. Only the capture thread uses it.
    last_clipped: bool = false,

    pub const Bucket = packed struct(u32) {
        /// The largest sample magnitude, linear, `full` being full scale; `clipped` if any
        /// sample reached it.
        peak: u16,
        /// Momentary loudness (K-weighted, over the last loudness_ms) as a linear amplitude,
        /// `full` being 0 dB: in LUFS, 20 * log10(loudness / full) - 0.691.
        loudness: u16,

        pub const clipped = std.math.maxInt(u16);
        pub const full = clipped - 1;

        fn encode(v: f32) u16 {
            return @intFromFloat(@round(std.math.clamp(v, 0, 1) * full));
        }
    };

    /// `peak` is the largest sample magnitude in the bucket and `loudness` the momentary
    /// loudness's amplitude (see Bucket), 1.0 being full scale. Only the capture thread calls
    /// this.
    pub fn push(m: *Meter, peak: f32, loudness: f32) void {
        const clipped = peak >= 1.0;
        if (clipped and !m.last_clipped) _ = m.clips.fetchAdd(1, .monotonic);
        m.last_clipped = clipped;
        const b: Bucket = .{
            .peak = if (clipped) Bucket.clipped else @min(Bucket.encode(peak), Bucket.full),
            .loudness = Bucket.encode(loudness),
        };
        const n = m.count.raw;
        m.buckets[n % len].store(@bitCast(b), .monotonic);
        m.count.store(n + 1, .release);
    }

    /// Bucket `n`, which must have been written (n < count) and not overwritten since.
    pub fn bucket(m: *const Meter, n: u64) Bucket {
        return @bitCast(m.buckets[n % len].load(.monotonic));
    }
};

/// User settings. Will be saved and restored (not yet).
pub const Settings = struct {
    /// Hide our own window from screen capture, so it never appears in recordings.
    exclude_from_capture: bool = true,
    /// Keep the window above others, so it can sit beside the game as a monitor.
    always_on_top: bool = false,
    /// Shrink the window to just the controls.
    collapsed: bool = false,
};

/// Whether the platform managed to apply `Settings.exclude_from_capture`.
pub const CaptureExclusion = union(enum) {
    ok,
    /// This version of Windows can't exclude windows from capture.
    unsupported,
    failed: u32,
};

/// What Black Box is doing with recordings.
const Mode = union(enum) {
    idle,
    /// The user wants to be recording: the platform records to match (see isRecording).
    recording,
    /// Quit was asked for while recording or while a recording's files were still being
    /// finished: it closes once they are (see closeWhenFinished). How much they have left,
    /// once the platform has said (see setFinishingLeft).
    closing: ?FinishingLeft,
};

const State = struct {
    settings: Settings = .{},
    capture_exclusion: CaptureExclusion = .ok,
    mode: Mode = .idle,
    recording_error: ?Message = null,
    recording_elapsed_ms: ?u64 = null,
    disk: Disk = .{},
    /// What's being recorded, in the order added.
    sources: std.ArrayList(Source) = .empty,
    next_source_id: u32 = 1,
    mouse: ?Point = null,
    menu: ?Menu = null,
    /// The mouse in the menu's coordinates.
    menu_mouse: ?Point = null,
    menu_pressed: ?MenuItem = null,
    /// The button the left mouse button went down on, until it's released or the mouse moves
    /// off it, see onMouseUp.
    pressed: ?Hot = null,
    /// Quit or Force Quit was chosen, until the platform takes it (see takeQuitRequest): an
    /// event, not a state. Closing, the state, is Mode's.
    quit_requested: ?QuitRequest = null,
    /// Removing a track while recording: the platform asks the user first (see takeConfirm).
    confirm_requested: ?Confirm = null,
    /// Minimize was clicked; the platform minimizes the window, see takeMinimize.
    minimize_requested: bool = false,
    /// Where things were last painted, for hit testing.
    button: Rect = empty_rect,
    /// The add buttons (by SourceKind), and the group around them with its "+".
    add_buttons: [std.enums.values(SourceKind).len]Rect = @splat(empty_rect),
    add_group: Rect = empty_rect,
    pin_button: Rect = empty_rect,
    collapse_button: Rect = empty_rect,
    more_button: Rect = empty_rect,
    minimize_button: Rect = empty_rect,
    /// What the open devices menu lists. It lives only as long as the menu: listed fresh each
    /// time one opens (see takeDeviceListRequest) and freed when it closes, so it's never
    /// stale and we needn't watch for devices coming and going.
    devices: std.ArrayList(Device) = .empty,
    device_list_requested: ?SourceKind = null,
    /// The open menu's layout, from menuRect.
    menu_w: i32 = 0,
    menu_row_h: i32 = 1,
    /// The track's uncleared clips when its menu opened.
    track_menu_clips: u32 = 0,
    /// A webcam track's frames as its open menu last painted them: see menuChanged.
    track_menu_frames: FrameCounts = .{},
    /// The widest row note's text, from menuRect: notes are drawn as tags this wide.
    menu_note_w: i32 = 0,
    /// Live levels for the open devices menu's rows, one per device, from the platform (see
    /// setDeviceLevels). Gone when the menu closes.
    device_levels: ?[]const DeviceLevel = null,
};

/// A device's live peak level, 0 to 1 (full scale) as f32 bits, or no_level until it's known.
pub const DeviceLevel = std.atomic.Value(u32);
pub const no_level: u32 = std.math.maxInt(u32);

const Point = struct { x: i32, y: i32 };

const empty_rect: Rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };

var state: State = .{};
var gpa: std.mem.Allocator = undefined;

pub fn init(allocator: std.mem.Allocator) void {
    gpa = allocator;
    state = .{};
}

/// The platform stops its captures first.
pub fn deinit() void {
    _ = closeMenu();
    state.devices.deinit(gpa);
    for (state.sources.items) |s| if (s.device) |d| d.deinit();
    state.sources.deinit(gpa);
    state = undefined;
}

pub fn setDisk(d: Disk) void {
    state.disk = d;
}

pub fn settings() Settings {
    return state.settings;
}

pub fn setCaptureExclusion(result: CaptureExclusion) void {
    state.capture_exclusion = result;
}

// ---------------------------------------------------------------------------
// Input. Each returns true if the window needs repainting.
// ---------------------------------------------------------------------------

// Buttons act on release, like Windows' own: only if the press started on the same button
// and the mouse never left it, so a press can be abandoned by moving off before releasing.

pub fn onMouseMove(x: i32, y: i32) bool {
    const was = hot();
    state.mouse = .{ .x = x, .y = y };
    const now = hot();
    if (std.meta.eql(was, now)) return false;
    // Moving off the pressed button abandons the press, even if it comes back.
    state.pressed = null;
    return true;
}

pub fn onMouseLeave() bool {
    const was = hot();
    state.mouse = null;
    state.pressed = null;
    return was != .none;
}

pub fn onMouseDown(x: i32, y: i32) bool {
    state.mouse = .{ .x = x, .y = y };
    // A click outside the menu only closes it.
    if (closeMenu()) return true;
    const target = hitTest(x, y);
    if (target == .none) return false;
    // The record button does nothing while disabled, it can't be pressed.
    if (target == .button and !recordEnabled()) return false;
    state.pressed = target;
    return true;
}

/// Acts on the button if the press started on it. Returns true if anything changed.
pub fn onMouseUp(x: i32, y: i32) bool {
    state.mouse = .{ .x = x, .y = y };
    const pressed = state.pressed orelse return false;
    state.pressed = null;
    const target = hitTest(x, y);
    // Released elsewhere: the press is abandoned, just repaint it unpressed.
    if (!std.meta.eql(pressed, target)) return true;
    switch (target) {
        .none => unreachable,
        .button => return primaryAction(),
        .add => |kind| if (kind.todo() != null) {
            state.menu = .{ .todo = kind };
        } else if (kind.hasDevice()) {
            // Which device first.
            state.menu = .{ .devices = kind };
            state.menu_mouse = null;
            state.device_list_requested = kind;
        } else addSource(kind, null),
        .more_button => state.menu = .more,
        .pin_button => state.settings.always_on_top = !state.settings.always_on_top,
        .collapse_button => state.settings.collapsed = !state.settings.collapsed,
        .minimize_button => state.minimize_requested = true,
        .track => |id| {
            state.menu = .{ .track = id };
            const src = findSource(id).?;
            state.track_menu_clips = src.clips();
            state.track_menu_frames = src.frameCounts();
        },
    }
    return true;
}

fn removeSource(id: u32) void {
    for (state.sources.items, 0..) |s, i| if (s.id == id) {
        if (s.device) |d| d.deinit();
        _ = state.sources.orderedRemove(i);
        return;
    };
    unreachable;
}

/// Takes ownership of `device`.
fn addSource(kind: SourceKind, device: ?Device) void {
    state.sources.append(gpa, .{ .kind = kind, .id = state.next_source_id, .device = device }) catch @panic("out of memory");
    state.next_source_id += 1;
}

/// Which kind of device to list, when a devices menu opened since the last call. The
/// platform lists them all with addDevice right away, before showing the menu.
pub fn takeDeviceListRequest() ?SourceKind {
    defer state.device_list_requested = null;
    return state.device_list_requested;
}

/// Takes ownership of `device`. The list stays sorted (see Device.before), however the
/// platform orders them.
pub fn addDevice(device: Device) void {
    const at = for (state.devices.items, 0..) |*d, i| {
        if (device.before(d)) break i;
    } else state.devices.items.len;
    state.devices.insert(gpa, at, device) catch @panic("out of memory");
}

fn findSource(id: u32) ?*Source {
    for (state.sources.items) |*s| if (s.id == id) return s;
    return null;
}

/// What's being recorded, in the order added. The platform captures each one, matching its
/// captures to these by id after any input that changed something: starting captures for
/// new sources and stopping those whose source is gone.
pub fn sources() []const Source {
    return state.sources.items;
}

/// The platform's capture for this source keeps its levels here, until it calls this again
/// with null before stopping. Ignored if the source is gone.
pub fn setSourceMeter(id: u32, meter: ?*const Meter) void {
    if (findSource(id)) |s| s.meter = meter;
}

const FrameCounts = struct { encoded: u64 = 0, dropped: u64 = 0 };

/// A webcam's frames since its capture started, counted by its capture thread.
pub const VideoCounts = struct {
    encoded: std.atomic.Value(u64) = .init(0),
    /// Refused by the encoder (it was busy): not in the recording.
    dropped: std.atomic.Value(u64) = .init(0),
};

/// The platform's capture for this webcam counts its frames here, for as long as the source
/// exists. Ignored if the source is gone.
pub fn setSourceVideoCounts(id: u32, counts: *const VideoCounts) void {
    if (findSource(id)) |s| s.video_counts = counts;
}

/// Whether anything on screen changes by itself (live levels), so the platform paints a
/// frame for every one the display shows.
pub fn animating() bool {
    // The open menu's levels: frames are paced by our window's.
    if (menuAnimating()) return true;
    // Collapsed, only the top bar shows, and nothing in it changes by the frame (the status
    // is repainted with each disk refresh). The meters still fill, so their history is there
    // when expanded again.
    if (state.settings.collapsed) return false;
    // The elapsed time, on the timeline.
    if (state.mode == .recording) return true;
    for (state.sources.items) |s| {
        if (s.status == .live and !s.kind.isVideo()) return true;
    }
    return false;
}

/// While animating: whether a frame now would look any different from the last one painted.
/// The levels change only when a lane gains a column (about ten times a second, not at the
/// display's 60 or more), the time only each second. `elapsed_ms` is setRecordingElapsed's.
pub fn frameChanged(elapsed_ms: ?u64) bool {
    if (wholeSeconds(elapsed_ms) != wholeSeconds(state.recording_elapsed_ms)) return true;
    if (state.settings.collapsed) return false;
    for (state.sources.items) |src| {
        if (src.status != .live or src.kind.isVideo()) continue;
        const meter = src.meter orelse continue;
        if (levelColumns(meter.count.load(.acquire), src.painted_width) != src.painted_columns) return true;
    }
    return false;
}

fn wholeSeconds(ms: ?u64) ?u64 {
    return if (ms) |m| m / 1000 else null;
}

/// Ignored if the source is gone.
pub fn setSourceStatus(id: u32, status: SourceStatus) void {
    if (findSource(id)) |s| s.status = status;
}

pub fn onKeyActivate() bool {
    return primaryAction();
}

/// Whether a press here should move or resize the window. Not while the menu is open: then
/// any click just closes it.
pub fn isDragArea(x: i32, y: i32) bool {
    return state.menu == null and hitTest(x, y) == .none;
}

/// Quitting, once chosen.
pub const QuitRequest = enum {
    /// The platform closes the window, once any recording's files are finished (see
    /// closeWhenFinished).
    quit,
    /// Force Quit (Quit, while closing): the platform ends now, without waiting for the files.
    /// They're left as a crash leaves them: `blackbox recover` finishes them.
    force_quit,
};

/// Quit or Force Quit, if one was chosen since the last call. Taken once: kept, every input
/// after would quit again (closing the menu, skipping the rest of what it changed).
pub fn takeQuitRequest() ?QuitRequest {
    defer state.quit_requested = null;
    return state.quit_requested;
}

/// How much finishing a recording's files has left: the journal it has yet to read, and if
/// it can be told yet (from how fast that's going down), about how long.
pub const FinishingLeft = struct { bytes: u64, seconds: ?u64 };

/// While closing, the platform says how much finishing the files has left, now and then:
/// shown in the top bar and Force Quit's note.
pub fn setFinishingLeft(left: FinishingLeft) void {
    std.debug.assert(state.mode == .closing);
    state.mode = .{ .closing = left };
}

/// E.g. "12.4 MB left, about 9 seconds": fmtBytes's and fmtDuration's.
fn fmtFinishingLeft(left: FinishingLeft) std.fmt.Alt(FinishingLeft, formatFinishingLeft) {
    return .{ .data = left };
}
fn formatFinishingLeft(left: FinishingLeft, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("{f} left", .{fmtBytes(left.bytes)});
    if (left.seconds) |sec| try w.print(", about {f}", .{fmtDuration(sec)});
}

/// Room for any fmtFinishingLeft, whatever its u64s: at most "18446744.1 TB left, about
/// 5,124,095,576,030,431 hours" (57 bytes), see its test.
const finishing_left_max = 64;

/// A long fmtFinishingLeft, for the note's width, so it doesn't change as the numbers go (one
/// longer, from an absurd estimate, is clipped).
const finishing_left_reserve = "999.9 MB left, about 9 hours 59 minutes";

/// While the open menu needs more said than it has room for: a note for the platform to show
/// in a popup of its own, beside the menu. The "⋯" menu while closing, about Force Quit.
pub fn menuNote() ?Note {
    const menu = state.menu orelse return null;
    if (menu != .more) return null;
    const finishing_left = switch (state.mode) {
        .closing => |left| left,
        .idle, .recording => return null,
    };
    var note: Note = .{};
    if (finishing_left) |left| {
        note.left_len = (std.fmt.bufPrint(&note.left_buf, "{f}", .{fmtFinishingLeft(left)}) catch unreachable).len;
    }
    return note;
}

/// Force Quit's note: how much is left (once known), then what Force Quit does.
pub const Note = struct {
    left_buf: [finishing_left_max]u8 = undefined,
    left_len: usize = 0,

    const lines = [_][]const u8{
        "Black Box quits once the recording's",
        "files are finished.",
        "Force Quit quits now, leaving them",
        "unfinished: blackbox recover finishes",
        "them later.",
    };

    /// The lines, the first how much is left (empty until known).
    fn line(n: *const Note, i: usize) []const u8 {
        return if (i == 0) n.left_buf[0..n.left_len] else lines[i - 1];
    }
    const count = lines.len + 1;
};

/// The note's size (see menuNote), at our window's DPI, room kept for how much is left at
/// its longest. `measure` as for menuRect.
pub fn noteSize(dpi: u32, measure: anytype) struct { w: i32, h: i32 } {
    const s: Scale = .{ .dpi = dpi };
    var w: i32 = measure.width(finishing_left_reserve, .normal);
    for (Note.lines) |text| w = @max(w, measure.width(text, .normal));
    return .{
        .w = w + 2 * s.px(note_pad_px),
        .h = @as(i32, Note.count) * s.px(note_line_px) + 2 * s.px(note_pad_px),
    };
}

/// Paints the note (see menuNote) into its popup.
pub fn paintNote(p: anytype, width: i32, height: i32, dpi: u32) void {
    const s: Scale = .{ .dpi = dpi };
    p.clear(color.menu);
    const note = menuNote() orelse return;
    const pad = s.px(note_pad_px);
    for (0..Note.count) |i| {
        const top = pad + @as(i32, @intCast(i)) * s.px(note_line_px);
        p.text(note.line(i), .{ .left = pad, .top = top, .right = width - pad, .bottom = @min(height, top + s.px(note_line_px)) }, .normal, color.text, .left);
    }
}

const note_pad_px = 12;
const note_line_px = 20;

/// Quit (the menu's, or the platform's: Alt+F4, the taskbar's close). While recording, it stops,
/// and the window closes once its files are finished (see closeWhenFinished, and Force Quit).
pub fn requestQuit() void {
    state.quit_requested = .quit;
}

/// What the user is asked before it's done, see takeConfirm.
pub const Confirm = union(enum) {
    /// Removing this source while recording: its track ends.
    remove: u32,
};

/// A question for the user, if something asks one: the platform asks it (yes or no, no by
/// default), then calls confirmed if the answer's yes.
pub fn takeConfirm() ?Confirm {
    defer state.confirm_requested = null;
    return state.confirm_requested;
}

/// The question's words: a title, and what happens on yes. `buf` holds the message when it
/// names a source.
pub fn confirmText(c: Confirm, buf: []u8) struct { title: []const u8, message: []const u8 } {
    return switch (c) {
        .remove => |id| .{
            .title = "Remove this track while recording?",
            .message = if (findSource(id)) |src| std.fmt.bufPrint(buf, "{s} stops being recorded now. Added back, it carries on in the same file.", .{src.name()}) catch
                "It stops being recorded now. Added back, it carries on in the same file." else "It's already gone.",
        },
    };
}

/// The user said yes: it's done (if it still can be: the source may be gone by now).
pub fn confirmed(c: Confirm) void {
    switch (c) {
        .remove => |id| if (findSource(id) != null) removeSource(id),
    }
}

/// Whether Minimize was clicked since the last call.
pub fn takeMinimize() bool {
    defer state.minimize_requested = false;
    return state.minimize_requested;
}

pub fn openMenu() ?Menu {
    return state.menu;
}

fn menuIs(tag: std.meta.Tag(Menu)) bool {
    const menu = state.menu orelse return false;
    return menu == tag;
}

/// Returns whether a menu was open.
pub fn closeMenu() bool {
    const was_open = state.menu != null;
    state.menu = null;
    state.menu_mouse = null;
    state.menu_pressed = null;
    // Everything the menu had goes: nothing lingers after it closes.
    for (state.devices.items) |d| d.deinit();
    state.devices.clearAndFree(gpa);
    state.device_levels = null;
    return was_open;
}

/// The open devices menu's devices, in its order (for the platform to meter, see
/// setDeviceLevels).
pub fn listedDevices() []const Device {
    return state.devices.items;
}

/// Live levels for the open devices menu, one per listedDevices entry, or null. The platform
/// keeps them until the menu closes (or it sets null), then frees them.
pub fn setDeviceLevels(levels: ?[]const DeviceLevel) void {
    if (levels) |l| std.debug.assert(l.len == state.devices.items.len);
    state.device_levels = levels;
}

/// Whether the open menu changes by itself (live levels), so the platform repaints it every
/// frame.
/// Whether the open menu shows something that changes by itself: device levels, or a live
/// webcam's frame counts. See menuChanged.
pub fn menuAnimating() bool {
    if (state.device_levels != null) return true;
    const id = switch (state.menu orelse return false) {
        .track => |id| id,
        .devices, .todo, .more => return false,
    };
    const src = findSource(id) orelse return false;
    return src.video_counts != null and src.status == .live;
}

/// While menuAnimating: whether a frame now would look any different. Levels move every
/// frame; the counts only when a frame is encoded or dropped (a camera's rate, not the
/// display's).
pub fn menuChanged() bool {
    if (state.device_levels != null) return true;
    const id = switch (state.menu orelse return false) {
        .track => |id| id,
        .devices, .todo, .more => return false,
    };
    const src = findSource(id) orelse return false;
    return !std.meta.eql(src.frameCounts(), state.track_menu_frames);
}

/// Where the open menu goes, in our window's client coordinates: under the button that
/// opened it. It may extend past our window.
/// `measure` is the platform's: width([]const u8, Font) i32, in pixels.
pub fn menuRect(dpi: u32, measure: anytype) Rect {
    const s: Scale = .{ .dpi = dpi };
    const menu = state.menu.?;
    // Wide enough for every row's text, so nothing is cut off.
    state.menu_w = s.px(menu_min_w_px);
    state.menu_note_w = 0;
    for (0..menuRowCount(menu)) |i| {
        const row = menuRow(menu, i);
        if (row.note) |note| state.menu_note_w = @max(state.menu_note_w, measure.width(note, .small));
    }
    for (0..menuRowCount(menu)) |i| {
        const row = menuRow(menu, i);
        var text_w = measure.width(row.text.slice(), .normal);
        if (row.reserve) |reserve| text_w = @max(text_w, measure.width(reserve, .normal));
        if (row.note != null) text_w += s.px(menu_note_gap_px) + state.menu_note_w + 2 * s.px(menu_tag_pad_px);
        state.menu_w = @max(state.menu_w, menuTextLeft(menu, s) + text_w + s.px(menu_text_right_px));
    }
    state.menu_row_h = s.px(menu_row_px);
    const w = state.menu_w;
    const h = @as(i32, @intCast(menuRowCount(menu))) * state.menu_row_h;
    const anchor = switch (menu) {
        .devices, .todo => |kind| state.add_buttons[@intFromEnum(kind)],
        .more => state.more_button,
        .track => |id| findSource(id).?.track_button,
    };
    const top = anchor.bottom + s.px(4);
    const left = switch (menu) {
        .devices, .todo, .track => anchor.left,
        // At the right edge.
        .more => anchor.right - w,
    };
    return .{ .left = left, .top = top, .right = left + w, .bottom = top + h };
}

const menu_row_px = 36;
/// Between a row's text and its note.
const menu_note_gap_px = 16;
/// A note's tag: padding either side of its text, and its height.
const menu_tag_pad_px = 7;
const menu_tag_h_px = 20;
/// A devices menu row's level bar: its height, and its gap above the row's bottom.
const menu_level_h_px = 3;
const menu_level_bottom_px = 5;

/// A line in a menu.
const MenuRow = struct {
    /// Null if it can't be chosen: a heading or a note.
    item: ?MenuItem,
    text: MenuText,
    icon: ?Icon = null,
    /// A word at the right, drawn as a tag, e.g. "Default".
    note: ?[]const u8 = null,
    /// A checkmark in the menu's check column, at the left.
    checked: bool = false,
    divider_below: bool = false,
    /// For text that changes while the menu is open (live counts): the menu is made at
    /// least this wide for it, so it has room to grow without the menu changing size.
    reserve: ?[]const u8 = null,
};

/// Menu text, formatted without allocating: each formatted kind has room for its longest.
const MenuText = union(enum) {
    static: []const u8,
    format: AudioFormat.Text.Formatted,
    captured_as: AudioFormat.CapturedAsText.Formatted,
    video_captured_as: VideoFormat.CapturedAsText.Formatted,
    encoder: EncoderText.Formatted,
    camera_format: CameraFormatText.Formatted,
    gpu: GpuText.Formatted,
    bitrate: BitrateText.Formatted,
    frames: FramesText.Formatted,
    clips: ClipsText.Formatted,
    buffer: BufferText.Formatted,

    fn slice(t: *const MenuText) []const u8 {
        return switch (t.*) {
            .static => |text| text,
            inline else => |*formatted| formatted.slice(),
        };
    }
};

const BufferText = maxstring.MaxString(.utf8, .no_sentinel, &.{
    .{ .static = "Recording buffer: " },
    .{ .runtime_value = .{ .name = "kb", .type = u32 } },
    .{ .static = " KB (" },
    .{ .runtime_value = .{ .name = "ms", .type = u32 } },
    .{ .static = " ms)" },
});

const EncoderText = maxstring.MaxString(.utf8, .no_sentinel, &.{
    .{ .static = "Encoded by " },
    .{ .runtime_utf8 = .{ .name = "name", .max_len = 64 } },
});

const CameraFormatText = maxstring.MaxString(.utf8, .no_sentinel, &.{
    .{ .static = "Camera sends " },
    .{ .runtime_utf8 = .{ .name = "format", .max_len = 36 } },
    .{ .runtime_utf8 = .{ .name = "converted", .max_len = converted_text.len } },
});
const converted_text = ", converted for the encoder";

const GpuText = maxstring.MaxString(.utf8, .no_sentinel, &.{
    .{ .static = "On " },
    .{ .runtime_utf8 = .{ .name = "name", .max_len = 64 } },
});

/// The rate in Mbit/s, to a tenth.
const BitrateText = maxstring.MaxString(.utf8, .no_sentinel, &.{
    .{ .static = "Target bitrate " },
    .{ .runtime_value = .{ .name = "mbit", .type = u32 } },
    .{ .static = "." },
    .{ .runtime_value = .{ .name = "tenth", .type = u32 } },
    .{ .static = " Mbit/s" },
});

/// The room the live frame counts have to grow into (see MenuRow.reserve): over 38 days of
/// frames at 30 fps, a million dropped.
const frames_reserve = "Frames: 99999999 encoded, 999999 dropped";

const FramesText = maxstring.MaxString(.utf8, .no_sentinel, &.{
    .{ .static = "Frames: " },
    .{ .runtime_value = .{ .name = "encoded", .type = u64 } },
    .{ .static = " encoded, " },
    .{ .runtime_value = .{ .name = "dropped", .type = u64 } },
    .{ .static = " dropped" },
});

const ClipsText = maxstring.MaxString(.utf8, .no_sentinel, &.{
    .{ .static = "Clipped " },
    .{ .runtime_value = .{ .name = "count", .type = u32 } },
    .{ .static = "\u{00D7} \u{00B7} Clear" },
});

fn formatText(format: ?AudioFormat) MenuText {
    const f = format orelse return .{ .static = "Format unknown" };
    return .{ .format = f.text() };
}

fn menuRowCount(menu: Menu) usize {
    return switch (menu) {
        .todo => 1,
        .more => std.enums.values(MoreItem).len,
        .track => |id| blk: {
            var buf: [std.enums.values(TrackRow).len]TrackRow = undefined;
            break :blk trackRows(findSource(id).?, &buf).len;
        },
        // A note when there are none.
        .devices => @max(1, state.devices.items.len),
    };
}

fn menuRow(menu: Menu, i: usize) MenuRow {
    switch (menu) {
        .todo => |kind| return .{ .item = null, .text = .{ .static = kind.todo().? }, .icon = kind.icon() },
        .more => {
            const item = std.enums.values(MoreItem)[i];
            return .{
                .item = .{ .more = item },
                // Already quitting, waiting for the files: quitting now (see menuNote).
                .text = .{ .static = if (item == .quit and state.mode == .closing) "Force Quit" else item.title() },
                .checked = item == .exclude_from_capture and state.settings.exclude_from_capture,
                .divider_below = item == .exclude_from_capture,
            };
        },
        .track => |id| {
            const src = findSource(id).?;
            var buf: [std.enums.values(TrackRow).len]TrackRow = undefined;
            const rows = trackRows(src, &buf);
            // A divider between what the track is and what can be done with it.
            const last_info = i + 1 < rows.len and switch (rows[i + 1]) {
                .clips, .remove => true,
                .name, .device_format, .captured_as, .camera_format, .effects, .encoder, .gpu, .bitrate, .frames, .buffer => false,
            };
            return switch (rows[i]) {
                .name => .{ .item = null, .text = .{ .static = src.name() }, .icon = src.icon(), .divider_below = last_info },
                .device_format => .{ .item = null, .text = formatText(src.device.?.format), .divider_below = last_info },
                .captured_as => .{ .item = null, .text = switch (src.status) {
                    .live => |live| switch (live) {
                        .audio => |a| .{ .captured_as = a.format.capturedAsText() },
                        .video => |v| .{ .video_captured_as = v.format.capturedAsText() },
                    },
                    .starting => .{ .static = "Captured as: starting..." },
                    .failed => .{ .static = "Captured as: not capturing" },
                }, .divider_below = last_info },
                .effects => .{ .item = null, .text = .{ .static = switch (src.status) {
                    .live => |live| if (live.audio.raw)
                        "Raw: Windows audio effects bypassed"
                    else
                        "Windows audio effects may apply (no raw support)",
                    .starting, .failed => "Windows audio effects: unknown until capturing",
                } }, .divider_below = last_info },
                .encoder => switch (src.status) {
                    .live => |*live| .{
                        .item = null,
                        .text = .{ .encoder = EncoderText.format(.{ .name = live.video.encoder() }) },
                        .note = live.video.path.note(),
                        .divider_below = last_info,
                    },
                    .starting, .failed => .{ .item = null, .text = .{ .static = "Encoder: unknown until capturing" }, .divider_below = last_info },
                },
                .camera_format => .{ .item = null, .text = switch (src.status) {
                    .live => |*live| .{ .camera_format = CameraFormatText.format(.{
                        .format = live.video.cameraFormat(),
                        .converted = if (live.video.camera_converted) converted_text else "",
                    }) },
                    .starting, .failed => .{ .static = "Camera's format: unknown until capturing" },
                }, .divider_below = last_info },
                .gpu => .{ .item = null, .text = switch (src.status) {
                    .live => |*live| if (live.video.path == .software)
                        .{ .static = "On the CPU" }
                    else
                        .{ .gpu = GpuText.format(.{ .name = live.video.gpu() }) },
                    .starting, .failed => .{ .static = "GPU: unknown until capturing" },
                }, .divider_below = last_info },
                .bitrate => .{ .item = null, .text = switch (src.status) {
                    .live => |live| .{ .bitrate = BitrateText.format(.{
                        .mbit = live.video.bitrate / 1_000_000,
                        .tenth = live.video.bitrate / 100_000 % 10,
                    }) },
                    .starting, .failed => .{ .static = "Target bitrate: unknown until capturing" },
                }, .divider_below = last_info },
                // Live: the counts as this paint took them (see paintMenu).
                .frames => .{ .item = null, .text = .{ .frames = FramesText.format(.{
                    .encoded = state.track_menu_frames.encoded,
                    .dropped = state.track_menu_frames.dropped,
                }) }, .divider_below = last_info, .reserve = frames_reserve },
                .buffer => .{ .item = null, .text = if (src.buffer) |b|
                    .{ .buffer = BufferText.format(.{ .kb = @intCast(b.bytes / 1024), .ms = b.ms }) }
                else
                    .{ .static = "Recording buffer: not recording" }, .divider_below = last_info },
                // The count as when the menu opened, see track_menu_clips.
                .clips => if (state.track_menu_clips == 0)
                    .{ .item = null, .text = .{ .static = "No clips" } }
                else
                    .{ .item = .{ .track = .clear_clips }, .text = .{ .clips = ClipsText.format(.{ .count = state.track_menu_clips }) } },
                .remove => .{ .item = .{ .track = .remove }, .text = .{ .static = "Remove" } },
            };
        },
        .devices => |kind| {
            if (state.devices.items.len == 0) return .{ .item = null, .text = .{ .static = kind.noDevices() } };
            const device = state.devices.items[i];
            // One track per device: those already added are checked and can't be chosen.
            const added = for (state.sources.items) |src| {
                if (src.kind == kind and src.device != null and std.mem.eql(u8, src.device.?.id, device.id)) break true;
            } else false;
            return .{
                .item = if (added) null else .{ .device = i },
                .text = .{ .static = device.name },
                .icon = device.icon(kind),
                .note = if (device.default) "Default" else null,
                .checked = added,
            };
        },
    }
}

pub fn onMenuMouseMove(x: i32, y: i32) bool {
    const was = menuHot();
    state.menu_mouse = .{ .x = x, .y = y };
    return !std.meta.eql(was, menuHot());
}

pub fn onMenuMouseLeave() bool {
    const was = menuHot();
    state.menu_mouse = null;
    return was != null;
}

pub fn onMenuMouseDown(x: i32, y: i32) void {
    state.menu_mouse = .{ .x = x, .y = y };
    state.menu_pressed = menuHot();
}

/// Chooses the item if the press started on it too. Returns true if one was chosen.
pub fn onMenuMouseUp(x: i32, y: i32) bool {
    state.menu_mouse = .{ .x = x, .y = y };
    const pressed = state.menu_pressed;
    state.menu_pressed = null;
    const item = menuHot() orelse return false;
    if (!std.meta.eql(pressed, @as(?MenuItem, item))) return false;
    const menu = state.menu.?;
    switch (item) {
        .more => |more| switch (more) {
            .exclude_from_capture => state.settings.exclude_from_capture = !state.settings.exclude_from_capture,
            .quit => if (state.mode == .closing) {
                state.quit_requested = .force_quit;
            } else requestQuit(),
        },
        .track => |track| switch (track) {
            // Those that happened while the menu was open stay.
            .clear_clips => findSource(menu.track).?.clips_cleared += state.track_menu_clips,
            // While recording, its track ends: asked first.
            .remove => if (state.mode == .recording) {
                state.confirm_requested = .{ .remove = menu.track };
            } else removeSource(menu.track),
        },
        // Taken from the list, closeMenu frees the rest.
        .device => |i| addSource(menu.devices, state.devices.swapRemove(i)),
    }
    _ = closeMenu();
    return true;
}

const MenuItem = union(enum) {
    more: MoreItem,
    track: TrackItem,
    /// Index into state.devices.
    device: usize,
};

fn menuHot() ?MenuItem {
    const m = state.menu_mouse orelse return null;
    const menu = state.menu orelse return null;
    if (m.x < 0 or m.x >= state.menu_w or m.y < 0) return null;
    const i: usize = @intCast(@divTrunc(m.y, state.menu_row_h));
    if (i >= menuRowCount(menu)) return null;
    return menuRow(menu, i).item;
}

fn hot() Hot {
    const m = state.mouse orelse return .none;
    return hitTest(m.x, m.y);
}

fn hitTest(x: i32, y: i32) Hot {
    if (state.button.contains(x, y)) return .button;
    for (state.add_buttons, 0..) |r, i| if (r.contains(x, y)) return .{ .add = @enumFromInt(i) };
    if (state.pin_button.contains(x, y)) return .pin_button;
    if (state.collapse_button.contains(x, y)) return .collapse_button;
    if (state.more_button.contains(x, y)) return .more_button;
    if (state.minimize_button.contains(x, y)) return .minimize_button;
    if (state.settings.collapsed) return .none;
    for (state.sources.items) |s| {
        if (s.track_button.contains(x, y)) return .{ .track = s.id };
    }
    return .none;
}

/// The record button: start or stop recording. Returns false when it's disabled.
fn primaryAction() bool {
    if (!recordEnabled()) return false;
    state.mode = switch (state.mode) {
        .idle => .recording,
        .recording => .idle,
        .closing => unreachable, // recordEnabled
    };
    if (state.mode == .recording) {
        state.recording_error = null;
        for (state.sources.items) |*src| src.record_error = null;
    }
    return true;
}

/// Whether the user wants to be recording. The platform starts and stops the recording to
/// match, see recordingFailed.
pub fn isRecording() bool {
    return state.mode == .recording;
}

/// Quit was asked for while recording, or while a recording's files are still being finished:
/// recording stops, nothing new can start, and the top bar says the window closes once the
/// files are done (the platform closes it then, if it's still closing: see recordingProblem).
pub fn closeWhenFinished() void {
    // Again (the window closed again, while closing): how much is left stays.
    if (state.mode != .closing) state.mode = .{ .closing = null };
}

pub fn isClosing() bool {
    return state.mode == .closing;
}

/// The recording as a whole couldn't start or continue: it stops, and the message shows in
/// the top bar until the next one. While closing, it stops closing too (see recordingProblem).
pub fn recordingFailed(message: Message) void {
    state.mode = .idle;
    state.recording_error = message;
}

/// A problem with a recording that stopped nothing (its progress couldn't be saved, or one
/// being finished failed): shown in the top bar like a failure, until the next recording.
/// While closing, it stops closing: the window stays, so the problem is seen, not closed
/// over; quitting again closes it.
pub fn recordingProblem(message: Message) void {
    if (state.mode == .closing) state.mode = .idle;
    state.recording_error = message;
}

/// How long the recording has been going, set by the platform before painting; null when not
/// recording.
pub fn setRecordingElapsed(ms: ?u64) void {
    state.recording_elapsed_ms = ms;
}

/// Recording this source failed (the recording goes on for the others). Cleared when the
/// next recording starts. Ignored if the source is gone.
/// Debug: a source's recording buffer, null when it isn't recording. Ignored if the source is
/// gone.
pub fn setSourceBuffer(id: u32, buffer: ?Buffer) void {
    if (findSource(id)) |s| s.buffer = buffer;
}

pub const Buffer = struct {
    bytes: u64,
    /// How much audio that holds.
    ms: u32,
};

pub fn setSourceRecordError(id: u32, message: Message) void {
    if (findSource(id)) |s| s.record_error = message;
}

// ---------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------

/// `p` is the platform's painter. It provides:
///   clear(Color), fill(Rect, Color), ellipse(Rect, Color), pill(Rect, Color) (a rect with
///   fully rounded ends), text([]const u8, Rect, Font, Color, Align),
///   icon(Icon, Rect, Font, Color) (centered in the rect), textWidth([]const u8, Font) i32,
///   band(left: i32, upper: []const i32, lower: []const i32, Gradient): columns a pixel wide
///   from `left`, column i filled from upper[i] down to lower[i] (at most band_columns)
pub fn paint(p: anytype, width: i32, height: i32, dpi: u32) void {
    const s: Scale = .{ .dpi = dpi };
    p.clear(color.window);

    const margin = s.px(margin_px);
    const gap = s.px(8);
    const left = margin;
    const right = width - margin;
    var top = margin;

    // The bar on top is for status and what you do while recording, and stays when the
    // window is collapsed: collapse, the record button and storage on the left, the window
    // controls on the right. Those follow Windows' minimize/maximize/close: minimize, pin
    // where maximize would be, and "â‹¯" (which has Quit) where close would be.
    const bar_h = s.px(bar_px);
    {
        state.collapse_button = .{ .left = left, .top = top, .right = left + bar_h, .bottom = top + bar_h };
        paintToggle(p, state.collapse_button, if (state.settings.collapsed) .expand else .collapse, false, look(.collapse_button));
        const record_left = state.collapse_button.right + gap;
        state.button = .{ .left = record_left, .top = top, .right = record_left + bar_h, .bottom = top + bar_h };
        paintRecordButton(p, s);

        state.more_button = .{ .left = right - bar_h, .top = top, .right = right, .bottom = top + bar_h };
        paintToggle(p, state.more_button, .more, menuIs(.more), look(.more_button));
        state.pin_button = .{ .left = state.more_button.left - bar_h, .top = top, .right = state.more_button.left, .bottom = top + bar_h };
        paintToggle(p, state.pin_button, if (state.settings.always_on_top) .pinned else .pin, state.settings.always_on_top, look(.pin_button));
        state.minimize_button = .{ .left = state.pin_button.left - bar_h, .top = top, .right = state.pin_button.left, .bottom = top + bar_h };
        paintToggle(p, state.minimize_button, .minimize, false, look(.minimize_button));

        const status_r = line(state.button.right + s.px(12), state.minimize_button.left - s.px(8), top, bar_h);
        switch (state.mode) {
            .closing => |finishing| if (finishing) |known| {
                var buf: [closing_text_prefix.len + finishing_left_max]u8 = undefined;
                p.text(std.fmt.bufPrint(&buf, closing_text_prefix ++ "{f}", .{fmtFinishingLeft(known)}) catch unreachable, status_r, .small, color.text, .left);
            } else p.text(closing_text, status_r, .small, color.text, .left),
            .idle, .recording => if (state.recording_error) |*m| {
                p.text(m.slice(), status_r, .small, color.amber, .left);
            } else {
                paintStatus(p, s, status_r);
            },
        }
    }
    top += bar_h + gap;

    var warning_buf: [256]u8 = undefined;
    if (captureWarning(&warning_buf)) |warning| {
        p.text(warning, line(left, right, top, s.px(warning_px)), .normal, color.amber, .left);
        top += s.px(warning_px) + gap;
    }

    if (state.settings.collapsed) {
        // Nothing below is painted, so nothing below can be clicked.
        for (state.sources.items) |*src| src.track_button = empty_rect;
        state.add_buttons = @splat(empty_rect);
        state.add_group = empty_rect;
    } else {
        paintViewer(p, s, .{ .left = left, .top = top, .right = right, .bottom = height - margin });
    }
}

const margin_px = 16;
const bar_px = 36;
const warning_px = 24;

/// The client height the platform should give a collapsed window: just the controls, and the
/// capture warning if there is one, since it must stay visible.
pub fn collapsedHeight(dpi: u32) i32 {
    const s: Scale = .{ .dpi = dpi };
    var buf: [256]u8 = undefined;
    const warning: i32 = if (captureWarning(&buf) != null) s.px(warning_px) + s.px(8) else 0;
    return 2 * s.px(margin_px) + s.px(bar_px) + warning;
}

fn captureWarning(buf: []u8) ?[]const u8 {
    if (!state.settings.exclude_from_capture) return null;
    return switch (state.capture_exclusion) {
        .ok => null,
        .unsupported => "Warning: this version of Windows can't hide this window from screen capture, it may appear in recordings.",
        .failed => |code| std.fmt.bufPrint(buf, "Warning: hiding this window from screen capture failed (error {d}), it may appear in recordings.", .{code}) catch buf,
    };
}

const closing_text = closing_text_prefix ++ "Black Box closes when it's done";
/// Once how much is left is known (see setFinishingLeft), followed by that.
const closing_text_prefix = "Finishing the recording\u{2026} ";

/// The recording time the disk has room for (an estimate, see averageRate), then faintly,
/// what it's from: free space and the rate.
fn paintStatus(p: anytype, s: Scale, r: Rect) void {
    const d = state.disk;
    // Before the platform's first setDisk: a volume is never 0 bytes.
    if (d.total == 0) return p.text("Checking free space\u{2026}", r, .small, color.dim, .left);
    // Nothing to record yet: no time to tell, just the space.
    const rate = averageRate() orelse {
        var buf: [64]u8 = undefined;
        return p.text(std.fmt.bufPrint(&buf, "{f} free", .{fmtBytes(d.free)}) catch unreachable, r, .small, color.text, .left);
    };
    var time_buf: [64]u8 = undefined;
    const left_s: u64 = @intFromFloat(@as(f64, @floatFromInt(d.free)) / rate);
    const time = std.fmt.bufPrint(&time_buf, "{f} left", .{fmtDuration(left_s)}) catch unreachable;
    p.text(time, r, .small, color.text, .left);
    var details_buf: [64]u8 = undefined;
    const details = std.fmt.bufPrint(&details_buf, "{f} \u{00B7} {f}/s", .{ fmtBytes(d.free), fmtBytes(@intFromFloat(rate)) }) catch unreachable;
    const x = r.left + p.textWidth(time, .small) + s.px(12);
    p.text(details, .{ .left = x, .top = r.top, .right = r.right, .bottom = r.bottom }, .small, color.faint, .left);
}

/// Bytes a second the tracks typically take, or null with nothing to record yet. Each is FLAC
/// of its device's own bit depth, what its samples really hold (a 16-bit device's, captured
/// as float and stored as 24-bit, keep 8 zero bits the encoder drops), compressed to
/// typical_flac_ratio of that.
fn averageRate() ?f64 {
    var bps: f64 = 0;
    for (state.sources.items) |src| switch (src.status) {
        .live => |live| switch (live) {
            .audio => |a| {
                const device_bits = if (src.device) |d| if (d.format) |f| f.bits else null else null;
                const bits: f64 = @floatFromInt(@min(device_bits orelse a.format.bits, 24));
                bps += @as(f64, @floatFromInt(a.format.rate)) * @as(f64, @floatFromInt(a.format.channels)) * bits / 8 * typical_flac_ratio;
            },
            .video => |v| bps += @as(f64, @floatFromInt(v.bitrate)) / 8 * typical_video_ratio,
        },
        .starting, .failed => {},
    };
    return if (bps > 0) bps else null;
}

/// What a webcam's video typically takes of its encoder's target rate: a webcam's picture is
/// mostly still. A first test (a laptop's 1080p camera, a person at a desk) took 30-45%.
const typical_video_ratio = 0.4;

/// What FLAC typically shrinks audio to. A first recording's tracks (three mics, an output)
/// took 37% (quiet mics) to 92% (music) of their 16-bit size, 62% on average.
const typical_flac_ratio = 0.6;

/// A number with its thousands grouped: "1,240".
fn fmtGrouped(n: u64) std.fmt.Alt(u64, formatGrouped) {
    return .{ .data = n };
}

fn formatGrouped(n: u64, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (n < 1000) return w.print("{d}", .{n});
    try formatGrouped(n / 1000, w);
    try w.print(",{d:0>3}", .{n % 1000});
}

/// A long time, roughly: "1,240 hours", "340 hours", "3 hours 20 minutes", "45 minutes", "30 seconds".
fn fmtDuration(seconds: u64) std.fmt.Alt(u64, formatDuration) {
    return .{ .data = seconds };
}

fn formatDuration(seconds: u64, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const hours = seconds / 3600;
    const minutes = seconds / 60 % 60;
    if (hours >= 10) return w.print("{f} hours", .{fmtGrouped(hours)});
    if (hours >= 1) {
        try w.print("{d} {s}", .{ hours, if (hours == 1) "hour" else "hours" });
        if (minutes > 0) try w.print(" {d} {s}", .{ minutes, if (minutes == 1) "minute" else "minutes" });
        return;
    }
    if (minutes >= 1) return w.print("{d} {s}", .{ minutes, if (minutes == 1) "minute" else "minutes" });
    try w.print("{d} {s}", .{ seconds, if (seconds == 1) "second" else "seconds" });
}

/// Whether the record button does anything: there must be something to record, but a
/// recording can always be stopped.
fn recordEnabled() bool {
    return switch (state.mode) {
        .idle => state.sources.items.len > 0,
        .recording => true,
        .closing => false,
    };
}

/// How a button looks: the mouse over it, or pressed (the press started on it and the mouse
/// is still over it).
const Look = enum { normal, hot, pressed };

fn look(target: Hot) Look {
    if (!std.meta.eql(hot(), target)) return .normal;
    if (state.pressed) |pressed| if (std.meta.eql(pressed, target)) return .pressed;
    return .hot;
}

/// The record button in state.button: round, with a dot that turns red while recording.
fn paintRecordButton(p: anytype, s: Scale) void {
    const enabled = recordEnabled();
    const r = state.button;
    p.ellipse(r, if (!enabled) color.button else switch (look(.button)) {
        .normal => color.button,
        .hot => color.button_hot,
        .pressed => color.button_pressed,
    });
    const dot = s.px(14);
    const dot_x = r.left + @divTrunc(r.right - r.left - dot, 2);
    const dot_y = r.top + @divTrunc(r.bottom - r.top - dot, 2);
    p.ellipse(.{ .left = dot_x, .top = dot_y, .right = dot_x + dot, .bottom = dot_y + dot }, if (!enabled)
        color.disabled
    else if (state.mode == .recording)
        color.record
    else
        color.text);
}

/// The add buttons, one per kind of source, as one group: plain icons, their place above the
/// tracks saying what they're for. The one the mouse is over (or whose menu is open) says what
/// it adds beside the group, up to `right`.
fn paintAddGroup(p: anytype, s: Scale, left: i32, top: i32, right: i32) void {
    const size = s.px(bar_px);
    const divider = @max(1, s.px(1));
    state.add_group = .{ .left = left, .top = top, .right = left + @as(i32, add_order.len) * size, .bottom = top + size };
    p.fill(state.add_group, color.button);

    // The kind the mouse is over or pressing, else the one whose menu is open.
    const active: ?SourceKind = switch (hot()) {
        .add => |kind| kind,
        else => if (state.menu) |m| switch (m) {
            .devices, .todo => |kind| kind,
            .more, .track => null,
        } else null,
    };

    var x = left;
    for (add_order, 0..) |kind, i| {
        const r: Rect = .{ .left = x, .top = top, .right = x + size, .bottom = top + size };
        state.add_buttons[@intFromEnum(kind)] = r;
        switch (look(.{ .add = kind })) {
            .pressed => p.fill(r, color.button_pressed),
            .hot => p.fill(r, color.button_hot),
            .normal => if (active == kind) p.fill(r, color.button_hot),
        }
        if (i > 0) p.fill(.{ .left = r.left, .top = r.top, .right = r.left + divider, .bottom = r.bottom }, color.window);
        p.icon(kind.icon(), r, .icon_small, color.text);
        x = r.right;
    }
    if (active) |kind| p.text(kind.addHint(), line(state.add_group.right + s.px(12), right, top, size), .small, color.dim, .left);
}

/// A square icon button; `on` highlights it.
fn paintToggle(p: anytype, r: Rect, icon: Icon, on: bool, button_look: Look) void {
    switch (button_look) {
        .pressed => p.fill(r, color.tile_pressed),
        .hot => p.fill(r, color.tile_hot),
        .normal => if (on) p.fill(r, color.tile),
    }
    p.icon(icon, r, .icon_small, if (on or button_look != .normal) color.text else color.dim);
}

/// What's being recorded: the add buttons, always in the same place at the top so adding
/// several sources is clicks in one spot; then a timeline, a track per source (video tracks
/// first, like an editor) with the playhead crossing them all, then video previews filling
/// the space below.
fn paintViewer(p: anytype, s: Scale, viewer: Rect) void {
    const gap = s.px(8);
    paintAddGroup(p, s, viewer.left, viewer.top, viewer.right);
    if (state.sources.items.len == 0) return;
    var area = viewer;
    area.top = state.add_group.bottom + gap;

    var audio_count: i32 = 0;
    var video_count: i32 = 0;
    for (state.sources.items) |src| {
        if (src.kind.isVideo()) video_count += 1 else audio_count += 1;
    }

    // Audio on a timeline, each track a lane of its levels; video as tiles below, each its
    // picture and state. (A lane is for seeing sound over time; what's useful of a webcam
    // while recording is that it's working, and how it's framed.)
    // The timeline (the recording's time, the playhead) whatever's being recorded.
    const tiles_top = paintTimeline(p, s, area, audio_count) + gap;
    if (video_count > 0) paintVideoTiles(p, s, .{ .left = area.left, .top = tiles_top, .right = area.right, .bottom = area.bottom }, video_count);
}

/// The timeline and the audio tracks under it (if any), from `area`'s top: returns where
/// they end.
fn paintTimeline(p: anytype, s: Scale, area: Rect, audio_count: i32) i32 {
    const gap = s.px(8);
    // Columns shared by the timeline and the tracks, so they line up.
    const icon_w = s.px(36);
    const wave_left = area.left + icon_w;
    const wave_right = area.right - s.px(4);

    const timeline_top = area.top;
    const timeline_h = s.px(20);
    const timeline_bottom = timeline_top + timeline_h;
    const tracks_top = timeline_bottom + gap;
    const tracks_bottom = if (audio_count == 0) timeline_bottom else tracks_top + audio_count * (s.px(audio_track_px) + gap) - gap;

    // Timeline, above the tracks.
    {
        const mid = timeline_top + @divTrunc(timeline_h, 2);
        p.fill(.{ .left = wave_left, .top = mid, .right = wave_right, .bottom = mid + @max(1, s.px(1)) }, color.divider);
        // TODO: real times once there's a recording to scrub; longer ones won't fit in the
        // icon column.
        var time_buf: [16]u8 = undefined;
        const elapsed_s = (state.recording_elapsed_ms orelse 0) / 1000;
        const time = if (elapsed_s < 3600)
            std.fmt.bufPrint(&time_buf, "{d}:{d:0>2}", .{ elapsed_s / 60, elapsed_s % 60 }) catch unreachable
        else
            std.fmt.bufPrint(&time_buf, "{d}:{d:0>2}:{d:0>2}", .{ elapsed_s / 3600, elapsed_s / 60 % 60, elapsed_s % 60 }) catch unreachable;
        p.text(time, .{ .left = area.left, .top = timeline_top, .right = wave_left, .bottom = timeline_bottom }, .small, if (state.mode == .recording) color.text else color.dim, .center);
    }

    // Tracks. Just an icon, no name; the icon opens the track's menu.
    var y = tracks_top;
    for (state.sources.items) |*src| {
        if (src.kind.isVideo()) continue;
        const track_h = s.px(audio_track_px);
        const r: Rect = .{ .left = area.left, .top = y, .right = area.right, .bottom = y + track_h };
        p.fill(r, color.tile);
        const icon_r: Rect = .{ .left = r.left, .top = r.top, .right = r.left + icon_w, .bottom = r.bottom };
        paintTrackButton(p, src, icon_r);
        paintClipBadge(p, s, icon_r, src.clips());
        const lane: Rect = .{ .left = wave_left, .top = r.top + s.px(4), .right = wave_right, .bottom = r.bottom - s.px(4) };
        switch (src.status) {
            .live => {
                src.painted_width = @intCast(@max(lane.right - lane.left, 0));
                src.painted_columns = paintLevels(p, s, lane, src.meter.?);
            },
            .starting => p.text("Starting...", lane.inset(s.px(8), 0), .small, color.dim, .left),
            .failed => |*m| p.text(m.slice(), lane.inset(s.px(8), 0), .small, color.amber, .left),
        }
        // What it is, over its lane: the icon says what kind of device, this which one.
        paintTrackLabel(p, s, lane, src.name());
        paintRecordError(p, s, lane, src);
        y += track_h + gap;
    }

    // Playhead, across the timeline and every track. At "now" (live) until scrubbing exists.
    {
        const w = @max(2, s.px(2));
        const x = wave_right - w;
        p.fill(.{ .left = x, .top = timeline_top, .right = x + w, .bottom = tracks_bottom }, color.text);
    }
    return tracks_bottom;
}

/// The video sources side by side in `area`, each as large as fits at 16:9 (and no smaller
/// than video_tile_min_px tall: its menu stays in reach in a small window). Each has its
/// track button at its top left, its name beside it, and what it's doing in its middle.
/// TODO: the picture, and marks where frames were dropped.
fn paintVideoTiles(p: anytype, s: Scale, area: Rect, video_count: i32) void {
    const gap = s.px(8);
    var tile_w = @divTrunc(area.right - area.left - (video_count - 1) * gap, video_count);
    var tile_h = @divTrunc(tile_w * 9, 16);
    const region_h = area.bottom - area.top;
    if (tile_h > region_h) {
        tile_h = region_h;
        tile_w = @divTrunc(tile_h * 16, 9);
    }
    if (tile_h < s.px(video_tile_min_px)) {
        tile_h = s.px(video_tile_min_px);
        tile_w = @divTrunc(tile_h * 16, 9);
    }
    const row_w = video_count * tile_w + (video_count - 1) * gap;
    var x = area.left + @max(0, @divTrunc(area.right - area.left - row_w, 2));
    const button_w = s.px(36);
    for (state.sources.items) |*src| {
        if (!src.kind.isVideo()) continue;
        const r: Rect = .{ .left = x, .top = area.top, .right = x + tile_w, .bottom = area.top + tile_h };
        x += tile_w + gap;
        p.fill(r, color.video);
        const button: Rect = .{ .left = r.left, .top = r.top, .right = r.left + button_w, .bottom = r.top + button_w };
        paintTrackButton(p, src, button);
        paintClipBadge(p, s, button, src.clips());
        paintTrackLabel(p, s, .{ .left = button.right, .top = r.top + s.px(8), .right = r.right, .bottom = r.bottom }, src.name());
        // What it's doing, in the middle: its format once live, until there's a picture.
        const body: Rect = .{ .left = r.left + s.px(8), .top = button.bottom, .right = r.right - s.px(8), .bottom = r.bottom - s.px(8) };
        switch (src.status) {
            .live => |live| {
                var buf: [64]u8 = undefined;
                const f = live.video.format;
                const fps = if (f.fps_den == 0) 0 else (f.fps_num + f.fps_den / 2) / f.fps_den;
                const text = std.fmt.bufPrint(&buf, "{d}x{d} at {d} fps", .{ f.width, f.height, fps }) catch unreachable;
                p.text(text, body, .small, color.dim, .center);
            },
            .starting => p.text("Starting...", body, .small, color.dim, .center),
            .failed => |*m| p.text(m.slice(), body, .small, color.amber, .center),
        }
        paintRecordError(p, s, .{ .left = r.left, .top = r.bottom - s.px(32), .right = r.right, .bottom = r.bottom }, src);
    }
}

/// A track's button (its icon, which opens its menu), lit when hot, pressed or open.
fn paintTrackButton(p: anytype, src: *Source, r: Rect) void {
    src.track_button = r;
    const menu_open = menuIs(.track) and state.menu.?.track == src.id;
    switch (look(.{ .track = src.id })) {
        .pressed => p.fill(r, color.tile_pressed),
        .hot => p.fill(r, color.tile_hot),
        .normal => if (menu_open) p.fill(r, color.tile_hot),
    }
    p.icon(src.icon(), r, .icon_small, color.text);
}

/// Why recording the source failed, if it did, over `r`.
fn paintRecordError(p: anytype, s: Scale, r: Rect, src: *const Source) void {
    const m = src.record_error orelse return;
    const r_err = r.inset(s.px(4), s.px(4));
    p.fill(r_err, color.window);
    p.text(m.slice(), r_err.inset(s.px(4), 0), .small, color.amber, .left);
}

/// Taller than a tile's track button and name: room for what it's doing too.
const video_tile_min_px = 90;
/// Room for the level meter's zones.
const audio_track_px = 56;

/// A track's name at its lane's top left: small, see-through so the levels show beneath it,
/// with a soft shadow so it still reads over loud ones.
fn paintTrackLabel(p: anytype, s: Scale, lane: Rect, name: []const u8) void {
    const r: Rect = .{ .left = lane.left + s.px(6), .top = lane.top + s.px(1), .right = lane.right - s.px(6), .bottom = lane.top + s.px(19) };
    const shadow = @max(1, s.px(1));
    p.text(name, .{ .left = r.left + shadow, .top = r.top + shadow, .right = r.right + shadow, .bottom = r.bottom + shadow }, .small, color.label_shadow, .left);
    p.text(name, r, .small, color.label, .left);
}

/// A red badge in the corner of a track's icon while it has uncleared clips, with how many:
/// up to 99, then "99+". A circle, stretched into a pill for more digits.
fn paintClipBadge(p: anytype, s: Scale, icon_r: Rect, clips: u32) void {
    if (clips == 0) return;
    var buf: [2]u8 = undefined;
    const text = if (clips > 99) "99+" else std.fmt.bufPrint(&buf, "{d}", .{clips}) catch unreachable;
    const h = s.px(16);
    const w = s.px(switch (text.len) {
        1 => 16,
        2 => 20,
        else => 26,
    });
    const inset = s.px(2);
    const r: Rect = .{ .left = icon_r.right - w - inset, .top = icon_r.top + inset, .right = icon_r.right - inset, .bottom = icon_r.top + inset + h };
    p.pill(r, color.record);
    p.text(text, r, .badge, color.text, .center);
}

/// How much audio the track lanes show, ending now at the right edge.
const levels_seconds = 10;

/// A level meter's zones, by where each starts in dB below full scale, quietest first. They
/// tell the user whether to change their gain: speech should peak in `loud`.
const level_zones = [_]struct { from_db: f32, color: Color }{
    // Mostly noise: the gain is too low. From the bottom of the scale, see meterFraction.
    .{ .from_db = -70, .color = .{ .r = 120, .g = 120, .b = 132 } },
    .{ .from_db = -40, .color = .{ .r = 90, .g = 200, .b = 120 } },
    .{ .from_db = -18, .color = .{ .r = 225, .g = 205, .b = 70 } },
    // Close to clipping. Clipping itself is red, see paintLevels.
    .{ .from_db = -6, .color = .{ .r = 240, .g = 135, .b = 40 } },
};

/// Where a level in dB sits on a meter, 0 (bottom) to 1 (full scale): the IEC 60268-18 curve
/// level meters use, giving the loud end, where gain is decided, more room than the noise
/// floor. -20 dB is halfway, -6 dB is 85%.
fn meterFraction(db: f32) f32 {
    if (db < -70) return 0;
    if (db < -60) return (db + 70) * 0.0025;
    if (db < -50) return (db + 60) * 0.005 + 0.025;
    if (db < -40) return (db + 50) * 0.0075 + 0.075;
    if (db < -30) return (db + 40) * 0.015 + 0.15;
    if (db < -20) return (db + 30) * 0.02 + 0.3;
    if (db < 0) return (db + 20) * 0.025 + 0.5;
    return 1;
}

/// A peak level (1 = full scale) as a horizontal bar on a faint track, on the meters' scale
/// and in their zone colors; red at full scale.
fn paintLevelBar(p: anytype, r: Rect, peak: f32) void {
    p.fill(r, color.tile);
    if (peak >= 1) return p.fill(r, color.record);
    const w: f32 = @floatFromInt(r.right - r.left);
    const at = struct {
        fn f(rect: Rect, width: f32, db: f32) i32 {
            return rect.left + @as(i32, @intFromFloat(@round(width * meterFraction(db))));
        }
    }.f;
    const end = if (peak > 0) at(r, w, 20 * std.math.log10(peak)) else r.left;
    for (level_zones, 0..) |zone, z| {
        const left = if (z == 0) r.left else at(r, w, zone.from_db);
        const right = @min(end, if (z + 1 < level_zones.len) at(r, w, level_zones[z + 1].from_db) else r.right);
        if (right > left) p.fill(.{ .left = left, .top = r.top, .right = right, .bottom = r.bottom }, zone.color);
    }
}

/// A level meter over time, a column per pixel. Each column has a solid body up to its
/// momentary loudness (how loud it sounds, BS.1770) and a fainter cap up to its peak (how close
/// to clipping), both colored by zone like a meter's segments, on meterFraction's scale. A
/// column that clipped is red, full height.
///
/// Column c covers buckets [c * shown / width, (c + 1) * shown / width), counting both from
/// the first bucket, not back from the newest: so each column keeps the same buckets as it
/// scrolls. Counted back from the newest, which columns cover one bucket and which two would
/// change with every bucket, and their heights would shimmer.
///
/// Drawn as shapes, not a rectangle per column and zone: the bodies of a run of columns are
/// one band (their tops down to the bottom) and the caps another (peaks down to the bodies),
/// each filled once with the zones as a gradient of hard stops. A few calls a lane, not
/// thousands. Returns the columns there were, so the next frame can tell whether anything
/// would change (see frameChanged).
fn paintLevels(p: anytype, s: Scale, lane: Rect, meter: *const Meter) u64 {
    const width: u64 = @intCast(@max(lane.right - lane.left, 0));
    const count = meter.count.load(.acquire);
    const columns = levelColumns(count, width);
    const shown = levels_shown;
    const min_h = @max(1, s.px(1));
    const scale: LevelScale = .{ .bottom = lane.bottom, .h = @floatFromInt(lane.bottom - lane.top) };

    // Faint bands behind the loud and close-to-clipping zones, so where the levels sit reads
    // at a glance.
    {
        const loud_y = scale.y(level_zones[2].from_db);
        const hot_y = scale.y(level_zones[3].from_db);
        p.fill(.{ .left = lane.left, .top = hot_y, .right = lane.right, .bottom = loud_y }, color.loud_band);
        p.fill(.{ .left = lane.left, .top = lane.top, .right = lane.right, .bottom = hot_y }, color.hot_band);
    }

    // The zones as gradient stops, for the bodies and, fainter, the caps.
    var body_zones: [level_zones.len]GradientStop = undefined;
    var cap_zones: [level_zones.len]GradientStop = undefined;
    for (level_zones, &body_zones, &cap_zones, 0..) |zone, *body, *cap, z| {
        const y = if (z == 0) lane.bottom else scale.y(zone.from_db);
        body.* = .{ .y = y, .color = zone.color };
        cap.* = .{ .y = y, .color = zone.color };
        cap.color.a = 110;
    }
    const body_gradient: Gradient = .{ .bottom = lane.bottom, .top = lane.top, .stops = &body_zones };
    const cap_gradient: Gradient = .{ .bottom = lane.bottom, .top = lane.top, .stops = &cap_zones };

    // A run of columns at a time: each column's body top, its cap top, and the lane bottom.
    var body_tops: [band_columns]i32 = undefined;
    var cap_tops: [band_columns]i32 = undefined;
    var bottoms: [band_columns]i32 = undefined;
    @memset(&bottoms, lane.bottom);
    var run_start: u64 = 0;
    while (run_start < width) : (run_start += band_columns) {
        const n: usize = @intCast(@min(band_columns, width - run_start));
        for (0..n) |i| {
            const x = run_start + i;
            // Nothing to show (yet, or any more): no height.
            body_tops[i] = lane.bottom;
            cap_tops[i] = lane.bottom;
            // Column number `columns - width + x`, if it exists and hasn't been overwritten.
            if (columns + x < width) continue;
            const c = columns + x - width;
            const first = c * shown / width;
            // Wider than `shown` pixels, some columns fall within one bucket: they show it.
            const end = @max((c + 1) * shown / width, first + 1);
            if (end > count or count - first > Meter.len) continue;
            var peak: u16 = 0;
            var loudness: u16 = 0;
            for (first..end) |b| {
                const bucket = meter.bucket(b);
                peak = @max(peak, bucket.peak);
                loudness = @max(loudness, bucket.loudness);
            }
            if (peak == Meter.Bucket.clipped) {
                const left = lane.left + @as(i32, @intCast(x));
                p.fill(.{ .left = left, .top = lane.top, .right = left + 1, .bottom = lane.bottom }, color.record);
                continue;
            }
            // In LUFS, Bucket.loudness's offset. Always at least a line, so silence still shows
            // the audio is arriving.
            body_tops[i] = @min(scale.y(decibels(loudness) - 0.691), lane.bottom - min_h);
            cap_tops[i] = @min(scale.y(decibels(peak)), body_tops[i]);
        }
        const left = lane.left + @as(i32, @intCast(run_start));
        p.band(left, body_tops[0..n], bottoms[0..n], body_gradient);
        p.band(left, cap_tops[0..n], body_tops[0..n], cap_gradient);
    }
    return columns;
}

/// Columns a level band takes at most, see Painter.band.
pub const band_columns = 1024;

/// A vertical gradient of hard stops, for Painter.band: from `bottom` up to `top`, each stop's
/// color from its y (going up) to the next one's.
pub const Gradient = struct {
    bottom: i32,
    top: i32,
    /// Bottom first.
    stops: []const GradientStop,
};

pub const GradientStop = struct { y: i32, color: Color };

/// Buckets a lane shows across its width.
const levels_shown: u64 = levels_seconds * 1000 / Meter.bucket_ms;

/// The complete columns a lane of `width` pixels has after `count` buckets, those whose
/// buckets have all arrived, so the newest doesn't grow: column c is complete when
/// (c + 1) * shown / width <= count.
fn levelColumns(count: u64, width: u64) u64 {
    return ((count + 1) * width -| 1) / levels_shown;
}

/// dB below full scale of a Bucket value.
fn decibels(v: u16) f32 {
    if (v == 0) return -std.math.inf(f32);
    return 20 * std.math.log10(@as(f32, @floatFromInt(v)) / Meter.Bucket.full);
}

/// A lane's vertical scale, see meterFraction.
const LevelScale = struct {
    bottom: i32,
    h: f32,

    fn y(l: LevelScale, db: f32) i32 {
        return l.bottom - @as(i32, @intFromFloat(@round(l.h * meterFraction(db))));
    }
};

/// Paints the open menu into its popup window, laid out as menuRect says.
pub fn paintMenu(p: anytype, width: i32, dpi: u32) void {
    const s: Scale = .{ .dpi = dpi };
    p.clear(color.menu);
    const menu = state.menu orelse return;
    // The live counts as of this paint (see menuChanged).
    switch (menu) {
        .track => |id| if (findSource(id)) |src| {
            state.track_menu_frames = src.frameCounts();
        },
        .devices, .todo, .more => {},
    }
    const hot_item = menuHot();
    const row_h = s.px(menu_row_px);
    const icon_w = s.px(menu_icon_px);
    const check_w = menuCheckWidth(menu, s);
    const text_left = menuTextLeft(menu, s);
    for (0..menuRowCount(menu)) |i| {
        const row = menuRow(menu, i);
        const y = @as(i32, @intCast(i)) * row_h;
        const r: Rect = .{ .left = 0, .top = y, .right = width, .bottom = y + row_h };
        if (row.item != null and std.meta.eql(row.item, hot_item)) p.fill(r, color.tile_hot);
        const fg = if (row.item == null) color.dim else color.text;
        // The checkmark first, in the column menus with checkable rows have.
        if (row.checked) p.icon(.check, .{ .left = r.left, .top = r.top, .right = r.left + check_w, .bottom = r.bottom }, .icon_small, color.check);
        if (row.icon) |icon| p.icon(icon, .{ .left = r.left + check_w, .top = r.top, .right = r.left + check_w + icon_w, .bottom = r.bottom }, .icon_small, fg);
        const text_right = r.right - s.px(menu_text_right_px);
        if (row.note) |note| {
            const tag_h = s.px(menu_tag_h_px);
            const tag_top = r.top + @divTrunc(row_h - tag_h, 2);
            const tag: Rect = .{ .left = text_right - state.menu_note_w - 2 * s.px(menu_tag_pad_px), .top = tag_top, .right = text_right, .bottom = tag_top + tag_h };
            p.pill(tag, color.accent);
            p.text(note, tag, .small, color.text, .center);
        }
        p.text(row.text.slice(), .{ .left = text_left, .top = r.top, .right = text_right, .bottom = r.bottom }, .normal, fg, .left);
        // A device's live level, along the row's bottom under its name.
        if (menu == .devices) if (state.device_levels) |levels| {
            const bits = levels[i].load(.monotonic);
            if (bits != no_level) {
                const bottom = r.bottom - s.px(menu_level_bottom_px);
                paintLevelBar(p, .{ .left = text_left, .top = bottom - @max(1, s.px(menu_level_h_px)), .right = text_right, .bottom = bottom }, @bitCast(bits));
            }
        };
        if (row.divider_below) p.fill(.{ .left = r.left, .top = r.bottom - @max(1, s.px(1)), .right = r.right, .bottom = r.bottom }, color.divider);
    }
}

const menu_icon_px = 36;
/// The checkmark column, at the left of menus with checkable rows.
const menu_check_px = 30;
const menu_min_w_px = 190;
/// Space after a row's text.
const menu_text_right_px = 16;

/// The checkmark column's width: menus whose rows can be checked have one (devices already
/// added, settings that are on), even while no row is.
fn menuCheckWidth(menu: Menu, s: Scale) i32 {
    return switch (menu) {
        .devices, .more => s.px(menu_check_px),
        .todo, .track => 0,
    };
}

/// Text lines up with text after an icon, even in rows without one.
fn menuTextLeft(menu: Menu, s: Scale) i32 {
    return menuCheckWidth(menu, s) + switch (menu) {
        .todo, .devices, .track => s.px(menu_icon_px),
        .more => 0,
    };
}

fn line(left: i32, right: i32, top: i32, h: i32) Rect {
    return .{ .left = left, .top = top, .right = right, .bottom = top + h };
}

const Scale = struct {
    dpi: u32,
    fn px(s: Scale, v: i32) i32 {
        return @intCast(@divTrunc(@as(i64, v) * s.dpi, 96));
    }
};

fn fmtBytes(n: u64) std.fmt.Alt(u64, formatBytes) {
    return .{ .data = n };
}
fn formatBytes(n: u64, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var v: f64 = @floatFromInt(n);
    var i: usize = 0;
    while (v >= 1000 and i + 1 < units.len) : (i += 1) v /= 1000;
    try w.print("{d:.1} {s}", .{ v, units[i] });
}

// ---------------------------------------------------------------------------
// Tests. They drive the app as the platform does: input, then paint (which lays out what's
// clicked next) into a TestPainter that keeps the text drawn.
// ---------------------------------------------------------------------------

/// A painter that draws nothing but keeps every text drawn, with its rect and color, so a test
/// can check what's on screen. Text is copied: callers often pass their own stack buffers.
const TestPainter = struct {
    texts: [max_texts]Text = undefined,
    count: usize = 0,
    chars: [8192]u8 = undefined,
    chars_len: usize = 0,

    const max_texts = 128;
    const Text = struct { start: usize, len: usize, rect: Rect, font: Font, color: Color };

    fn clear(_: *TestPainter, _: Color) void {}
    fn fill(_: *TestPainter, _: Rect, _: Color) void {}
    fn ellipse(_: *TestPainter, _: Rect, _: Color) void {}
    fn pill(_: *TestPainter, _: Rect, _: Color) void {}
    fn icon(_: *TestPainter, _: Icon, _: Rect, _: Font, _: Color) void {}
    fn band(_: *TestPainter, _: i32, upper: []const i32, lower: []const i32, _: Gradient) void {
        if (upper.len != lower.len or upper.len > band_columns) std.debug.panic("band of {d} uppers and {d} lowers, at most {d}", .{ upper.len, lower.len, band_columns });
        for (upper, lower, 0..) |u, l, i| if (u > l) std.debug.panic("band column {d} is upside down: {d} above {d}", .{ i, u, l });
    }
    fn text(p: *TestPainter, t: []const u8, r: Rect, font: Font, c: Color, _: Align) void {
        if (p.count == max_texts or p.chars_len + t.len > p.chars.len) std.debug.panic("TestPainter is full, can't keep '{s}'", .{t});
        @memcpy(p.chars[p.chars_len..][0..t.len], t);
        p.texts[p.count] = .{ .start = p.chars_len, .len = t.len, .rect = r, .font = font, .color = c };
        p.count += 1;
        p.chars_len += t.len;
    }
    /// A monospace stand-in, for Painter.textWidth and menuRect's measure alike.
    fn textWidth(_: *TestPainter, t: []const u8, _: Font) i32 {
        return @intCast(t.len * 8);
    }
    fn width(p: *TestPainter, t: []const u8, f: Font) i32 {
        return p.textWidth(t, f);
    }

    fn slice(p: *const TestPainter, t: Text) []const u8 {
        return p.chars[t.start..][0..t.len];
    }
    /// The text drawn exactly as `s`, if it was.
    fn find(p: *const TestPainter, s: []const u8) ?Text {
        for (p.texts[0..p.count]) |t| if (std.mem.eql(u8, p.slice(t), s)) return t;
        return null;
    }
    /// The text of the one badge drawn (Font.badge), if any. Fails if there are several.
    fn badge(p: *const TestPainter) !?[]const u8 {
        var found: ?[]const u8 = null;
        for (p.texts[0..p.count]) |t| if (t.font == .badge) {
            if (found) |f| {
                std.debug.print("two badges drawn: '{s}' and '{s}'\n", .{ f, p.slice(t) });
                return error.TestUnexpectedResult;
            }
            found = p.slice(t);
        };
        return found;
    }
    /// Fails, listing what was drawn, unless `s` was.
    fn expectText(p: *const TestPainter, s: []const u8) !void {
        if (p.find(s) != null) return;
        std.debug.print("'{s}' wasn't drawn, these were:\n", .{s});
        for (p.texts[0..p.count]) |t| std.debug.print("  '{s}'\n", .{p.slice(t)});
        return error.TestExpectedEqual;
    }
};

const test_w = 600;
const test_h = 400;

/// Paints the window as the platform would, at 96 DPI, so the next input hits what's on screen.
fn testPaint(p: *TestPainter) void {
    p.* = .{};
    paint(p, test_w, test_h, 96);
}

/// Lays out and paints the open menu, as the platform does when it opens.
fn testPaintMenu(p: *TestPainter) void {
    p.* = .{};
    const r = menuRect(96, p);
    paintMenu(p, r.right - r.left, 96);
}

fn testCenter(r: Rect) Point {
    std.debug.assert(r.right > r.left and r.bottom > r.top);
    return .{ .x = @divTrunc(r.left + r.right, 2), .y = @divTrunc(r.top + r.bottom, 2) };
}

/// Presses and releases the left button in the middle of `r` (as last painted).
fn testClick(r: Rect) void {
    const c = testCenter(r);
    _ = onMouseDown(c.x, c.y);
    _ = onMouseUp(c.x, c.y);
}

/// Clicks the open menu's row `i` (menuRect must have laid it out). Returns whether an item
/// was chosen.
fn testClickMenuRow(i: usize) bool {
    const y = @as(i32, @intCast(i)) * state.menu_row_h + @divTrunc(state.menu_row_h, 2);
    onMenuMouseDown(10, y);
    return onMenuMouseUp(10, y);
}

/// A device as the platform lists it, its strings owned by bb's allocator.
fn testDevice(name: []const u8, form: ?Device.Form) !Device {
    const n = try gpa.dupe(u8, name);
    errdefer gpa.free(n);
    return .{ .name = n, .id = try std.fmt.allocPrint(gpa, "id:{s}", .{name}), .format = null, .form = form };
}

test "the record button needs something to record, but can always stop" {
    init(std.testing.allocator);
    defer deinit();
    var p: TestPainter = .{};
    testPaint(&p);
    // Nothing to record: neither a click nor the keyboard starts a recording.
    testClick(state.button);
    try std.testing.expect(!isRecording());
    try std.testing.expect(!onKeyActivate());
    try std.testing.expect(!isRecording());

    addSource(.microphone, try testDevice("Mic", .microphone));
    testPaint(&p);
    testClick(state.button);
    try std.testing.expect(isRecording());
    // With the last source gone mid-recording, it can still be stopped.
    removeSource(state.sources.items[0].id);
    testPaint(&p);
    testClick(state.button);
    try std.testing.expect(!isRecording());
}

test "a button acts on release, only if the press started there and never left" {
    init(std.testing.allocator);
    defer deinit();
    var p: TestPainter = .{};
    testPaint(&p);
    const pin = testCenter(state.pin_button);
    const collapse = testCenter(state.collapse_button);
    // The margin is nothing: there a press drags the window.
    try std.testing.expect(isDragArea(1, 1));
    try std.testing.expect(!isDragArea(pin.x, pin.y));

    testClick(state.pin_button);
    try std.testing.expect(settings().always_on_top);

    // Moved off and back before the release: abandoned.
    try std.testing.expect(onMouseDown(pin.x, pin.y));
    try std.testing.expect(onMouseMove(1, 1));
    try std.testing.expect(onMouseMove(pin.x, pin.y));
    try std.testing.expect(!onMouseUp(pin.x, pin.y));
    try std.testing.expect(settings().always_on_top);

    // Pressed on one button, released on another: neither acts.
    _ = onMouseDown(pin.x, pin.y);
    _ = onMouseUp(collapse.x, collapse.y);
    try std.testing.expect(settings().always_on_top);
    try std.testing.expect(!settings().collapsed);

    // Moving within the same button needs no repaint, and keeps the press.
    _ = onMouseDown(pin.x, pin.y);
    try std.testing.expect(!onMouseMove(pin.x + 1, pin.y));
    _ = onMouseUp(pin.x + 1, pin.y);
    try std.testing.expect(!settings().always_on_top);

    testClick(state.minimize_button);
    try std.testing.expect(takeMinimize());
    try std.testing.expect(!takeMinimize());
}

test "adding a device: listed in order, each added once, the list freed with the menu" {
    init(std.testing.allocator);
    defer deinit();
    var p: TestPainter = .{};
    testPaint(&p);

    testClick(state.add_buttons[@intFromEnum(SourceKind.microphone)]);
    try std.testing.expectEqual(Menu{ .devices = .microphone }, openMenu().?);
    // The platform lists them once per opening, in its own order.
    try std.testing.expectEqual(SourceKind.microphone, takeDeviceListRequest().?);
    try std.testing.expectEqual(null, takeDeviceListRequest());
    const listed = [_]struct { []const u8, ?Device.Form }{
        .{ "zeta", .microphone },
        .{ "Unknown thing", null },
        .{ "Headset Mic", .headset },
        .{ "alpha", .microphone },
        .{ "Beta", .microphone },
    };
    for (listed) |d| addDevice(try testDevice(d[0], d[1]));
    // By form (as Form lists them, unknown last), then name ignoring case.
    const sorted = [_][]const u8{ "Headset Mic", "alpha", "Beta", "zeta", "Unknown thing" };
    for (sorted, listedDevices()) |name, d| try std.testing.expectEqualStrings(name, d.name);

    testPaintMenu(&p);
    try std.testing.expect(testClickMenuRow(1));
    try std.testing.expectEqual(null, openMenu());
    try std.testing.expectEqual(0, listedDevices().len);
    try std.testing.expectEqual(1, sources().len);
    try std.testing.expectEqualStrings("alpha", sources()[0].name());
    try std.testing.expectEqualStrings("id:alpha", sources()[0].device.?.id);

    // Listed again: the one already added is checked and can't be chosen again.
    testPaint(&p);
    testClick(state.add_buttons[@intFromEnum(SourceKind.microphone)]);
    _ = takeDeviceListRequest();
    for (listed) |d| addDevice(try testDevice(d[0], d[1]));
    const row = menuRow(state.menu.?, 1);
    try std.testing.expect(row.checked and row.item == null);
    testPaintMenu(&p);
    try std.testing.expect(!testClickMenuRow(1));
    try std.testing.expect(openMenu() != null);
    // Below the last row is nothing.
    try std.testing.expect(!testClickMenuRow(listed.len));
    // A click in the window only closes the menu (and frees the list, else the testing
    // allocator reports a leak).
    try std.testing.expect(onMouseDown(1, 1));
    try std.testing.expectEqual(null, openMenu());
    try std.testing.expectEqual(1, sources().len);

    // None to list: the menu says so, with nothing to choose.
    testClick(state.add_buttons[@intFromEnum(SourceKind.system_audio)]);
    _ = takeDeviceListRequest();
    testPaintMenu(&p);
    try p.expectText("No outputs found");
    try std.testing.expect(!testClickMenuRow(0));
}

test "a webcam is added from its devices menu, like a microphone" {
    init(std.testing.allocator);
    defer deinit();
    var p: TestPainter = .{};
    testPaint(&p);
    testClick(state.add_buttons[@intFromEnum(SourceKind.webcam)]);
    try std.testing.expectEqual(Menu{ .devices = .webcam }, openMenu().?);
    try std.testing.expectEqual(SourceKind.webcam, takeDeviceListRequest().?);
    // The platform's webcams have no audio format or form: the webcam icon.
    addDevice(try testDevice("Front Camera", null));
    try std.testing.expect(!menuAnimating());
    testPaintMenu(&p);
    try std.testing.expectEqual(Icon.webcam, menuRow(state.menu.?, 0).icon.?);
    try std.testing.expect(testClickMenuRow(0));
    try std.testing.expectEqual(null, openMenu());
    try std.testing.expectEqual(0, listedDevices().len);
    try std.testing.expectEqual(1, sources().len);
    try std.testing.expectEqual(SourceKind.webcam, sources()[0].kind);
    try std.testing.expectEqualStrings("id:Front Camera", sources()[0].device.?.id);

    // Live, its menu says what it captures and what encodes it, and where.
    var live: SourceStatus.VideoLive = .{ .format = .{ .width = 1920, .height = 1080, .fps_num = 30000, .fps_den = 1001 }, .bitrate = 6_300_000, .path = .gpu, .camera_converted = true };
    const name = "Test Encoder";
    @memcpy(live.encoder_buf[0..name.len], name);
    live.encoder_len = name.len;
    const gpu_name = "Test GPU";
    @memcpy(live.gpu_buf[0..gpu_name.len], gpu_name);
    live.gpu_len = gpu_name.len;
    @memcpy(live.camera_format_buf[0..4], "MJPG");
    live.camera_format_len = 4;
    const id = sources()[0].id;
    setSourceStatus(id, .{ .live = .{ .video = live } });
    // A webcam alone still has the timeline: the recording's time, and the playhead.
    testPaint(&p);
    try p.expectText("0:00");
    var counts: VideoCounts = .{};
    counts.encoded.store(1234, .monotonic);
    counts.dropped.store(3, .monotonic);
    setSourceVideoCounts(id, &counts);
    testPaint(&p);
    testClick(findSource(id).?.track_button);
    try std.testing.expectEqual(Menu{ .track = id }, openMenu().?);
    testPaintMenu(&p);
    try p.expectText("Captured as 1920x1080 at 30 fps");
    try p.expectText("Camera sends MJPG, converted for the encoder");
    try p.expectText("Encoded by Test Encoder");
    try p.expectText("GPU");
    try p.expectText("On Test GPU");
    try p.expectText("Target bitrate 6.3 Mbit/s");
    try p.expectText("Frames: 1234 encoded, 3 dropped");
    // The counts are live: the menu repaints when they change, and only then, and stays the
    // size it opened at as they grow.
    try std.testing.expect(menuAnimating());
    try std.testing.expect(!menuChanged());
    const opened = menuRect(96, &p);
    counts.encoded.store(99_999_999, .monotonic);
    try std.testing.expect(menuChanged());
    testPaintMenu(&p);
    try std.testing.expect(!menuChanged());
    try p.expectText("Frames: 99999999 encoded, 3 dropped");
    try std.testing.expectEqual(opened, menuRect(96, &p));
    _ = closeMenu();
    // Encoded by the CPU: no GPU to name.
    live.path = .software;
    setSourceStatus(id, .{ .live = .{ .video = live } });
    testClick(findSource(id).?.track_button);
    testPaintMenu(&p);
    try p.expectText("On the CPU");
    _ = closeMenu();

    // No webcams: the menu says so.
    testClick(state.add_buttons[@intFromEnum(SourceKind.webcam)]);
    _ = takeDeviceListRequest();
    testPaintMenu(&p);
    try p.expectText("No webcams found");
    try std.testing.expect(!testClickMenuRow(0));
}

test "a kind not recordable yet says so instead of adding" {
    init(std.testing.allocator);
    defer deinit();
    var p: TestPainter = .{};
    testPaint(&p);
    for ([_]SourceKind{.screen}) |kind| {
        testClick(state.add_buttons[@intFromEnum(kind)]);
        try std.testing.expectEqual(Menu{ .todo = kind }, openMenu().?);
        try std.testing.expectEqual(null, takeDeviceListRequest());
        testPaintMenu(&p);
        try p.expectText(kind.todo().?);
        try std.testing.expect(!testClickMenuRow(0));
        _ = closeMenu();
    }
    try std.testing.expectEqual(0, sources().len);
}

test "a track's rows depend on its kind, never its state" {
    var buf: [std.enums.values(TrackRow).len]TrackRow = undefined;
    const live: SourceStatus = .{ .live = .{ .audio = .{ .format = .{ .sample = .float, .bits = 32, .rate = 48000, .channels = 2 }, .raw = true } } };
    const statuses = [_]SourceStatus{ .starting, live, .{ .failed = .init("no device", .{}) } };
    const buffers = [_]?Buffer{ null, .{ .bytes = 1 << 20, .ms = 5000 } };
    for (std.enums.values(SourceKind)) |kind| {
        const want: []const TrackRow = switch (kind) {
            .microphone, .system_audio => &.{ .name, .device_format, .captured_as, .effects, .buffer, .clips, .remove },
            .webcam => &.{ .name, .captured_as, .camera_format, .encoder, .gpu, .bitrate, .frames, .buffer, .remove },
            .screen => &.{ .name, .captured_as, .encoder, .gpu, .bitrate, .frames, .buffer, .remove },
        };
        for (statuses) |status| for (buffers) |buffer| {
            const src: Source = .{ .kind = kind, .id = 1, .device = null, .status = status, .buffer = buffer, .clips_cleared = 3 };
            try std.testing.expectEqualSlices(TrackRow, want, trackRows(&src, &buf));
        };
    }
}

test "quitting while recording isn't asked, removing a track is" {
    init(std.testing.allocator);
    defer deinit();
    var p: TestPainter = .{};
    // Not recording: Quit quits.
    requestQuit();
    try std.testing.expectEqual(QuitRequest.quit, takeQuitRequest());
    try std.testing.expectEqual(null, takeConfirm());
    state.quit_requested = null;

    addSource(.microphone, try testDevice("Mic", .microphone));
    const id = sources()[0].id;
    testPaint(&p);
    testClick(state.button);
    try std.testing.expect(isRecording());
    // Recording: Quit quits too (the recording stops, its files are finished), not asked.
    requestQuit();
    try std.testing.expectEqual(QuitRequest.quit, takeQuitRequest());
    try std.testing.expectEqual(null, takeConfirm());
    state.quit_requested = null;

    // Its track's Remove: asked, naming it; no (not confirmed) keeps it, yes removes it.
    testPaint(&p);
    testClick(findSource(id).?.track_button);
    testPaintMenu(&p);
    var buf: [std.enums.values(TrackRow).len]TrackRow = undefined;
    try std.testing.expect(testClickMenuRow(trackRows(findSource(id).?, &buf).len - 1));
    const remove = takeConfirm().?;
    try std.testing.expectEqual(Confirm{ .remove = id }, remove);
    var text_buf: [256]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, confirmText(remove, &text_buf).message, "Mic stops being recorded now."));
    try std.testing.expectEqual(1, sources().len);
    confirmed(remove);
    try std.testing.expectEqual(0, sources().len);
}

test "a track's menu clears the clips it showed, and removes the track" {
    init(std.testing.allocator);
    defer deinit();
    var p: TestPainter = .{};
    var meter: Meter = .{};
    addSource(.microphone, try testDevice("Mic", .microphone));
    const id = sources()[0].id;
    setSourceMeter(id, &meter);
    setSourceStatus(id, .{ .live = .{ .audio = .{ .format = .{ .sample = .float, .bits = 32, .rate = 48000, .channels = 2 }, .raw = true } } });
    // Two runs of clipping: two clips.
    for ([_]f32{ 1.0, 1.2, 0.5, 1.0 }) |peak| meter.push(peak, 0.1);
    testPaint(&p);
    try std.testing.expectEqualStrings("2", (try p.badge()).?);
    testClick(findSource(id).?.track_button);
    try std.testing.expectEqual(Menu{ .track = id }, openMenu().?);
    testPaintMenu(&p);
    try p.expectText("Mic");
    try p.expectText("Captured as 32-bit float, 48000 Hz, 2 ch");
    try p.expectText("Raw: Windows audio effects bypassed");
    try p.expectText("Clipped 2\u{00D7} \u{00B7} Clear");

    // Clipping again while the menu's open: that one wasn't shown, so it stays.
    meter.push(0.1, 0.1);
    meter.push(1.0, 0.1);
    try std.testing.expect(testClickMenuRow(5));
    try std.testing.expectEqual(1, findSource(id).?.clips());

    testPaint(&p);
    testClick(findSource(id).?.track_button);
    testPaintMenu(&p);
    try std.testing.expect(testClickMenuRow(6));
    try std.testing.expectEqual(0, sources().len);
}

test "the clip badge counts to 99" {
    init(std.testing.allocator);
    defer deinit();
    var p: TestPainter = .{};
    var meter: Meter = .{};
    addSource(.microphone, null);
    setSourceMeter(sources()[0].id, &meter);
    // No clips, no badge.
    testPaint(&p);
    try std.testing.expectEqual(null, try p.badge());
    for (0..100) |_| {
        meter.push(1.0, 0.5);
        meter.push(0.0, 0.0);
    }
    testPaint(&p);
    try std.testing.expectEqualStrings("99+", (try p.badge()).?);
    state.sources.items[0].clips_cleared = 1;
    testPaint(&p);
    try std.testing.expectEqualStrings("99", (try p.badge()).?);
    state.sources.items[0].clips_cleared = 91;
    testPaint(&p);
    try std.testing.expectEqualStrings("9", (try p.badge()).?);
    // All cleared: gone again.
    state.sources.items[0].clips_cleared = 100;
    testPaint(&p);
    try std.testing.expectEqual(null, try p.badge());
}

test "collapsed: only the top bar shows and can be clicked" {
    init(std.testing.allocator);
    defer deinit();
    var p: TestPainter = .{};
    addSource(.microphone, null);
    testPaint(&p);
    const track = testCenter(state.sources.items[0].track_button);
    testClick(state.collapse_button);
    try std.testing.expect(settings().collapsed);
    testPaint(&p);
    try std.testing.expect(isDragArea(track.x, track.y));
    for (state.add_buttons) |r| try std.testing.expectEqual(empty_rect, r);
    testClick(state.collapse_button);
    try std.testing.expect(!settings().collapsed);

    // Its height: the margins and the bar, and room for a capture warning, which must show.
    try std.testing.expectEqual(16 + 36 + 16, collapsedHeight(96));
    try std.testing.expectEqual(24 + 54 + 24, collapsedHeight(144));
    setCaptureExclusion(.{ .failed = 5 });
    try std.testing.expectEqual(16 + 36 + 16 + 24 + 8, collapsedHeight(96));
    testPaint(&p);
    try p.expectText("Warning: hiding this window from screen capture failed (error 5), it may appear in recordings.");
    // Not excluding: nothing to warn about.
    testClick(state.more_button);
    testPaintMenu(&p);
    try std.testing.expect(testClickMenuRow(0));
    try std.testing.expect(!settings().exclude_from_capture);
    try std.testing.expectEqual(16 + 36 + 16, collapsedHeight(96));
}

test "quitting while recording stops it, and says the window closes once it's finished" {
    init(std.testing.allocator);
    defer deinit();
    var p: TestPainter = .{};
    addSource(.microphone, try testDevice("Mic", .microphone));
    testPaint(&p);
    testClick(state.button);
    try std.testing.expect(isRecording());
    closeWhenFinished();
    try std.testing.expect(!isRecording() and isClosing());
    testPaint(&p);
    try p.expectText(closing_text);
    // Nothing new starts while it closes.
    testClick(state.button);
    try std.testing.expect(!isRecording());
    // A problem finishing the files: it shows, and closing stops, so it isn't closed over.
    recordingProblem(.init("Writing the recording file failed: the disk is full", .{}));
    try std.testing.expect(!isClosing() and !isRecording());
    testPaint(&p);
    try p.expectText("Writing the recording file failed: the disk is full");
    try std.testing.expect(p.find(closing_text) == null);
}

test "while closing, Quit is Force Quit, with a note saying what's left and what it does" {
    init(std.testing.allocator);
    defer deinit();
    var p: TestPainter = .{};
    addSource(.microphone, try testDevice("Mic", .microphone));
    testPaint(&p);
    testClick(state.button);
    closeWhenFinished();
    testPaint(&p);
    try p.expectText(closing_text);
    testClick(state.more_button);
    testPaintMenu(&p);
    try p.expectText("Force Quit");
    // Its note, before how much is left is known: just what Force Quit does.
    const note = menuNote().?;
    try std.testing.expectEqualStrings("", note.line(0));
    try std.testing.expectEqualStrings("Force Quit quits now, leaving them", note.line(3));
    // Then how much, in the note and the top bar.
    setFinishingLeft(.{ .bytes = 12_400_000, .seconds = 9 });
    try std.testing.expectEqualStrings("12.4 MB left, about 9 seconds", menuNote().?.line(0));
    testPaint(&p);
    try p.expectText("Finishing the recording\u{2026} 12.4 MB left, about 9 seconds");
    // Closing again (the window closed again) keeps it.
    closeWhenFinished();
    try std.testing.expectEqualStrings("12.4 MB left, about 9 seconds", menuNote().?.line(0));
    // Chosen: quit now.
    try std.testing.expectEqual(null, takeQuitRequest());
    try std.testing.expect(testClickMenuRow(1));
    try std.testing.expectEqual(QuitRequest.force_quit, takeQuitRequest());
    // Not closing, it's Quit again, and no note.
    state.mode = .idle;
    testClick(state.more_button);
    testPaintMenu(&p);
    try p.expectText("Quit");
    try std.testing.expectEqual(null, menuNote());
}

test fmtFinishingLeft {
    try std.testing.expectFmt("640.0 KB left", "{f}", .{fmtFinishingLeft(.{ .bytes = 640_000, .seconds = null })});
    try std.testing.expectFmt("12.4 MB left, about 1 second", "{f}", .{fmtFinishingLeft(.{ .bytes = 12_400_000, .seconds = 1 })});
    try std.testing.expectFmt("3.2 GB left, about 2 minutes", "{f}", .{fmtFinishingLeft(.{ .bytes = 3_200_000_000, .seconds = 150 })});
    // The longest there is fits the room kept for any.
    var buf: [finishing_left_max]u8 = undefined;
    const longest = try std.fmt.bufPrint(&buf, "{f}", .{fmtFinishingLeft(.{ .bytes = std.math.maxInt(u64), .seconds = std.math.maxInt(u64) })});
    try std.testing.expectEqualStrings("18446744.1 TB left, about 5,124,095,576,030,431 hours", longest);
}

test "the more menu's Quit" {
    init(std.testing.allocator);
    defer deinit();
    var p: TestPainter = .{};
    testPaint(&p);
    testClick(state.more_button);
    testPaintMenu(&p);
    try std.testing.expectEqual(null, takeQuitRequest());
    try std.testing.expect(testClickMenuRow(1));
    try std.testing.expectEqual(QuitRequest.quit, takeQuitRequest());
    // Taken once: the inputs after don't quit again (closing the menu each time).
    try std.testing.expectEqual(null, takeQuitRequest());
}

test "the status: how long the disk lasts at the tracks' rate" {
    init(std.testing.allocator);
    defer deinit();
    var p: TestPainter = .{};
    testPaint(&p);
    try p.expectText("Checking free space\u{2026}");

    var mic = try testDevice("Mic", .microphone);
    mic.format = .{ .sample = .integer, .bits = 16, .rate = 48000, .channels = 2 };
    addSource(.microphone, mic);
    // 16-bit stereo at 48 kHz, captured as float: FLAC keeps the device's 16 bits, at 60%,
    // 115.2 KB/s. 5 h 20 m of that.
    const rate = 48000 * 2 * 2 * 6 / 10;
    setDisk(.{ .free = rate * (5 * 3600 + 20 * 60), .total = 1 << 40 });
    testPaint(&p);
    // Not capturing yet: no rate to go by.
    try p.expectText("2.2 GB free");

    var meter: Meter = .{};
    const id = sources()[0].id;
    setSourceMeter(id, &meter);
    setSourceStatus(id, .{ .live = .{ .audio = .{ .format = .{ .sample = .float, .bits = 32, .rate = 48000, .channels = 2 }, .raw = false } } });
    testPaint(&p);
    try p.expectText("5 hours 20 minutes left");
    try p.expectText("2.2 GB \u{00B7} 115.2 KB/s");

    // A device whose format isn't known: what's captured, up to the 24 bits FLAC stores.
    state.sources.items[0].device.?.format = null;
    testPaint(&p);
    try p.expectText("2.2 GB \u{00B7} 172.8 KB/s");

    // A failure takes the status' place until the next recording starts.
    recordingFailed(.init("disk full", .{}));
    testPaint(&p);
    try p.expectText("disk full");
    try std.testing.expectEqual(null, p.find("2.2 GB \u{00B7} 172.8 KB/s"));
    try std.testing.expect(!isRecording());
    testClick(state.button);
    testPaint(&p);
    try std.testing.expectEqual(null, p.find("disk full"));
}

test "the timeline's time" {
    init(std.testing.allocator);
    defer deinit();
    var p: TestPainter = .{};
    addSource(.microphone, null);
    testPaint(&p);
    try p.expectText("0:00");
    setRecordingElapsed(65_999);
    testPaint(&p);
    try p.expectText("1:05");
    setRecordingElapsed((1 * 3600 + 2 * 60 + 5) * 1000);
    testPaint(&p);
    try p.expectText("1:02:05");
}

test "a frame is painted only when it would look different" {
    init(std.testing.allocator);
    defer deinit();
    var p: TestPainter = .{};
    try std.testing.expect(!animating());
    var meter: Meter = .{};
    addSource(.microphone, null);
    const id = sources()[0].id;
    setSourceMeter(id, &meter);
    // Starting: nothing moves yet.
    try std.testing.expect(!animating());
    setSourceStatus(id, .{ .live = .{ .audio = .{ .format = .{ .sample = .float, .bits = 32, .rate = 48000, .channels = 1 }, .raw = false } } });
    try std.testing.expect(animating());

    testPaint(&p);
    try std.testing.expect(!frameChanged(null));
    // A bucket at a time, until the lane gains a column.
    const columns = state.sources.items[0].painted_columns;
    var pushed: usize = 0;
    while (levelColumns(meter.count.load(.monotonic), state.sources.items[0].painted_width) == columns) : (pushed += 1) {
        try std.testing.expect(!frameChanged(null));
        meter.push(0.5, 0.5);
    }
    try std.testing.expect(pushed > 0);
    try std.testing.expect(frameChanged(null));
    testPaint(&p);
    try std.testing.expect(!frameChanged(null));

    // The time changes each whole second, and when it appears.
    try std.testing.expect(frameChanged(999));
    setRecordingElapsed(1000);
    try std.testing.expect(!frameChanged(1999));
    try std.testing.expect(frameChanged(2000));

    // Collapsed, the levels don't show.
    state.settings.collapsed = true;
    try std.testing.expect(!animating());
    meter.push(0.5, 0.5);
    meter.push(0.5, 0.5);
    meter.push(0.5, 0.5);
    try std.testing.expect(!frameChanged(1000));
}

// levelColumns is the closed form of counting the columns c with (c + 1) * shown / width <=
// count; this counts them.
test levelColumns {
    for ([_]u64{ 1, 7, 333, 528, 999, 1000, 1001, 2560, 4000 }) |width| {
        for ([_]u64{ 0, 1, 2, 3, 99, 999, 1000, 1001, 123_456 }) |count| {
            var complete: u64 = 0;
            while ((complete + 1) * levels_shown / width <= count) complete += 1;
            if (levelColumns(count, width) != complete) {
                std.debug.print("width {d}, count {d}: levelColumns says {d}, there are {d}\n", .{ width, count, levelColumns(count, width), complete });
                return error.TestExpectedEqual;
            }
        }
    }
}

test meterFraction {
    try std.testing.expectEqual(0, meterFraction(-std.math.inf(f32)));
    try std.testing.expectEqual(0, meterFraction(-70));
    try std.testing.expectApproxEqAbs(0.5, meterFraction(-20), 1e-6);
    try std.testing.expectApproxEqAbs(0.85, meterFraction(-6), 1e-6);
    try std.testing.expectEqual(1, meterFraction(0));
    try std.testing.expectEqual(1, meterFraction(6));
    // Continuous and rising: no jumps at the segments' joins, so a level rising smoothly
    // moves smoothly.
    var prev = meterFraction(-80);
    var db: f32 = -80;
    while (db <= 1) : (db += 0.125) {
        const f = meterFraction(db);
        if (f < prev or f - prev > 0.125 * 0.025 + 1e-5) {
            std.debug.print("meterFraction jumps from {d} to {d} at {d} dB\n", .{ prev, f, db });
            return error.TestUnexpectedResult;
        }
        prev = f;
    }
}

test "the meter counts each run of clipping once, and keeps the newest buckets" {
    var meter: Meter = .{};
    for ([_]f32{ 0.5, 1.0, 1.0, 2.0, 0.99999994, 1.0, 0.0, 1.0 }) |peak| meter.push(peak, 0.25);
    try std.testing.expectEqual(3, meter.clips.load(.monotonic));
    try std.testing.expectEqual(8, meter.count.load(.monotonic));
    // Linear, rounded: full scale is 65534.
    try std.testing.expectEqual(32767, meter.bucket(0).peak);
    try std.testing.expectEqual(16384, meter.bucket(0).loudness);
    try std.testing.expectEqual(Meter.Bucket.clipped, meter.bucket(3).peak);
    // Just under full scale isn't a clip, however it rounds.
    try std.testing.expectEqual(Meter.Bucket.full, meter.bucket(4).peak);
    try std.testing.expectEqual(0, meter.bucket(6).peak);

    // Round the ring: bucket n is in slot n % len.
    for (0..Meter.len) |i| meter.push(@as(f32, @floatFromInt(i % 100)) / 100, 0);
    const n = meter.count.load(.monotonic);
    try std.testing.expectEqual(8 + Meter.len, n);
    try std.testing.expectEqual(Meter.Bucket.encode(@as(f32, @floatFromInt((Meter.len - 1) % 100)) / 100), meter.bucket(n - 1).peak);
    try std.testing.expectEqual(3, meter.clips.load(.monotonic));
}

test "a message too long for its buffer ends in an ellipsis" {
    const short: Message = .init("{s} failed, error {d}", .{ "Start", 5 });
    try std.testing.expectEqualStrings("Start failed, error 5", short.slice());
    const xs: [300]u8 = @splat('x');
    const long: Message = .init("{s}", .{&xs});
    try std.testing.expectEqualStrings(xs[0..197] ++ "...", long.slice());
}

test fmtDuration {
    const cases = [_]struct { u64, []const u8 }{
        .{ 0, "0 seconds" },
        .{ 1, "1 second" },
        .{ 59, "59 seconds" },
        .{ 60, "1 minute" },
        .{ 119, "1 minute" },
        .{ 3599, "59 minutes" },
        .{ 3600, "1 hour" },
        .{ 3660, "1 hour 1 minute" },
        .{ 2 * 3600 + 2 * 60, "2 hours 2 minutes" },
        .{ 10 * 3600 - 1, "9 hours 59 minutes" },
        // From ten hours, minutes are noise.
        .{ 10 * 3600 + 59 * 60, "10 hours" },
        .{ 1240 * 3600, "1,240 hours" },
        .{ 1_000_005 * 3600, "1,000,005 hours" },
    };
    for (cases) |c| {
        var buf: [64]u8 = undefined;
        try std.testing.expectEqualStrings(c[1], try std.fmt.bufPrint(&buf, "{f}", .{fmtDuration(c[0])}));
    }
}

test fmtBytes {
    const cases = [_]struct { u64, []const u8 }{
        .{ 0, "0.0 B" },
        .{ 999, "999.0 B" },
        .{ 1000, "1.0 KB" },
        .{ 1_500_000, "1.5 MB" },
        .{ 2_211_840_000, "2.2 GB" },
        .{ 3_000_000_000_000, "3.0 TB" },
        // TB is the largest unit.
        .{ 5_000_000_000_000_000, "5000.0 TB" },
    };
    for (cases) |c| {
        var buf: [64]u8 = undefined;
        try std.testing.expectEqualStrings(c[1], try std.fmt.bufPrint(&buf, "{f}", .{fmtBytes(c[0])}));
    }
}

const std = @import("std");
const maxstring = @import("maxstring.zig");
