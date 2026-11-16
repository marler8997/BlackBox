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
            .microphone, .system_audio => true,
            // TODO: pick which screen/window/webcam.
            .screen, .webcam => false,
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
            .webcam => "TODO: implement webcam recording",
            .system_audio, .microphone => null,
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
    effects,
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
            .name, .remove => true,
            .device_format => src.kind.hasDevice(),
            .captured_as, .effects, .buffer, .clips => !src.kind.isVideo(),
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

    pub const Live = struct {
        /// What we receive, which may differ from the device's (Device.format): Windows'
        /// shared mode converts.
        format: AudioFormat,
        /// Whether Windows' audio effects are bypassed. Not when the device doesn't allow it.
        raw: bool,
    };
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

const State = struct {
    settings: Settings = .{},
    capture_exclusion: CaptureExclusion = .ok,
    recording: bool = false,
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
    /// Quit was chosen; the platform closes the window.
    quit_requested: bool = false,
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
            state.track_menu_clips = findSource(id).?.clips();
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
    if (state.recording) return true;
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

pub fn quitRequested() bool {
    return state.quit_requested;
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
pub fn menuAnimating() bool {
    return state.device_levels != null;
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
};

/// Menu text, formatted without allocating: each formatted kind has room for its longest.
const MenuText = union(enum) {
    static: []const u8,
    format: AudioFormat.Text.Formatted,
    captured_as: AudioFormat.CapturedAsText.Formatted,
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
                .text = .{ .static = item.title() },
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
                .name, .device_format, .captured_as, .effects, .buffer => false,
            };
            return switch (rows[i]) {
                .name => .{ .item = null, .text = .{ .static = src.name() }, .icon = src.icon(), .divider_below = last_info },
                .device_format => .{ .item = null, .text = formatText(src.device.?.format), .divider_below = last_info },
                .captured_as => .{ .item = null, .text = switch (src.status) {
                    .live => |live| .{ .captured_as = live.format.capturedAsText() },
                    .starting => .{ .static = "Captured as: starting..." },
                    .failed => .{ .static = "Captured as: not capturing" },
                }, .divider_below = last_info },
                .effects => .{ .item = null, .text = .{ .static = switch (src.status) {
                    .live => |live| if (live.raw)
                        "Raw: Windows audio effects bypassed"
                    else
                        "Windows audio effects may apply (no raw support)",
                    .starting, .failed => "Windows audio effects: unknown until capturing",
                } }, .divider_below = last_info },
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
        // TODO: confirm when that would stop a recording.
        .more => |more| switch (more) {
            .exclude_from_capture => state.settings.exclude_from_capture = !state.settings.exclude_from_capture,
            .quit => state.quit_requested = true,
        },
        // TODO: what removing a source does to a recording in progress.
        .track => |track| switch (track) {
            // Those that happened while the menu was open stay.
            .clear_clips => findSource(menu.track).?.clips_cleared += state.track_menu_clips,
            .remove => removeSource(menu.track),
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
    state.recording = !state.recording;
    if (state.recording) {
        state.recording_error = null;
        for (state.sources.items) |*src| src.record_error = null;
    }
    return true;
}

/// Whether the user wants to be recording. The platform starts and stops the recording to
/// match, see recordingFailed.
pub fn isRecording() bool {
    return state.recording;
}

/// The recording as a whole couldn't start or continue: it stops, and the message shows in
/// the top bar until the next one.
pub fn recordingFailed(message: Message) void {
    state.recording = false;
    state.recording_error = message;
}

/// A problem with a recording that stopped nothing (its progress couldn't be saved, or one
/// being finished failed): shown in the top bar like a failure, until the next recording.
pub fn recordingProblem(message: Message) void {
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
        if (state.recording_error) |*m| {
            p.text(m.slice(), status_r, .small, color.amber, .left);
        } else {
            paintStatus(p, s, status_r);
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
        .live => |live| {
            const device_bits = if (src.device) |d| if (d.format) |f| f.bits else null else null;
            const bits: f64 = @floatFromInt(@min(device_bits orelse live.format.bits, 24));
            bps += @as(f64, @floatFromInt(live.format.rate)) * @as(f64, @floatFromInt(live.format.channels)) * bits / 8 * typical_flac_ratio;
        },
        .starting, .failed => {},
    };
    return if (bps > 0) bps else null;
}

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
    return state.recording or state.sources.items.len > 0;
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
    else if (state.recording)
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

    // Columns shared by the timeline and the tracks, so they line up.
    const icon_w = s.px(36);
    const wave_left = area.left + icon_w;
    const wave_right = area.right - s.px(4);

    const timeline_top = area.top;
    const timeline_h = s.px(20);
    const timeline_bottom = timeline_top + timeline_h;
    const tracks_top = timeline_bottom + gap;
    const tracks_bottom = tracks_top + video_count * (s.px(video_track_px) + gap) + audio_count * (s.px(audio_track_px) + gap) - gap;

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
        p.text(time, .{ .left = area.left, .top = timeline_top, .right = wave_left, .bottom = timeline_bottom }, .small, if (state.recording) color.text else color.dim, .center);
    }

    // Tracks: video first, then audio. Just an icon, no name; the icon opens the track's menu.
    {
        var y = tracks_top;
        for ([2]bool{ true, false }) |video_pass| for (state.sources.items) |*src| {
            if (src.kind.isVideo() != video_pass) continue;
            const track_h = s.px(if (video_pass) video_track_px else audio_track_px);
            const r: Rect = .{ .left = area.left, .top = y, .right = area.right, .bottom = y + track_h };
            p.fill(r, color.tile);
            const icon_r: Rect = .{ .left = r.left, .top = r.top, .right = r.left + icon_w, .bottom = r.bottom };
            src.track_button = icon_r;
            const menu_open = menuIs(.track) and state.menu.?.track == src.id;
            switch (look(.{ .track = src.id })) {
                .pressed => p.fill(icon_r, color.tile_pressed),
                .hot => p.fill(icon_r, color.tile_hot),
                .normal => if (menu_open) p.fill(icon_r, color.tile_hot),
            }
            p.icon(src.icon(), icon_r, .icon_small, color.text);
            paintClipBadge(p, s, icon_r, src.clips());
            const lane: Rect = .{ .left = wave_left, .top = r.top + s.px(4), .right = wave_right, .bottom = r.bottom - s.px(4) };
            if (src.kind.isVideo()) {
                // TODO: thumbnails, and marks where frames were dropped.
                p.fill(lane, color.video);
            }
            switch (src.status) {
                .live => if (!src.kind.isVideo()) {
                    src.painted_width = @intCast(@max(lane.right - lane.left, 0));
                    src.painted_columns = paintLevels(p, s, lane, src.meter.?);
                },
                .starting => p.text("Starting...", lane.inset(s.px(8), 0), .small, color.dim, .left),
                .failed => |*m| p.text(m.slice(), lane.inset(s.px(8), 0), .small, color.amber, .left),
            }
            // What it is, over its lane: the icon says what kind of device, this which one.
            paintTrackLabel(p, s, lane, src.name());
            if (src.record_error) |*m| {
                const r_err = lane.inset(s.px(4), s.px(4));
                p.fill(r_err, color.window);
                p.text(m.slice(), r_err.inset(s.px(4), 0), .small, color.amber, .left);
            }
            y += track_h + gap;
        };
    }

    // Playhead, across the timeline and every track. At "now" (live) until scrubbing exists.
    {
        const w = @max(2, s.px(2));
        const x = wave_right - w;
        p.fill(.{ .left = x, .top = timeline_top, .right = x + w, .bottom = tracks_bottom }, color.text);
    }

    // Video previews side by side below, each as large as fits at 16:9.
    if (video_count > 0) {
        const region_top = tracks_bottom + gap;
        const region_h = area.bottom - region_top;
        var tile_w = @divTrunc(area.right - area.left - (video_count - 1) * gap, video_count);
        var tile_h = @divTrunc(tile_w * 9, 16);
        if (tile_h > region_h) {
            tile_h = region_h;
            tile_w = @divTrunc(tile_h * 16, 9);
        }
        if (tile_h > 0) {
            const row_w = video_count * tile_w + (video_count - 1) * gap;
            var x = area.left + @divTrunc(area.right - area.left - row_w, 2);
            for (state.sources.items) |src| {
                const kind = src.kind;
                if (!kind.isVideo()) continue;
                const r: Rect = .{ .left = x, .top = region_top, .right = x + tile_w, .bottom = region_top + tile_h };
                p.fill(r, color.video);
                const mid = r.top + @divTrunc(tile_h, 2);
                p.icon(kind.icon(), .{ .left = r.left, .top = mid - s.px(36), .right = r.right, .bottom = mid + s.px(4) }, .icon, color.dim);
                p.text(kind.title(), .{ .left = r.left, .top = mid + s.px(4), .right = r.right, .bottom = mid + s.px(28) }, .small, color.dim, .center);
                x += tile_w + gap;
            }
        }
    }
}

const video_track_px = 36;
/// Taller than video: room for the level meter's zones.
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

const std = @import("std");
const maxstring = @import("maxstring.zig");
