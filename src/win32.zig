//! Windows platform layer and entry point. App logic lives in bb.zig.

// ---------------------------------------------------------------------------
// Crash handling, adapted from github.com/marler8997/zig-win32-crash-handling.
// Every panic and unhandled exception writes a report with a wintrace stack trace to a new
// file in %LOCALAPPDATA%\BlackBox\crashes, then shows a message box saying where it is.
// There's no other logging. wintrace traces are module+offset, symbolize them with
// wintrace-symbolize and the matching PDB.
// ---------------------------------------------------------------------------

pub const std_options: std.Options = .{
    .io_vtable = .threaded,
    // std's segfault handler logs and aborts without a way for us to handle it. Disabling
    // it routes to our unhandled exception filter like every other exception.
    .enable_segfault_handler = false,
    .logFn = noLogging,
};

/// Black Box doesn't log: problems are shown to the user, or crash with a report. Any use of
/// std.log fails to compile, except DebugAllocator's reports of memory bugs, which go to the
/// crash report.
fn noLogging(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime scope != .DebugAllocator)
        @compileError("Black Box doesn't log, but this logs: " ++ @tagName(level) ++ " (" ++ @tagName(scope) ++ "): " ++ format);
    prepareCrashReport();
    std.log.defaultLog(level, scope, format, args);
    // Leaks are reported one by one, then checkLeaks panics. Anything else is a bad free:
    // the program is already broken, so stop now rather than at exit.
    if (comptime !std.mem.startsWith(u8, format, "memory address 0x{x} leaked"))
        @panic("bad free, see the crash report for where");
}

pub const wintrace_options: wintrace.Options = .{ .mode = .symbolize };

const app_name = "BlackBox";

const crash = struct {
    /// How far the panic handler got. A panic while logging or showing the message box re-enters
    /// the handler, which skips the step that panicked instead of recursing forever.
    var panic_state: enum { none, log, msgbox } = .none;
    /// This process's report file, see initCrashPath. Null until main sets it.
    var path: ?[:0]const u16 = null;
    /// Where this crash's report went, for the message box.
    var report: ?union(enum) {
        file,
        no_path,
        file_failed: win32.WIN32_ERROR,
    } = null;
};

/// Creates the report file and points stderr (what wintrace and our panic handler write to)
/// at it. Once per crash: an exception raised after a panic (std.process.abort's breakpoint)
/// must not start another report.
fn prepareCrashReport() void {
    if (crash.report != null) return;
    const path = crash.path orelse {
        crash.report = .no_path;
        return;
    };
    const handle = win32.CreateFileW(path, win32.FILE_GENERIC_WRITE, .{ .READ = 1 }, null, win32.CREATE_NEW, win32.FILE_ATTRIBUTE_NORMAL, null);
    if (handle == win32.INVALID_HANDLE_VALUE) {
        crash.report = .{ .file_failed = win32.GetLastError() };
        return;
    }
    std.os.windows.peb().ProcessParameters.hStdError = handle;
    crash.report = .file;
}

pub const panic = std.debug.FullPanic(onPanic);
fn onPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    if (crash.panic_state == .none) {
        crash.panic_state = .log;
        prepareCrashReport();
        // Before the message box, which may never be dismissed.
        var buf: [256]u8 = undefined;
        const stderr = std.debug.lockStderr(&buf);
        const w = &stderr.file_writer.interface;
        write: {
            w.print("panic: {s}\n", .{msg}) catch break :write;
            wintrace.writeCurrentStackTrace(w, ret_addr orelse @returnAddress()) catch break :write;
            w.flush() catch break :write;
        }
    }
    if (crash.panic_state == .log) {
        crash.panic_state = .msgbox;
        crashMsgbox("{s}", .{msg});
    }
    // Not std.debug.defaultPanic, which would print the message and trace again.
    std.process.abort();
}

fn unhandledExceptionFilter(info: *std.os.windows.EXCEPTION_POINTERS) callconv(.winapi) c_long {
    prepareCrashReport();
    const action = wintrace.unhandledExceptionFilter(info);
    // wintrace passes on breakpoints (std.process.abort after a panic) and exceptions raised
    // while it was already reporting one.
    const execute_handler = 1;
    if (action == execute_handler) crashMsgbox("unhandled exception 0x{X:0>8} at 0x{x}", .{
        info.ExceptionRecord.ExceptionCode,
        @intFromPtr(info.ExceptionRecord.ExceptionAddress),
    });
    return action;
}

/// Sets crash.path to %LOCALAPPDATA%\BlackBox\crashes\<start time>_pid<pid>.txt, creating
/// the folders. Named now, so a crash only has to create the file. The start time and pid make
/// it unique to this process: crashes never overwrite each other, even across instances.
fn initCrashPath() void {
    var appdata: ?[*:0]u16 = null;
    {
        const hr = win32.SHGetKnownFolderPath(&win32.FOLDERID_LocalAppData, .DEFAULT, null, &appdata);
        if (hr.failed) win32.panicHresult("SHGetKnownFolderPath(LocalAppData)", hr);
    }
    defer win32.CoTaskMemFree(appdata);
    const appdata_dir = std.mem.span(appdata.?);

    var t: win32.SYSTEMTIME = undefined;
    win32.GetLocalTime(&t);
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "\\{d:0>4}-{d:0>2}-{d:0>2}_{d:0>2}-{d:0>2}-{d:0>2}_pid{d}.txt", .{
        t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond, win32.GetCurrentProcessId(),
    }) catch unreachable;

    const app_dir = win32.L("\\" ++ app_name);
    const crashes_dir = win32.L("\\crashes");
    // Needed until the process ends, so it's never freed, and doesn't come from global.gpa
    // whose leak check runs before that.
    const path = std.heap.smp_allocator.allocSentinel(u16, appdata_dir.len + app_dir.len + crashes_dir.len + name.len, 0) catch
        @panic("out of memory for the crash report path");
    var len: usize = 0;
    // Each folder is created while the path ends there; the next part overwrites the end.
    for ([_][]const u16{ appdata_dir, app_dir, crashes_dir }, 0..) |part, i| {
        @memcpy(path[len..][0..part.len], part);
        len += part.len;
        if (i > 0) {
            path[len] = 0;
            createDir(path[0..len :0]);
        }
    }
    for (name, path[len..]) |c, *w| w.* = c;
    crash.path = path;
}

/// Deinits the debug allocator, which reports leaks to stderr, so stderr goes to this run's
/// crash report file. It's deleted when nothing leaked; otherwise we panic, saying where the
/// leaks are.
/// Panics with `what` if the allocator leaked, after the leaks were written to the crash report.
fn checkLeaks(debug_allocator: *std.heap.DebugAllocator(.{}), comptime what: []const u8) void {
    prepareCrashReport();
    if (debug_allocator.deinit() == .ok) {
        if (crash.report.? == .file) {
            win32.closeHandle(std.os.windows.peb().ProcessParameters.hStdError);
            if (0 == win32.DeleteFileW(crash.path.?)) win32.panicWin32("DeleteFile(crash report)", win32.GetLastError());
        }
        crash.report = null;
        return;
    }
    @panic(what);
}

/// Creates the directory if it doesn't exist.
fn createDir(path: [:0]const u16) void {
    if (0 == win32.CreateDirectoryW(path, null)) switch (win32.GetLastError()) {
        .ERROR_ALREADY_EXISTS => {},
        else => |e| std.debug.panic("create '{f}' failed, error={f}", .{ std.unicode.fmtUtf16Le(path), e }),
    };
}

fn crashMsgbox(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt ++ "\n\n{f}", args ++ .{std.fmt.Alt(void, formatReportNote){ .data = {} }}) catch blk: {
        buf[buf.len - 3 ..].* = "...".*;
        break :blk &buf;
    };
    // Wide, for paths with non-ASCII characters. Invalid UTF-8 (in a panic message) shows as '?'.
    var wide: [buf.len:0]u16 = undefined;
    const len = std.unicode.wtf8ToWtf16Le(&wide, text) catch blk: {
        for (text, 0..) |c, i| wide[i] = if (c < 0x80) c else '?';
        break :blk text.len;
    };
    wide[len] = 0;
    _ = win32.MessageBoxW(null, wide[0..len :0], win32.L("Black Box crash"), .{ .ICONHAND = 1 });
}

fn formatReportNote(_: void, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (crash.report orelse .no_path) {
        .file => try w.print("Details were saved to {f}", .{std.unicode.fmtUtf16Le(crash.path.?)}),
        .no_path => try w.writeAll("Details couldn't be saved, this happened before the crash report file was named."),
        .file_failed => |e| try w.print("Details couldn't be saved to {f}: {f}", .{ std.unicode.fmtUtf16Le(crash.path.?), e }),
    }
}

// ---------------------------------------------------------------------------

/// Set up before the window is created and alive until after it's destroyed, so window
/// procedures can use them. What the window owns is in Window instead.
const global = struct {
    /// For allocations that come and go. See main.
    var gpa: std.mem.Allocator = undefined;
    var dwrite_factory: *win32.IDWriteFactory = undefined;
    /// Font family for bb.Icon glyphs, see findIconFont.
    var icon_family: [:0]const u16 = undefined;
    /// Where recordings go, a folder each: %LOCALAPPDATA%\BlackBox\rec. Allocated, see
    /// initPaths.
    var rec_dir: [:0]const u16 = undefined;
    /// Its strings are allocated, see initPaths.
    var disk: bb.Disk = .{};
    /// The main window's state, from its WM_CREATE to its WM_DESTROY.
    var window: ?Window = null;
};

/// What the main window owns: created in its WM_CREATE, destroyed in its WM_DESTROY, and
/// reached by the window procedures through global.window. Messages that arrive outside
/// that (some come before WM_CREATE) don't touch it.
const Window = struct {
    hwnd: win32.HWND,
    /// Popup that shows bb's menus, see menuWndProc. We own it, so Windows destroys it with
    /// us, just before our WM_DESTROY.
    menu_hwnd: win32.HWND,
    gpu: ?Gpu = null,
    main_target: ?Target = null,
    menu_target: ?Target = null,
    text_formats: ?TextFormats = null,
    tracking_mouse: bool = false,
    /// The menu menu_hwnd is showing, see syncMenu.
    menu_shown: ?bb.Menu = null,
    /// While a devices menu is open: its devices' live levels, see syncMenu.
    meters: ?*wasapi.DeviceMeters = null,
    /// A capture per bb source being captured, see syncCaptures. Their threads post to us.
    captures: std.ArrayList(*wasapi.Capture) = .empty,
    frame_clock: FrameClock = undefined,
    /// While recording, see syncRecording.
    recording: ?*record.Recording = null,
    /// Stopped recordings whose files are still being finished.
    finishing: std.ArrayList(*record.Recording) = .empty,
    /// bb's window settings as last applied, see syncWindow.
    collapsed: bool = false,
    always_on_top: bool = false,
    exclude_from_capture: bool = false,
    /// Client height to restore when expanding.
    expanded_client_h: i32 = 0,
    hinstance: win32.HINSTANCE,
    /// The window's icons at its monitor's DPI, see setIcons.
    icon_big: ?win32.HICON = null,
    icon_small: ?win32.HICON = null,

    fn create(hwnd: win32.HWND, hinstance: win32.HINSTANCE) void {
        global.window = .{ .hwnd = hwnd, .menu_hwnd = undefined, .hinstance = hinstance, .exclude_from_capture = bb.settings().exclude_from_capture };
        const w = &global.window.?;
        applyCaptureExclusion(hwnd);
        setIcons(w);

        // An owned popup, not a child window: a child is clipped to our window, and menus
        // must extend past it (it may be collapsed to just the controls). Owned, it stays
        // above us, and it never takes activation from us.
        w.menu_hwnd = win32.CreateWindowExW(
            .{ .NOREDIRECTIONBITMAP = 1, .TOOLWINDOW = 1, .NOACTIVATE = 1 },
            menu_class_name,
            null,
            win32.WS_POPUP,
            0,
            0,
            0,
            0,
            hwnd,
            null,
            hinstance,
            null,
        ) orelse win32.panicWin32("CreateWindowEx(menu)", win32.GetLastError());
        applyCaptureExclusion(w.menu_hwnd);

        {
            const dark: win32.BOOL = 1;
            const hr = win32.DwmSetWindowAttribute(hwnd, win32.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, @sizeOf(win32.BOOL));
            if (hr.failed) win32.panicHresult("DwmSetWindowAttribute(dark mode)", hr);
        }
        // Now, so the first frame has it, then on the timer.
        refreshDisk();
        if (0 == win32.SetTimer(hwnd, disk_timer_id, disk_refresh_ms, null)) win32.panicWin32("SetTimer", win32.GetLastError());
        w.frame_clock.start(hwnd);
    }

    /// In WM_DESTROY. The menu popup is already gone.
    fn destroy(w: *Window) void {
        // While the window still exists: their threads post to it.
        w.frame_clock.stop();
        stopMeters(w);
        // Closing while recording keeps what was recorded: the files are finished first.
        if (w.recording != null) stopRecording(w);
        for (w.finishing.items) |r| r.destroy(checkRecordingLeaks);
        w.finishing.deinit(global.gpa);
        for (w.captures.items) |c| c.destroy(global.gpa);
        w.captures.deinit(global.gpa);
        if (w.icon_big) |i| destroyIcon(i);
        if (w.icon_small) |i| destroyIcon(i);
        if (w.text_formats) |*t| t.deinit();
        if (w.menu_target) |*t| t.deinit();
        if (w.main_target) |*t| t.deinit();
        if (w.gpu) |*g| g.deinit();
        global.window = null;
    }

    /// Created on first use, and again when the DPI changes.
    fn textFormats(w: *Window, dpi: u32) *const TextFormats {
        if (w.text_formats) |*cached| {
            if (cached.dpi == dpi) return cached;
            cached.deinit();
            w.text_formats = null;
        }
        w.text_formats = .init(dpi);
        return &w.text_formats.?;
    }

    /// Closes any menu and ends the message loop; main then destroys the window.
    fn quit(w: *Window) void {
        // So the menu popup, destroyed with us, has nothing left to do when it loses the
        // mouse capture.
        _ = bb.closeMenu();
        syncMenu(w);
        win32.PostQuitMessage(0);
    }
};

const max_path = 1024;
const max_text = 512;

const window_class_name = win32.L("BlackBoxMainWindow");
const menu_class_name = win32.L("BlackBoxMenu");
const disk_timer_id = 1;
/// How often free disk space is checked.
const disk_refresh_ms = 1000;

/// Posted by the FrameClock thread on each vertical blank while bb is animating.
const frame_msg = win32.WM_APP + 2;

/// Paces animation to the display: while bb is animating, a thread waits for each vertical
/// blank of the monitor the window is on and posts frame_msg, whose handler paints right away.
/// A posted message, not drawing on that thread, so everything stays on the window's thread;
/// modal loops (moving, resizing) still dispatch posted messages.
const FrameClock = struct {
    hwnd: win32.HWND,
    thread: std.Thread,
    stop_event: win32.HANDLE,
    /// Set when animating turns on, so the thread starts waiting for frames.
    wake_event: win32.HANDLE,
    /// Set on the window's thread, see setAnimating.
    animating: std.atomic.Value(bool) = .init(false),
    /// A frame_msg is in the queue: at most one is, so a busy window skips frames instead
    /// of falling behind.
    pending: std.atomic.Value(bool) = .init(false),

    /// `c` must stay put until stop.
    fn start(c: *FrameClock, hwnd: win32.HWND) void {
        c.* = .{
            .hwnd = hwnd,
            .thread = undefined,
            .stop_event = win32.CreateEventW(null, 1, 0, null) orelse win32.panicWin32("CreateEvent", win32.GetLastError()),
            .wake_event = win32.CreateEventW(null, 0, 0, null) orelse win32.panicWin32("CreateEvent", win32.GetLastError()),
        };
        c.thread = std.Thread.spawn(.{}, run, .{c}) catch |e| std.debug.panic("spawning the frame clock thread failed: {t}", .{e});
    }

    fn stop(c: *FrameClock) void {
        if (0 == win32.SetEvent(c.stop_event)) win32.panicWin32("SetEvent", win32.GetLastError());
        c.thread.join();
        win32.closeHandle(c.wake_event);
        win32.closeHandle(c.stop_event);
    }

    /// On the window's thread.
    fn setAnimating(c: *FrameClock, on: bool) void {
        if (c.animating.swap(on, .acq_rel) == on) return;
        if (on and 0 == win32.SetEvent(c.wake_event)) win32.panicWin32("SetEvent", win32.GetLastError());
    }

    /// The window's frame_msg handler, before painting.
    fn onFrame(c: *FrameClock) void {
        c.pending.store(false, .release);
    }

    fn run(c: *FrameClock) void {
        var guarantee: u32 = wintrace.stack_guarantee;
        if (0 == wintrace.SetThreadStackGuarantee(&guarantee)) win32.panicWin32("SetThreadStackGuarantee", win32.GetLastError());
        var vblank: VBlank = .{};
        defer vblank.deinit();
        while (true) {
            if (!c.animating.load(.acquire)) {
                const handles = [_]?win32.HANDLE{ c.stop_event, c.wake_event };
                switch (@intFromEnum(win32.WaitForMultipleObjects(handles.len, &handles, 0, win32.INFINITE))) {
                    0 => return,
                    1 => continue,
                    else => win32.panicWin32("WaitForMultipleObjects", win32.GetLastError()),
                }
            }
            // Can't also wait on stop_event, so stopping takes up to a frame.
            vblank.wait(c.hwnd);
            switch (@intFromEnum(win32.WaitForSingleObject(c.stop_event, 0))) {
                0 => return,
                @intFromEnum(win32.WAIT_TIMEOUT) => {},
                else => win32.panicWin32("WaitForSingleObject", win32.GetLastError()),
            }
            if (!c.pending.swap(true, .acq_rel)) {
                if (0 == win32.PostMessageW(c.hwnd, frame_msg, 0, 0)) win32.panicWin32("PostMessage(frame)", win32.GetLastError());
            }
        }
    }
};

/// Waits for the vertical blank of the monitor a window is on, following it to other monitors.
/// Not the compositor clock (DCompositionWaitForCompositorClock): with several monitors it
/// ticks for each of them, waking us more often than ours refreshes.
const VBlank = struct {
    factory: ?*win32.IDXGIFactory1 = null,
    /// The monitor `output` shows.
    monitor: ?win32.HMONITOR = null,
    output: ?*win32.IDXGIOutput = null,

    fn deinit(v: *VBlank) void {
        if (v.output) |o| _ = o.IUnknown.Release();
        if (v.factory) |f| _ = f.IUnknown.Release();
    }

    fn wait(v: *VBlank, hwnd: win32.HWND) void {
        const monitor = win32.MonitorFromWindow(hwnd, win32.MONITOR_DEFAULTTONEAREST) orelse
            win32.panicWin32("MonitorFromWindow", win32.GetLastError());
        // Not current once monitors or adapters change.
        const current = if (v.factory) |f| f.IsCurrent() != 0 else false;
        if (!current or monitor != v.monitor) v.findOutput(monitor);
        const hr = v.output.?.WaitForVBlank();
        if (hr.failed) win32.panicHresult("IDXGIOutput.WaitForVBlank", hr);
    }

    /// Any adapter's: a monitor can be on one we don't render with.
    fn findOutput(v: *VBlank, monitor: win32.HMONITOR) void {
        if (v.output) |o| _ = o.IUnknown.Release();
        v.output = null;
        v.monitor = null;
        if (v.factory) |f| if (f.IsCurrent() == 0) {
            _ = f.IUnknown.Release();
            v.factory = null;
        };
        const factory = v.factory orelse blk: {
            var f: *win32.IDXGIFactory1 = undefined;
            const hr = win32.CreateDXGIFactory1(win32.IID_IDXGIFactory1, @ptrCast(&f));
            if (hr.failed) win32.panicHresult("CreateDXGIFactory1", hr);
            v.factory = f;
            break :blk f;
        };
        var adapter_index: u32 = 0;
        while (true) : (adapter_index += 1) {
            var adapter: *win32.IDXGIAdapter1 = undefined;
            {
                const hr = factory.EnumAdapters1(adapter_index, &adapter);
                if (hr == win32.DXGI_ERROR_NOT_FOUND) break;
                if (hr.failed) win32.panicHresult("IDXGIFactory1.EnumAdapters1", hr);
            }
            defer _ = adapter.IUnknown.Release();
            var output_index: u32 = 0;
            while (true) : (output_index += 1) {
                var output: *win32.IDXGIOutput = undefined;
                {
                    const hr = adapter.IDXGIAdapter.EnumOutputs(output_index, &output);
                    if (hr == win32.DXGI_ERROR_NOT_FOUND) break;
                    if (hr.failed) win32.panicHresult("IDXGIAdapter.EnumOutputs", hr);
                }
                var desc: win32.DXGI_OUTPUT_DESC = undefined;
                {
                    const hr = output.GetDesc(&desc);
                    if (hr.failed) win32.panicHresult("IDXGIOutput.GetDesc", hr);
                }
                if (desc.Monitor == monitor) {
                    v.output = output;
                    v.monitor = monitor;
                    return;
                }
                _ = output.IUnknown.Release();
            }
        }
        std.debug.panic("no DXGI output shows the window's monitor ({*})", .{monitor});
    }
};

// Don't return errors from main: std's code that calls main would only log the trace,
// without the message box.
pub fn main() void {
    if (wintrace.SetUnhandledExceptionFilter(&unhandledExceptionFilter) != null)
        @panic("an unhandled exception filter was already installed");

    initCrashPath();

    // Leaves room to report a stack overflow. Only for this thread, other threads that should
    // report an overflow need their own call.
    var guarantee: u32 = wintrace.stack_guarantee;
    if (0 == wintrace.SetThreadStackGuarantee(&guarantee)) win32.panicWin32("SetThreadStackGuarantee", win32.GetLastError());

    // Debug builds check that everything was freed when main ends, and catch bad frees.
    // Shorter-lived operations can get their own to be checked when they end.
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    global.gpa = if (builtin.mode == .debug) debug_allocator.allocator() else std.heap.smp_allocator;
    record.global_gpa = global.gpa;
    defer if (builtin.mode == .debug) checkLeaks(&debug_allocator, "memory leaked");

    // For listing audio devices (wasapi.listDevices). Capture threads initialize their own.
    {
        const hr = win32.CoInitializeEx(null, win32.COINIT_APARTMENTTHREADED);
        if (hr.failed) win32.panicHresult("CoInitializeEx", hr);
    }
    defer win32.CoUninitialize();

    initPaths();
    defer freePaths();
    refreshDisk();
    bb.init(global.gpa);
    defer bb.deinit();

    {
        const hr = win32.DWriteCreateFactory(.SHARED, win32.IID_IDWriteFactory, @ptrCast(&global.dwrite_factory));
        if (hr.failed) win32.panicHresult("DWriteCreateFactory", hr);
    }
    defer _ = global.dwrite_factory.IUnknown.Release();
    global.icon_family = findIconFont();

    const hinstance = win32.GetModuleHandleW(null);
    {
        const wc: win32.WNDCLASSEXW = .{
            .cbSize = @sizeOf(win32.WNDCLASSEXW),
            .style = .{ .VREDRAW = 1, .HREDRAW = 1 },
            .lpfnWndProc = wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            // Set per window at its DPI instead, see setIcons.
            .hIcon = null,
            .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = window_class_name,
            .hIconSm = null,
        };
        if (0 == win32.RegisterClassExW(&wc)) win32.panicWin32("RegisterClassEx", win32.GetLastError());
        var menu_wc = wc;
        menu_wc.lpfnWndProc = menuWndProc;
        menu_wc.lpszClassName = menu_class_name;
        if (0 == win32.RegisterClassExW(&menu_wc)) win32.panicWin32("RegisterClassEx(menu)", win32.GetLastError());
    }

    // No title bar (see WM_NCCALCSIZE/WM_NCHITTEST), but still a regular overlapped window, so
    // Windows keeps managing it: snapping, minimizing, the system menu. Maximizing makes no
    // sense for an overlay.
    const style: win32.WINDOW_STYLE = blk: {
        var s = win32.WS_OVERLAPPEDWINDOW;
        s.TABSTOP = 0; // WS_MAXIMIZEBOX
        break :blk s;
    };
    // No redirection bitmap: the client area is a DirectComposition visual backed by a
    // premultiplied-alpha surface, drawn with Direct2D/DirectWrite (see Gpu/Target). Every
    // pixel carries its own alpha, so bb.zig chooses the opacity of each item.
    const style_ex: win32.WINDOW_EX_STYLE = .{ .NOREDIRECTIONBITMAP = 1 };
    const hwnd = win32.CreateWindowExW(
        style_ex,
        window_class_name,
        win32.L("Black Box"),
        style,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        null,
        null,
        hinstance,
        null,
    ) orelse win32.panicWin32("CreateWindowEx", win32.GetLastError());
    // Only here: nothing else destroys it (see Window.quit), so it exists until the message
    // loop ends, and is gone (its WM_DESTROY done) before anything it uses is cleaned up.
    defer if (0 == win32.DestroyWindow(hwnd)) win32.panicWin32("DestroyWindow", win32.GetLastError());

    {
        // With no non-client area, the window size is the client size. FRAMECHANGED makes
        // Windows apply our WM_NCCALCSIZE, it was created with the default frame.
        const dpi = win32.dpiFromHwnd(hwnd);
        if (0 == win32.SetWindowPos(hwnd, null, 0, 0, scale(448, dpi), scale(496, dpi), .{ .NOMOVE = 1, .NOZORDER = 1, .NOACTIVATE = 1, .DRAWFRAME = 1 })) // DRAWFRAME == SWP_FRAMECHANGED
            win32.panicWin32("SetWindowPos", win32.GetLastError());
    }

    // SHOWDEFAULT: however our launcher asked (a shortcut set to minimized, or no activation).
    _ = win32.ShowWindow(hwnd, win32.SW_SHOWDEFAULT);

    // Be wary of changing this loop from the default. It isn't the only code that pumps this
    // thread's messages: modal loops (MessageBox, window drag/resize) take over dispatching, so
    // anything added here is skipped while one runs. Handle things in the window procedure.
    while (true) {
        var msg: win32.MSG = undefined;
        const result = win32.GetMessageW(&msg, null, 0, 0);
        if (result <= 0) {
            @branchHint(.unlikely);
            if (result < 0) win32.panicWin32("GetMessage", win32.GetLastError());
            break; // WM_QUIT, see Window.quit
        }
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
}

fn wndProc(hwnd: win32.HWND, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    // Messages that need no state; some arrive before WM_CREATE.
    switch (msg) {
        win32.WM_CREATE => {
            const cs: *const win32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
            Window.create(hwnd, cs.hInstance.?);
            return 0;
        },
        win32.WM_NCCALCSIZE => {
            // The client area is the whole window: no title bar or visible frame. We can't
            // be maximized, which would need the client inset to stay on the monitor.
            if (wparam != 0) return 0;
            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        // The whole window is client area, edges included: all mouse input arrives as client
        // messages and we decide what's a resize edge or a drag (see WM_LBUTTONDOWN).
        win32.WM_NCHITTEST => return win32.HTCLIENT,
        else => {},
    }
    const w = if (global.window) |*w| w else return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    switch (msg) {
        win32.WM_DESTROY => {
            w.destroy();
            return 0;
        },
        win32.WM_TIMER => {
            switch (wparam) {
                disk_timer_id => refreshDisk(),
                else => unreachable,
            }
            win32.invalidateHwnd(hwnd);
            return 0;
        },
        frame_msg => {
            w.frame_clock.onFrame();
            // Only when it would look different: the levels move a column at a time, about
            // ten times a second, not at the display's rate. Now, not whenever WM_PAINT's turn
            // comes (it's the lowest priority message).
            if (bb.frameChanged(recordingElapsedMs(w))) {
                win32.invalidateHwnd(hwnd);
                if (0 == win32.UpdateWindow(hwnd)) win32.panicWin32("UpdateWindow", win32.GetLastError());
            }
            if (bb.menuAnimating()) {
                win32.invalidateHwnd(w.menu_hwnd);
                if (0 == win32.UpdateWindow(w.menu_hwnd)) win32.panicWin32("UpdateWindow(menu)", win32.GetLastError());
            }
            return 0;
        },
        wasapi.status_msg => {
            const id: u32 = @intCast(wparam);
            // Gone if its source was removed after it posted.
            for (w.captures.items) |c| if (c.id == id) {
                bb.setSourceStatus(id, c.sourceStatus());
                // Live after recording started (added during it, or slow to start).
                if (w.recording != null and c.status.load(.acquire) == .live) startTrack(w, c);
                win32.invalidateHwnd(hwnd);
            };
            return 0;
        },
        record.failed_msg => {
            const id: u32 = @intCast(wparam);
            // Alive: it posts finished_msg (after this) before it's destroyed.
            const r: *record.Recording = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const f = r.failure(id) orelse return 0;
            // As much as fits where it's shown.
            const message: bb.Message = .init("{f}", .{f.problem});
            if (id != 0) {
                bb.setSourceRecordError(id, message);
            } else if (f.stops and r == w.recording) {
                // The recording being made can't go on: it stops.
                bb.recordingFailed(message);
            } else {
                // A problem that stops nothing, or from a recording being finished: shown.
                bb.recordingProblem(message);
            }
            syncWindow(w);
            return 0;
        },
        record.finished_msg => {
            const r: *record.Recording = @ptrFromInt(@as(usize, @bitCast(lparam)));
            for (w.finishing.items, 0..) |f, i| if (f == r) {
                _ = w.finishing.swapRemove(i);
                r.destroy(checkRecordingLeaks);
                return 0;
            };
            unreachable;
        },
        win32.WM_MOUSEMOVE => {
            if (!w.tracking_mouse) {
                var tme: win32.TRACKMOUSEEVENT = .{
                    .cbSize = @sizeOf(win32.TRACKMOUSEEVENT),
                    .dwFlags = .{ .LEAVE = 1 },
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                if (0 == win32.TrackMouseEvent(&tme)) win32.panicWin32("TrackMouseEvent", win32.GetLastError());
                w.tracking_mouse = true;
            }
            const pt = win32.pointFromLparam(lparam);
            if (bb.onMouseMove(pt.x, pt.y)) win32.invalidateHwnd(hwnd);
            return 0;
        },
        win32.WM_MOUSELEAVE => {
            w.tracking_mouse = false;
            if (bb.onMouseLeave()) win32.invalidateHwnd(hwnd);
            return 0;
        },
        win32.WM_LBUTTONDOWN => {
            const pt = win32.pointFromLparam(lparam);
            // Resize edges and empty space hand the press to Windows' own resize/move loop,
            // as if it were on a frame or title bar we don't draw.
            const system_hit: ?u32 = resizeEdge(w, pt) orelse if (bb.isDragArea(pt.x, pt.y)) win32.HTCAPTION else null;
            if (system_hit) |hit| {
                var screen_pt = pt;
                if (0 == win32.ClientToScreen(hwnd, &screen_pt)) win32.panicWin32("ClientToScreen", win32.GetLastError());
                // Return right away: the window may be gone once the loop ends.
                return win32.DefWindowProcW(hwnd, win32.WM_NCLBUTTONDOWN, hit, lparamFromPoint(screen_pt));
            }
            if (bb.onMouseDown(pt.x, pt.y)) syncWindow(w);
            return 0;
        },
        win32.WM_LBUTTONUP => {
            const pt = win32.pointFromLparam(lparam);
            if (bb.onMouseUp(pt.x, pt.y)) syncWindow(w);
            return 0;
        },
        win32.WM_KEYDOWN => {
            // We keep the keyboard while a menu is open, it never activates.
            if (wparam == @intFromEnum(win32.VK_ESCAPE)) {
                if (bb.closeMenu()) syncWindow(w);
            } else if (wparam == @intFromEnum(win32.VK_SPACE) or wparam == @intFromEnum(win32.VK_RETURN)) {
                if (bb.onKeyActivate()) syncWindow(w);
            }
            return 0;
        },
        win32.WM_SETCURSOR => {
            if (win32.loword(lparam) != win32.HTCLIENT) return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            var pt: win32.POINT = undefined;
            if (0 == win32.GetCursorPos(&pt)) win32.panicWin32("GetCursorPos", win32.GetLastError());
            if (0 == win32.ScreenToClient(hwnd, &pt)) win32.panicWin32("ScreenToClient", win32.GetLastError());
            const cursor: [*:0]align(1) const u16 = if (resizeEdge(w, pt)) |edge| switch (edge) {
                win32.HTLEFT, win32.HTRIGHT => win32.IDC_SIZEWE,
                win32.HTTOP, win32.HTBOTTOM => win32.IDC_SIZENS,
                win32.HTTOPLEFT, win32.HTBOTTOMRIGHT => win32.IDC_SIZENWSE,
                win32.HTTOPRIGHT, win32.HTBOTTOMLEFT => win32.IDC_SIZENESW,
                else => unreachable,
            } else win32.IDC_ARROW;
            _ = win32.SetCursor(win32.LoadCursorW(null, cursor));
            return 1;
        },
        win32.WM_GETMINMAXINFO => {
            // Collapsed, the height is fixed to just the controls; the width stays resizable.
            if (w.collapsed) {
                const info: *win32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
                const h = nonClientHeight(hwnd) + bb.collapsedHeight(win32.dpiFromHwnd(hwnd));
                info.ptMinTrackSize.y = h;
                info.ptMaxTrackSize.y = h;
            }
            return 0;
        },
        win32.WM_DPICHANGED => {
            const rect: *const win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (0 == win32.SetWindowPos(hwnd, null, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, .{ .NOZORDER = 1, .NOACTIVATE = 1 }))
                win32.panicWin32("SetWindowPos", win32.GetLastError());
            setIcons(w);
            win32.invalidateHwnd(hwnd);
            return 0;
        },
        win32.WM_PAINT => {
            paint(w, .main);
            return 0;
        },
        // Alt+F4, the taskbar's close. Not DefWindowProc, which would destroy the window:
        // main does that.
        win32.WM_CLOSE => {
            w.quit();
            return 0;
        },
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// The popup showing bb's open menu. Like a native menu (and Tuple's popups), it holds the
/// mouse capture while shown, so every click comes here, even outside it. Losing the capture,
/// to a click outside or anything else (Alt+Tab, another window taking it), is the one way it
/// closes without a choice, see WM_CAPTURECHANGED. It lives within the main window's
/// lifetime (it's created in its WM_CREATE and destroyed before its WM_DESTROY), so its
/// messages can use the main window's state, apart from those during its own creation.
fn menuWndProc(hwnd: win32.HWND, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    switch (msg) {
        win32.WM_MOUSEMOVE => {
            const pt = win32.pointFromLparam(lparam);
            if (bb.onMenuMouseMove(pt.x, pt.y)) win32.invalidateHwnd(hwnd);
            return 0;
        },
        win32.WM_LBUTTONDOWN => {
            const pt = win32.pointFromLparam(lparam);
            const size = win32.getClientSize(hwnd);
            if (pt.x < 0 or pt.y < 0 or pt.x >= size.cx or pt.y >= size.cy) {
                // Outside: just close the menu (the click isn't passed on).
                if (0 == win32.ReleaseCapture()) win32.panicWin32("ReleaseCapture", win32.GetLastError());
                return 0;
            }
            bb.onMenuMouseDown(pt.x, pt.y);
            return 0;
        },
        win32.WM_LBUTTONUP => {
            const pt = win32.pointFromLparam(lparam);
            if (bb.onMenuMouseUp(pt.x, pt.y)) syncWindow(&global.window.?);
            return 0;
        },
        win32.WM_CAPTURECHANGED => {
            const w = &global.window.?;
            if (w.menu_shown != null) {
                _ = bb.closeMenu();
                syncWindow(w);
            }
            return 0;
        },
        win32.WM_MOUSEACTIVATE => return win32.MA_NOACTIVATE,
        // Alt+F4 can't close it, it only hides when the menu closes.
        win32.WM_CLOSE => return 0,
        win32.WM_PAINT => {
            paint(&global.window.?, .menu);
            return 0;
        },
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// Starts or stops recording to match bb. A stopped recording's files are finished in the
/// background; it waits in Window.finishing until record.finished_msg.
fn syncRecording(w: *Window) void {
    if (bb.isRecording() and w.recording == null) {
        startRecording(w);
    } else if (!bb.isRecording() and w.recording != null) {
        stopRecording(w);
    }
}

fn startRecording(w: *Window) void {
    w.recording = switch (record.Recording.create(w.hwnd, global.rec_dir)) {
        .ok => |r| r,
        .failed => |m| return bb.recordingFailed(m),
    };
    // Those not live yet start when they are, see wasapi.status_msg.
    for (w.captures.items) |c| {
        if (c.status.load(.acquire) == .live) startTrack(w, c);
    }
}

/// Records a live capture's source, once per recording.
fn startTrack(w: *Window, c: *wasapi.Capture) void {
    const r = w.recording.?;
    if (c.recorder != null) return;
    const src = for (bb.sources()) |*src| {
        if (src.id == c.id) break src;
    } else return; // removed
    const tw = r.addTrack(c.id, .{
        .input = c.input,
        .device_id = if (src.device) |d| d.id else "",
        .device_name = src.name(),
        .device_format = if (src.device) |d| d.format else null,
        .raw = c.raw,
    }) orelse return;
    c.attachRecorder(tw);
}

fn stopTrack(c: *wasapi.Capture) void {
    if (c.detachRecorder()) |tw| tw.close();
}

fn stopRecording(w: *Window) void {
    const r = w.recording.?;
    for (w.captures.items) |c| stopTrack(c);
    r.stop();
    w.finishing.append(global.gpa, r) catch @panic("out of memory");
    w.recording = null;
}

fn checkRecordingLeaks(debug_allocator: *std.heap.DebugAllocator(.{})) void {
    checkLeaks(debug_allocator, "the recording leaked memory");
}

/// Starts and stops captures to match bb's sources.
fn syncCaptures(w: *Window) void {
    // Stop captures whose source is gone.
    var i: usize = 0;
    while (i < w.captures.items.len) {
        const c = w.captures.items[i];
        const exists = for (bb.sources()) |s| {
            if (s.id == c.id) break true;
        } else false;
        if (exists) {
            i += 1;
        } else {
            stopTrack(c);
            c.destroy(global.gpa);
            _ = w.captures.swapRemove(i);
        }
    }
    // Start captures for new sources. A failed capture stays in the list (stopped), so it
    // isn't retried until its source is removed and added again.
    for (bb.sources()) |s| {
        const has_capture = for (w.captures.items) |c| {
            if (c.id == s.id) break true;
        } else false;
        if (has_capture) continue;
        switch (s.kind) {
            .microphone, .system_audio => {
                w.captures.ensureUnusedCapacity(global.gpa, 1) catch @panic("out of memory");
                const endpoint: wasapi.Endpoint = if (s.kind == .microphone) .microphone else .output;
                const c = wasapi.Capture.create(global.gpa, s.id, endpoint, s.device.?.id, w.hwnd);
                w.captures.appendAssumeCapacity(c);
                bb.setSourceMeter(s.id, &c.meter);
            },
            .screen, .webcam => unreachable, // can't be added yet, see bb.SourceKind.todo
        }
    }
}

/// Gives the window the app's icon at the sizes Windows wants at its monitor's DPI: big for
/// the taskbar and Alt+Tab, small for the system menu. On creation, and when the DPI changes
/// (class icons can't follow: they'd be at the system DPI, scaled blurry elsewhere). Explorer
/// takes the icon from the exe itself, picking its own size.
fn setIcons(w: *Window) void {
    const dpi = win32.dpiFromHwnd(w.hwnd);
    const big = loadIcon(w.hinstance, win32.GetSystemMetricsForDpi(win32.SM_CXICON, dpi));
    const small = loadIcon(w.hinstance, win32.GetSystemMetricsForDpi(win32.SM_CXSMICON, dpi));
    _ = win32.SendMessageW(w.hwnd, win32.WM_SETICON, win32.ICON_BIG, @bitCast(@intFromPtr(big)));
    _ = win32.SendMessageW(w.hwnd, win32.WM_SETICON, win32.ICON_SMALL, @bitCast(@intFromPtr(small)));
    // The window holds the new ones now.
    if (w.icon_big) |i| destroyIcon(i);
    if (w.icon_small) |i| destroyIcon(i);
    w.icon_big = big;
    w.icon_small = small;
}

/// The app's icon (resource 1, src/win32.rc) at `size` pixels square, from the .ico's best
/// size for it. Ours: freed with destroyIcon.
fn loadIcon(hinstance: win32.HINSTANCE, size: i32) win32.HICON {
    const h = win32.LoadImageW(hinstance, @ptrFromInt(1), .ICON, size, size, .{}) orelse
        win32.panicWin32("LoadImage(icon)", win32.GetLastError());
    return @ptrCast(h);
}

fn destroyIcon(icon: win32.HICON) void {
    if (0 == win32.DestroyIcon(icon)) win32.panicWin32("DestroyIcon", win32.GetLastError());
}

/// Stops the open menu's device meters, if any: everything they held goes.
fn stopMeters(w: *Window) void {
    const m = w.meters orelse return;
    // bb lets go first (closeMenu already has, if the menu closed).
    bb.setDeviceLevels(null);
    m.stop();
    w.meters = null;
}

/// Shows, moves or hides the menu popup to match bb's open menu.
fn syncMenu(w: *Window) void {
    const menu = bb.openMenu() orelse {
        if (w.menu_shown == null) return;
        // Before releasing: WM_CAPTURECHANGED checks it, the menu is already closed.
        w.menu_shown = null;
        if (win32.GetCapture() == w.menu_hwnd) {
            if (0 == win32.ReleaseCapture()) win32.panicWin32("ReleaseCapture", win32.GetLastError());
        }
        _ = win32.ShowWindow(w.menu_hwnd, win32.SW_HIDE);
        // After hiding, so a slow device can't hold the menu on screen.
        stopMeters(w);
        return;
    };
    if (w.menu_shown) |shown| if (std.meta.eql(shown, menu)) return;
    // A different menu: the last one's levels, if any, go.
    stopMeters(w);
    w.menu_shown = menu;
    // Live levels while choosing a device (see DeviceMeters for what metering a microphone
    // involves).
    if (menu == .devices) {
        const endpoint: wasapi.Endpoint = switch (menu.devices) {
            .microphone => .microphone,
            .system_audio => .output,
            .screen, .webcam => unreachable, // no devices yet, see bb.SourceKind.hasDevice
        };
        const m = wasapi.DeviceMeters.start(global.gpa, endpoint, bb.listedDevices());
        w.meters = m;
        bb.setDeviceLevels(m.levels);
    }

    // Laid out at our window's DPI, see paint.
    const dpi = win32.dpiFromHwnd(w.hwnd);
    const r = bb.menuRect(dpi, TextMeasure{ .formats = w.textFormats(dpi) });
    var anchor: win32.POINT = .{ .x = r.left, .y = r.top };
    if (0 == win32.ClientToScreen(w.hwnd, &anchor)) win32.panicWin32("ClientToScreen", win32.GetLastError());
    const size: win32.SIZE = .{ .cx = r.right - r.left, .cy = r.bottom - r.top };
    // Moves it back onto the monitor's work area if it would hang off.
    var placed: win32.RECT = undefined;
    if (0 == win32.CalculatePopupWindowPosition(&anchor, &size, @bitCast(win32.TPM_WORKAREA), null, &placed))
        win32.panicWin32("CalculatePopupWindowPosition", win32.GetLastError());
    if (0 == win32.SetWindowPos(w.menu_hwnd, null, placed.left, placed.top, size.cx, size.cy, .{ .SHOWWINDOW = 1, .NOACTIVATE = 1 }))
        win32.panicWin32("SetWindowPos(menu)", win32.GetLastError());
    win32.invalidateHwnd(w.menu_hwnd);
    // Only if it doesn't have it already, from a menu it showed before this one (picking a
    // device after Add): setting it again, while we're in the background at least, loses it.
    if (win32.GetCapture() == w.menu_hwnd) return;
    _ = win32.SetCapture(w.menu_hwnd);
    const capture = win32.GetCapture();
    if (capture != w.menu_hwnd) std.debug.panic("the menu ({*}) didn't get the mouse capture for menu {t}, {?*} has it", .{ w.menu_hwnd, menu, capture });
}

/// Stands in for the frame we don't draw: the resize edge (an HT* value) under `pt`, if any.
fn resizeEdge(w: *const Window, pt: win32.POINT) ?u32 {
    const size = win32.getClientSize(w.hwnd);
    const border = scale(6, win32.dpiFromHwnd(w.hwnd));
    const left = pt.x < border;
    const right = pt.x >= size.cx - border;
    // Collapsed, the height is fixed.
    const top = !w.collapsed and pt.y < border;
    const bottom = !w.collapsed and pt.y >= size.cy - border;
    if (top and left) return win32.HTTOPLEFT;
    if (top and right) return win32.HTTOPRIGHT;
    if (bottom and left) return win32.HTBOTTOMLEFT;
    if (bottom and right) return win32.HTBOTTOMRIGHT;
    if (left) return win32.HTLEFT;
    if (right) return win32.HTRIGHT;
    if (top) return win32.HTTOP;
    if (bottom) return win32.HTBOTTOM;
    return null;
}

/// Applies bb's window state (quit, device lists, menu, captures, minimize, always on top,
/// capture exclusion, collapsed) when it's changed, and repaints. Call after any bb input that changed something.
fn syncWindow(w: *Window) void {
    if (bb.quitRequested()) return w.quit();
    const hwnd = w.hwnd;
    win32.invalidateHwnd(hwnd);
    // Before syncMenu: the list is the menu.
    if (bb.takeDeviceListRequest()) |kind| switch (kind) {
        .microphone => wasapi.listDevices(global.gpa, .microphone),
        .system_audio => wasapi.listDevices(global.gpa, .output),
        .screen, .webcam => unreachable, // no devices yet, see bb.SourceKind.hasDevice
    };
    syncMenu(w);
    syncCaptures(w);
    syncRecording(w);
    if (bb.takeMinimize()) _ = win32.ShowWindow(hwnd, win32.SW_MINIMIZE);
    const always_on_top = bb.settings().always_on_top;
    if (always_on_top != w.always_on_top) {
        w.always_on_top = always_on_top;
        const after = if (always_on_top) win32.HWND_TOPMOST else win32.HWND_NOTOPMOST;
        if (0 == win32.SetWindowPos(hwnd, after, 0, 0, 0, 0, .{ .NOMOVE = 1, .NOSIZE = 1, .NOACTIVATE = 1 }))
            win32.panicWin32("SetWindowPos(topmost)", win32.GetLastError());
    }
    const exclude_from_capture = bb.settings().exclude_from_capture;
    if (exclude_from_capture != w.exclude_from_capture) {
        w.exclude_from_capture = exclude_from_capture;
        applyCaptureExclusion(hwnd);
        applyCaptureExclusion(w.menu_hwnd);
        // Whether there's a warning about it changes the collapsed height.
        if (w.collapsed) {
            var rect: win32.RECT = undefined;
            if (0 == win32.GetWindowRect(hwnd, &rect)) win32.panicWin32("GetWindowRect", win32.GetLastError());
            if (0 == win32.SetWindowPos(hwnd, null, 0, 0, rect.right - rect.left, nonClientHeight(hwnd) + bb.collapsedHeight(win32.dpiFromHwnd(hwnd)), .{ .NOMOVE = 1, .NOZORDER = 1, .NOACTIVATE = 1 }))
                win32.panicWin32("SetWindowPos(collapsed)", win32.GetLastError());
        }
    }
    const collapsed = bb.settings().collapsed;
    if (collapsed != w.collapsed) {
        const client_h = win32.getClientSize(hwnd).cy;
        // Before resizing: WM_GETMINMAXINFO, sent during the resize, checks it.
        w.collapsed = collapsed;
        const new_client_h = if (collapsed) blk: {
            w.expanded_client_h = client_h;
            break :blk bb.collapsedHeight(win32.dpiFromHwnd(hwnd));
        } else w.expanded_client_h;
        var rect: win32.RECT = undefined;
        if (0 == win32.GetWindowRect(hwnd, &rect)) win32.panicWin32("GetWindowRect", win32.GetLastError());
        if (0 == win32.SetWindowPos(hwnd, null, 0, 0, rect.right - rect.left, nonClientHeight(hwnd) + new_client_h, .{ .NOMOVE = 1, .NOZORDER = 1, .NOACTIVATE = 1 }))
            win32.panicWin32("SetWindowPos(collapse)", win32.GetLastError());
    }
}

/// The inverse of win32.pointFromLparam.
fn lparamFromPoint(pt: win32.POINT) win32.LPARAM {
    const x: u16 = @bitCast(@as(i16, @intCast(pt.x)));
    const y: u16 = @bitCast(@as(i16, @intCast(pt.y)));
    return @bitCast(@as(usize, x) | (@as(usize, y) << 16));
}

fn nonClientHeight(hwnd: win32.HWND) i32 {
    var rect: win32.RECT = undefined;
    if (0 == win32.GetWindowRect(hwnd, &rect)) win32.panicWin32("GetWindowRect", win32.GetLastError());
    return (rect.bottom - rect.top) - win32.getClientSize(hwnd).cy;
}

/// Applies bb's exclude_from_capture setting to a window of ours. Call again when it changes.
fn applyCaptureExclusion(hwnd: win32.HWND) void {
    const affinity: win32.WINDOW_DISPLAY_AFFINITY = if (bb.settings().exclude_from_capture) .EXCLUDEFROMCAPTURE else .NONE;
    if (0 != win32.SetWindowDisplayAffinity(hwnd, affinity)) return bb.setCaptureExclusion(.ok);
    bb.setCaptureExclusion(switch (win32.GetLastError()) {
        // What Windows versions before 10 2004 return for EXCLUDEFROMCAPTURE.
        .ERROR_NOT_ENOUGH_MEMORY => .unsupported,
        else => |e| .{ .failed = @intFromEnum(e) },
    });
}

// ---------------------------------------------------------------------------
// Storage facts
// ---------------------------------------------------------------------------

/// The recordings folder and the disk facts' strings, allocated with global.gpa: free them
/// with freePaths.
fn initPaths() void {
    const gpa = global.gpa;
    const app_dir = knownFolderPath(gpa, &win32.FOLDERID_LocalAppData, &.{win32.L("\\" ++ app_name)});
    defer gpa.free(app_dir);
    createDir(app_dir);
    global.rec_dir = std.mem.concatWithSentinel(gpa, u16, &.{ app_dir, win32.L("\\rec") }, 0) catch @panic("out of memory");
    createDir(global.rec_dir);
    global.disk.out_dir = std.unicode.wtf16LeToWtf8Alloc(gpa, global.rec_dir) catch @panic("out of memory");

    var root_buf: [max_path]u16 = undefined;
    if (0 == win32.GetVolumePathNameW(global.rec_dir, @ptrCast(&root_buf), root_buf.len))
        win32.panicWin32("GetVolumePathName", win32.GetLastError());
    const root = std.mem.sliceTo(&root_buf, 0);

    var windir_buf: [max_path]u16 = undefined;
    const windir_len = win32.GetWindowsDirectoryW(@ptrCast(&windir_buf), windir_buf.len);
    if (windir_len == 0 or windir_len >= windir_buf.len) win32.panicWin32("GetWindowsDirectory", win32.GetLastError());
    windir_buf[windir_len] = 0;
    var sys_root_buf: [max_path]u16 = undefined;
    if (0 == win32.GetVolumePathNameW(windir_buf[0..windir_len :0], @ptrCast(&sys_root_buf), sys_root_buf.len))
        win32.panicWin32("GetVolumePathName(windir)", win32.GetLastError());
    global.disk.is_system = std.ascii.eqlIgnoreCase(
        std.mem.sliceAsBytes(std.mem.sliceTo(&sys_root_buf, 0)),
        std.mem.sliceAsBytes(root),
    );
}

fn freePaths() void {
    const gpa = global.gpa;
    gpa.free(global.disk.out_dir);
    gpa.free(global.rec_dir);
}

/// A known folder's path with `suffixes` appended, allocated.
fn knownFolderPath(gpa: std.mem.Allocator, id: *const win32.Guid, suffixes: []const []const u16) [:0]u16 {
    var folder: ?[*:0]u16 = null;
    {
        const hr = win32.SHGetKnownFolderPath(id, .DEFAULT, null, &folder);
        if (hr.failed) win32.panicHresult("SHGetKnownFolderPath", hr);
    }
    defer win32.CoTaskMemFree(folder);
    var parts: [4][]const u16 = undefined;
    parts[0] = std.mem.span(folder.?);
    for (suffixes, parts[1..][0..suffixes.len]) |suffix, *part| part.* = suffix;
    return std.mem.concatWithSentinel(gpa, u16, parts[0 .. 1 + suffixes.len], 0) catch @panic("out of memory");
}

fn refreshDisk() void {
    var avail: win32.ULARGE_INTEGER = undefined;
    var total: win32.ULARGE_INTEGER = undefined;
    if (0 == win32.GetDiskFreeSpaceExW(global.rec_dir, &avail, &total, null))
        win32.panicWin32("GetDiskFreeSpaceEx", win32.GetLastError());
    global.disk.free = avail.QuadPart;
    global.disk.total = total.QuadPart;
    bb.setDisk(global.disk);
}

// ---------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------

fn recordingElapsedMs(w: *const Window) ?u64 {
    const r = w.recording orelse return null;
    return (record.qpc100ns() - r.start_qpc) / 10_000;
}

fn paint(w: *Window, comptime which: enum { main, menu }) void {
    const hwnd = switch (which) {
        .main => w.hwnd,
        .menu => w.menu_hwnd,
    };
    _, const ps = win32.beginPaint(hwnd);
    defer win32.endPaint(hwnd, &ps);
    // Debug info. A capture's recorder is the window thread's to read, see attachRecorder.
    for (w.captures.items) |c| bb.setSourceBuffer(c.id, if (c.recorder) |tw| tw.buffer() else null);

    const size = win32.getClientSize(hwnd);
    // The menu is laid out at our window's DPI (bb.menuRect), even if it hangs onto a
    // monitor with another.
    const dpi = win32.dpiFromHwnd(w.hwnd);

    const gpu: *Gpu = if (w.gpu) |*g| g else blk: {
        w.gpu = .init();
        break :blk &w.gpu.?;
    };
    const target_slot = switch (which) {
        .main => &w.main_target,
        .menu => &w.menu_target,
    };
    const target: *Target = if (target_slot.*) |*t| t else blk: {
        target_slot.* = .init(gpu, hwnd);
        break :blk &target_slot.*.?;
    };
    const text_formats = w.textFormats(dpi);

    const dc = target.beginFrame(gpu, size);
    const painter: Painter = .{ .target = &dc.ID2D1RenderTarget, .brush = gpu.brush, .text_formats = text_formats };
    switch (which) {
        .main => {
            bb.setRecordingElapsed(recordingElapsedMs(w));
            bb.paint(&painter, size.cx, size.cy, dpi);
            // Anything that changes it (a source going live, collapsing) repaints.
            w.frame_clock.setAnimating(bb.animating());
        },
        .menu => bb.paintMenu(&painter, size.cx, dpi),
    }
    target.endFrame(gpu) catch |err| switch (err) {
        error.RecreateTarget => {
            // Every window's target belongs to the lost device.
            for ([_]*?Target{ &w.main_target, &w.menu_target }) |slot| if (slot.*) |*t| {
                t.deinit();
                slot.* = null;
            };
            gpu.deinit();
            w.gpu = null;
            win32.invalidateHwnd(w.hwnd);
            win32.invalidateHwnd(w.menu_hwnd);
        },
    };
}

/// Measures text for bb's layout, as Painter.text would draw it.
const TextMeasure = struct {
    formats: *const TextFormats,

    /// In pixels, rounded up.
    pub fn width(m: TextMeasure, utf8: []const u8, font: bb.Font) i32 {
        var buf: [max_text]u16 = undefined;
        const wide = toWide(utf8, &buf);
        var layout: *win32.IDWriteTextLayout = undefined;
        {
            const hr = global.dwrite_factory.CreateTextLayout(@ptrCast(wide.ptr), @intCast(wide.len), m.formats.formats.get(font), std.math.floatMax(f32), std.math.floatMax(f32), @ptrCast(&layout));
            if (hr.failed) win32.panicHresult("CreateTextLayout", hr);
        }
        defer _ = layout.IUnknown.Release();
        // The layout has the format's alignment, which Painter.text changes to whatever it
        // drew last. Centered or trailing in an unbounded width, the text sits near
        // floatMax, where its width is lost to rounding (it measured 0). Leading keeps it at
        // 0. Set on the layout only: the format is shared.
        {
            const hr = layout.IDWriteTextFormat.SetTextAlignment(.LEADING);
            if (hr.failed) win32.panicHresult("IDWriteTextLayout.SetTextAlignment", hr);
        }
        var metrics: win32.DWRITE_TEXT_METRICS = undefined;
        {
            const hr = layout.GetMetrics(&metrics);
            if (hr.failed) win32.panicHresult("IDWriteTextLayout.GetMetrics", hr);
        }
        return @intFromFloat(@ceil(metrics.widthIncludingTrailingWhitespace));
    }
};

const TextFormats = struct {
    dpi: u32,
    formats: std.EnumArray(bb.Font, *win32.IDWriteTextFormat),
    /// How far up to move badge text so its digits, not its line box, are centered, see
    /// digitCenterShift.
    badge_shift: f32,

    fn init(dpi: u32) TextFormats {
        var formats: std.EnumArray(bb.Font, *win32.IDWriteTextFormat) = undefined;
        for (std.enums.values(bb.Font)) |font| formats.set(font, createTextFormat(dpi, font));
        return .{ .dpi = dpi, .formats = formats, .badge_shift = digitCenterShift(formats.get(.badge)) };
    }
    fn deinit(t: *TextFormats) void {
        for (t.formats.values) |f| _ = f.IUnknown.Release();
        t.* = undefined;
    }
};

/// With paragraph alignment CENTER, DirectWrite centers the line box: ascent above the
/// baseline, descent below. Digits only rise to the cap height, so their middle is lower than
/// the line box's by (ascent - descent - cap height) / 2. This is that, in pixels.
fn digitCenterShift(format: *win32.IDWriteTextFormat) f32 {
    const m = fontMetrics(format);
    const ascent: f32 = @floatFromInt(m.ascent);
    const descent: f32 = @floatFromInt(m.descent);
    const cap: f32 = @floatFromInt(m.capHeight);
    return (ascent - descent - cap) / 2 * format.GetFontSize() / @as(f32, @floatFromInt(m.designUnitsPerEm));
}

/// The metrics of the font a text format uses: its family's best match for the format's
/// weight, stretch and style, as DirectWrite would pick.
fn fontMetrics(format: *win32.IDWriteTextFormat) win32.DWRITE_FONT_METRICS {
    var collection: *win32.IDWriteFontCollection = undefined;
    {
        const hr = format.GetFontCollection(&collection);
        if (hr.failed) win32.panicHresult("IDWriteTextFormat.GetFontCollection", hr);
    }
    defer _ = collection.IUnknown.Release();
    var name_buf: [128:0]u16 = undefined;
    const name_len = format.GetFontFamilyNameLength();
    if (name_len >= name_buf.len) std.debug.panic("font family name is {d} characters, longer than {d}", .{ name_len, name_buf.len - 1 });
    {
        const hr = format.GetFontFamilyName(&name_buf, name_buf.len);
        if (hr.failed) win32.panicHresult("IDWriteTextFormat.GetFontFamilyName", hr);
    }
    var index: u32 = undefined;
    var exists: win32.BOOL = undefined;
    {
        const hr = collection.FindFamilyName(&name_buf, &index, &exists);
        if (hr.failed) win32.panicHresult("IDWriteFontCollection.FindFamilyName", hr);
    }
    if (exists == 0) std.debug.panic("font family {f} not found", .{std.unicode.fmtUtf16Le(name_buf[0..name_len])});
    var family: *win32.IDWriteFontFamily = undefined;
    {
        const hr = collection.GetFontFamily(index, &family);
        if (hr.failed) win32.panicHresult("IDWriteFontCollection.GetFontFamily", hr);
    }
    defer _ = family.IUnknown.Release();
    var font: *win32.IDWriteFont = undefined;
    {
        const hr = family.GetFirstMatchingFont(format.GetFontWeight(), format.GetFontStretch(), format.GetFontStyle(), &font);
        if (hr.failed) win32.panicHresult("IDWriteFontFamily.GetFirstMatchingFont", hr);
    }
    defer _ = font.IUnknown.Release();
    var metrics: win32.DWRITE_FONT_METRICS = undefined;
    font.GetMetrics(&metrics);
    return metrics;
}

fn createTextFormat(dpi: u32, font: bb.Font) *win32.IDWriteTextFormat {
    var format: *win32.IDWriteTextFormat = undefined;
    {
        const size_px: f32 = @as(f32, @floatFromInt(font.px())) * @as(f32, @floatFromInt(dpi)) / 96.0;
        const hr = global.dwrite_factory.CreateTextFormat(
            switch (font) {
                .title, .normal, .small, .badge => win32.L("Segoe UI"),
                .icon, .icon_small => global.icon_family,
            },
            null,
            switch (font) {
                .title, .badge => win32.DWRITE_FONT_WEIGHT_BOLD,
                .normal, .small, .icon, .icon_small => win32.DWRITE_FONT_WEIGHT_NORMAL,
            },
            win32.DWRITE_FONT_STYLE_NORMAL,
            win32.DWRITE_FONT_STRETCH_NORMAL,
            size_px,
            win32.L(""),
            &format,
        );
        if (hr.failed) win32.panicHresult("CreateTextFormat", hr);
    }
    {
        const hr = format.SetParagraphAlignment(.CENTER);
        if (hr.failed) win32.panicHresult("SetParagraphAlignment", hr);
    }
    {
        const hr = format.SetWordWrapping(.NO_WRAP);
        if (hr.failed) win32.panicHresult("SetWordWrapping", hr);
    }
    {
        var ellipsis: *win32.IDWriteInlineObject = undefined;
        const create_hr = global.dwrite_factory.CreateEllipsisTrimmingSign(format, &ellipsis);
        if (create_hr.failed) win32.panicHresult("CreateEllipsisTrimmingSign", create_hr);
        defer _ = ellipsis.IUnknown.Release();
        const trimming: win32.DWRITE_TRIMMING = .{ .granularity = .CHARACTER, .delimiter = 0, .delimiterCount = 0 };
        const hr = format.SetTrimming(&trimming, ellipsis);
        if (hr.failed) win32.panicHresult("SetTrimming", hr);
    }
    return format;
}

/// What bb.paint draws with.
pub const Painter = struct {
    target: *const win32.ID2D1RenderTarget,
    brush: *win32.ID2D1SolidColorBrush,
    text_formats: *const TextFormats,

    fn setColor(p: *const Painter, c: bb.Color) *win32.ID2D1Brush {
        const color = colorF(c);
        p.brush.SetColor(&color);
        return &p.brush.ID2D1Brush;
    }

    pub fn clear(p: *const Painter, c: bb.Color) void {
        p.target.Clear(&colorF(c));
    }

    pub fn fill(p: *const Painter, r: bb.Rect, c: bb.Color) void {
        p.target.FillRectangle(&rectF(r), p.setColor(c));
    }

    /// The ellipse inscribed in `r`.
    pub fn ellipse(p: *const Painter, r: bb.Rect, c: bb.Color) void {
        const f = rectF(r);
        const e: win32.D2D1_ELLIPSE = .{
            .point = .{ .x = (f.left + f.right) / 2, .y = (f.top + f.bottom) / 2 },
            .radiusX = (f.right - f.left) / 2,
            .radiusY = (f.bottom - f.top) / 2,
        };
        p.target.FillEllipse(&e, p.setColor(c));
    }

    /// Columns a pixel wide from `left`, column i filled from upper[i] down to lower[i], as one
    /// shape (a path along the tops, back along the bottoms) filled once with `gradient`.
    pub fn band(p: *const Painter, left: i32, upper: []const i32, lower: []const i32, gradient: bb.Gradient) void {
        std.debug.assert(upper.len == lower.len and upper.len <= bb.band_columns);
        if (upper.len == 0) return;
        var factory: *win32.ID2D1Factory = undefined;
        p.target.ID2D1Resource.GetFactory(&factory);
        defer _ = factory.IUnknown.Release();
        var geometry: *win32.ID2D1PathGeometry = undefined;
        {
            const hr = factory.CreatePathGeometry(&geometry);
            if (hr.failed) win32.panicHresult("CreatePathGeometry", hr);
        }
        defer _ = geometry.IUnknown.Release();
        {
            var sink: *win32.ID2D1GeometrySink = undefined;
            {
                const hr = geometry.Open(&sink);
                if (hr.failed) win32.panicHresult("ID2D1PathGeometry.Open", hr);
            }
            defer _ = sink.IUnknown.Release();
            const s = &sink.ID2D1SimplifiedGeometrySink;
            // Along the tops left to right, a step per column, then back along the bottoms.
            var points: [4 * bb.band_columns]win32.D2D_POINT_2F = undefined;
            var n: usize = 0;
            const x0: f32 = @floatFromInt(left);
            for (upper, 0..) |y, i| {
                const x = x0 + @as(f32, @floatFromInt(i));
                points[n] = .{ .x = x, .y = @floatFromInt(y) };
                points[n + 1] = .{ .x = x + 1, .y = @floatFromInt(y) };
                n += 2;
            }
            var i = lower.len;
            while (i > 0) {
                i -= 1;
                const x = x0 + @as(f32, @floatFromInt(i));
                points[n] = .{ .x = x + 1, .y = @floatFromInt(lower[i]) };
                points[n + 1] = .{ .x = x, .y = @floatFromInt(lower[i]) };
                n += 2;
            }
            s.BeginFigure(points[0], win32.D2D1_FIGURE_BEGIN_FILLED);
            s.AddLines(points[1..n].ptr, @intCast(n - 1));
            s.EndFigure(win32.D2D1_FIGURE_END_CLOSED);
            const hr = s.Close();
            if (hr.failed) win32.panicHresult("ID2D1GeometrySink.Close", hr);
        }
        // The zones as hard stops: each color from its stop to the next, then the next color.
        var stops: [2 * 8]win32.D2D1_GRADIENT_STOP = undefined;
        std.debug.assert(gradient.stops.len <= stops.len / 2);
        const span: f32 = @floatFromInt(gradient.bottom - gradient.top);
        var count: usize = 0;
        for (gradient.stops, 0..) |stop, z| {
            const from: f32 = @as(f32, @floatFromInt(gradient.bottom - stop.y)) / span;
            const to: f32 = if (z + 1 < gradient.stops.len) @as(f32, @floatFromInt(gradient.bottom - gradient.stops[z + 1].y)) / span else 1;
            stops[count] = .{ .position = from, .color = colorF(stop.color) };
            stops[count + 1] = .{ .position = to, .color = colorF(stop.color) };
            count += 2;
        }
        var collection: *win32.ID2D1GradientStopCollection = undefined;
        {
            const hr = p.target.CreateGradientStopCollection(&stops, @intCast(count), win32.D2D1_GAMMA_2_2, win32.D2D1_EXTEND_MODE_CLAMP, &collection);
            if (hr.failed) win32.panicHresult("CreateGradientStopCollection", hr);
        }
        defer _ = collection.IUnknown.Release();
        var brush: *win32.ID2D1LinearGradientBrush = undefined;
        {
            const line: win32.D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES = .{
                .startPoint = .{ .x = 0, .y = @floatFromInt(gradient.bottom) },
                .endPoint = .{ .x = 0, .y = @floatFromInt(gradient.top) },
            };
            const hr = p.target.CreateLinearGradientBrush(&line, null, collection, &brush);
            if (hr.failed) win32.panicHresult("CreateLinearGradientBrush", hr);
        }
        defer _ = brush.IUnknown.Release();
        p.target.FillGeometry(&geometry.ID2D1Geometry, &brush.ID2D1Brush, null);
    }

    /// A rect with fully rounded ends: a circle when square.
    pub fn pill(p: *const Painter, r: bb.Rect, c: bb.Color) void {
        const f = rectF(r);
        const radius = @min(f.right - f.left, f.bottom - f.top) / 2;
        const rr: win32.D2D1_ROUNDED_RECT = .{ .rect = f, .radiusX = radius, .radiusY = radius };
        p.target.FillRoundedRectangle(&rr, p.setColor(c));
    }

    pub fn text(p: *const Painter, utf8: []const u8, r: bb.Rect, font: bb.Font, c: bb.Color, alignment: bb.Align) void {
        var buf: [max_text]u16 = undefined;
        const wide = toWide(utf8, &buf);
        const format = p.text_formats.formats.get(font);
        {
            const hr = format.SetTextAlignment(switch (alignment) {
                .left => .LEADING,
                .center => .CENTER,
                .right => .TRAILING,
            });
            if (hr.failed) win32.panicHresult("SetTextAlignment", hr);
        }
        var f = rectF(r);
        if (font == .badge) {
            f.top -= p.text_formats.badge_shift;
            f.bottom -= p.text_formats.badge_shift;
        }
        p.target.DrawText(@ptrCast(wide.ptr), @intCast(wide.len), format, &f, p.setColor(c), .{ .CLIP = 1 }, .NATURAL);
    }

    /// How wide `utf8` draws in `font`, in pixels.
    pub fn textWidth(p: *const Painter, utf8: []const u8, font: bb.Font) i32 {
        return (TextMeasure{ .formats = p.text_formats }).width(utf8, font);
    }

    pub fn icon(p: *const Painter, which: bb.Icon, r: bb.Rect, font: bb.Font, c: bb.Color) void {
        const glyph = [1:0]u16{iconCodepoint(which)};
        const format = p.text_formats.formats.get(font);
        {
            const hr = format.SetTextAlignment(.CENTER);
            if (hr.failed) win32.panicHresult("SetTextAlignment", hr);
        }
        p.target.DrawText(&glyph, 1, format, &rectF(r), p.setColor(c), .{ .CLIP = 1 }, .NATURAL);
    }
};

/// Icons are glyphs from Windows' icon font: "Segoe Fluent Icons" on Windows 11, "Segoe MDL2
/// Assets" on Windows 10. Both use the same code points. DirectWrite silently substitutes a
/// missing font, which would draw boxes, so check it's really installed.
fn findIconFont() [:0]const u16 {
    var collection: *win32.IDWriteFontCollection = undefined;
    {
        const hr = global.dwrite_factory.GetSystemFontCollection(&collection, 0);
        if (hr.failed) win32.panicHresult("GetSystemFontCollection", hr);
    }
    defer _ = collection.IUnknown.Release();
    const candidates = [_][:0]const u16{ win32.L("Segoe Fluent Icons"), win32.L("Segoe MDL2 Assets") };
    for (candidates) |name| {
        var index: u32 = undefined;
        var exists: win32.BOOL = undefined;
        const hr = collection.FindFamilyName(name, &index, &exists);
        if (hr.failed) win32.panicHresult("FindFamilyName", hr);
        if (exists != 0) return name;
    }
    std.debug.panic("neither the 'Segoe Fluent Icons' nor the 'Segoe MDL2 Assets' font is installed", .{});
}

fn iconCodepoint(icon: bb.Icon) u16 {
    return switch (icon) {
        .screen => 0xE7F4, // TVMonitor
        .speaker => 0xE7F5, // Speakers
        .webcam => 0xE8B8, // Webcam
        .microphone => 0xE720, // Microphone
        .headphones => 0xE7F6, // Headphone
        .headset => 0xE95B, // Headset
        .handset => 0xE717, // Phone
        .display => 0xE7F4, // TVMonitor
        .pin => 0xE718, // Pin
        .pinned => 0xE842, // PinnedFill
        .collapse => 0xE70E, // ChevronUp
        .expand => 0xE70D, // ChevronDown
        .more => 0xE712, // More
        .minimize => 0xE921, // ChromeMinimize
        .check => 0xE73E, // CheckMark
    };
}

/// UTF-8 to UTF-16, truncating text too long for `buf`. Invalid UTF-8 is a bug in our own strings.
fn toWide(utf8: []const u8, buf: []u16) []const u16 {
    var len: usize = 0;
    var it = (std.unicode.Utf8View.init(utf8) catch |e| std.debug.panic("invalid UTF-8 '{s}': {t}", .{ utf8, e })).iterator();
    while (it.nextCodepoint()) |cp| {
        if (len + 2 > buf.len) break;
        if (cp < 0x10000) {
            buf[len] = @intCast(cp);
            len += 1;
        } else {
            const v = cp - 0x10000;
            buf[len] = @intCast(0xD800 + (v >> 10));
            buf[len + 1] = @intCast(0xDC00 + (v & 0x3FF));
            len += 2;
        }
    }
    return buf[0..len];
}

fn colorF(c: bb.Color) win32.D2D_COLOR_F {
    return .{
        .r = @as(f32, @floatFromInt(c.r)) / 255.0,
        .g = @as(f32, @floatFromInt(c.g)) / 255.0,
        .b = @as(f32, @floatFromInt(c.b)) / 255.0,
        .a = @as(f32, @floatFromInt(c.a)) / 255.0,
    };
}

fn rectF(r: bb.Rect) win32.D2D_RECT_F {
    return .{
        .left = @floatFromInt(r.left),
        .top = @floatFromInt(r.top),
        .right = @floatFromInt(r.right),
        .bottom = @floatFromInt(r.bottom),
    };
}

/// The rendering devices, shared by all our windows. Each window draws into its own Target.
const Gpu = struct {
    d3d_device: *win32.ID3D11Device,
    d2d_device: *win32.ID2D1Device,
    res_dc: *win32.ID2D1DeviceContext,
    dcomp: *win32.IDCompositionDesktopDevice,
    brush: *win32.ID2D1SolidColorBrush,

    fn init() Gpu {
        var d3d_device: *win32.ID3D11Device = undefined;
        {
            const hr = win32.D3D11CreateDevice(
                null,
                win32.D3D_DRIVER_TYPE_HARDWARE,
                null,
                win32.D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                null,
                0,
                win32.D3D11_SDK_VERSION,
                &d3d_device,
                null,
                null,
            );
            if (hr.failed) win32.panicHresult("D3D11CreateDevice", hr);
        }
        var dxgi_device: *win32.IDXGIDevice = undefined;
        {
            const hr = d3d_device.IUnknown.QueryInterface(win32.IID_IDXGIDevice, @ptrCast(&dxgi_device));
            if (hr.failed) win32.panicHresult("QueryInterface(IDXGIDevice)", hr);
        }
        defer _ = dxgi_device.IUnknown.Release();
        var d2d_device: *win32.ID2D1Device = undefined;
        {
            const hr = win32.D2D1CreateDevice(dxgi_device, null, @ptrCast(&d2d_device));
            if (hr.failed) win32.panicHresult("D2D1CreateDevice", hr);
        }
        var res_dc: *win32.ID2D1DeviceContext = undefined;
        {
            const hr = d2d_device.CreateDeviceContext(win32.D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &res_dc);
            if (hr.failed) win32.panicHresult("CreateDeviceContext", hr);
        }
        var brush: *win32.ID2D1SolidColorBrush = undefined;
        {
            const black: win32.D2D_COLOR_F = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
            const hr = res_dc.ID2D1RenderTarget.CreateSolidColorBrush(&black, null, &brush);
            if (hr.failed) win32.panicHresult("CreateSolidColorBrush", hr);
        }
        var dcomp: *win32.IDCompositionDesktopDevice = undefined;
        {
            const hr = win32.DCompositionCreateDevice2(&d2d_device.IUnknown, win32.IID_IDCompositionDesktopDevice, @ptrCast(&dcomp));
            if (hr.failed) win32.panicHresult("DCompositionCreateDevice2", hr);
        }
        return .{
            .d3d_device = d3d_device,
            .d2d_device = d2d_device,
            .res_dc = res_dc,
            .dcomp = dcomp,
            .brush = brush,
        };
    }

    fn deinit(gpu: *Gpu) void {
        _ = gpu.dcomp.IUnknown.Release();
        _ = gpu.brush.IUnknown.Release();
        _ = gpu.res_dc.IUnknown.Release();
        _ = gpu.d2d_device.IUnknown.Release();
        _ = gpu.d3d_device.IUnknown.Release();
        gpu.* = undefined;
    }
};

/// One window's DirectComposition visual and the surface we draw into.
const Target = struct {
    target: *win32.IDCompositionTarget,
    visual: *win32.IDCompositionVisual2,
    surface: ?*win32.IDCompositionSurface = null,
    surface_size: win32.D2D_SIZE_U = .{ .width = 0, .height = 0 },
    frame_dc: ?*win32.ID2D1DeviceContext = null,

    fn init(gpu: *Gpu, hwnd: win32.HWND) Target {
        var target: *win32.IDCompositionTarget = undefined;
        {
            const hr = gpu.dcomp.CreateTargetForHwnd(hwnd, 1, @ptrCast(&target));
            if (hr.failed) win32.panicHresult("CreateTargetForHwnd", hr);
        }
        var visual: *win32.IDCompositionVisual2 = undefined;
        {
            const hr = gpu.dcomp.IDCompositionDevice2.CreateVisual(@ptrCast(&visual));
            if (hr.failed) win32.panicHresult("CreateVisual", hr);
        }
        {
            const hr = target.SetRoot(&visual.IDCompositionVisual);
            if (hr.failed) win32.panicHresult("SetRoot", hr);
        }
        return .{ .target = target, .visual = visual };
    }

    fn deinit(t: *Target) void {
        if (t.surface) |s| _ = s.IUnknown.Release();
        _ = t.visual.IUnknown.Release();
        _ = t.target.IUnknown.Release();
        t.* = undefined;
    }

    fn ensureSurface(t: *Target, gpu: *Gpu, size: win32.D2D_SIZE_U) void {
        if (t.surface != null and t.surface_size.width == size.width and t.surface_size.height == size.height) return;
        if (t.surface) |s| {
            _ = s.IUnknown.Release();
            t.surface = null;
        }
        var surface: *win32.IDCompositionSurface = undefined;
        {
            const hr = gpu.dcomp.IDCompositionDevice2.CreateSurface(
                size.width,
                size.height,
                win32.DXGI_FORMAT_B8G8R8A8_UNORM,
                win32.DXGI_ALPHA_MODE_PREMULTIPLIED,
                @ptrCast(&surface),
            );
            if (hr.failed) win32.panicHresult("CreateSurface", hr);
        }
        {
            const hr = t.visual.IDCompositionVisual.SetContent(&surface.IUnknown);
            if (hr.failed) win32.panicHresult("SetContent", hr);
        }
        t.surface = surface;
        t.surface_size = size;
    }

    fn beginFrame(t: *Target, gpu: *Gpu, client: win32.SIZE) *win32.ID2D1DeviceContext {
        t.ensureSurface(gpu, .{ .width = @intCast(@max(client.cx, 1)), .height = @intCast(@max(client.cy, 1)) });
        var dc: *win32.ID2D1DeviceContext = undefined;
        var offset: win32.POINT = undefined;
        {
            const hr = t.surface.?.BeginDraw(null, win32.IID_ID2D1DeviceContext, @ptrCast(&dc), &offset);
            if (hr.failed) win32.panicHresult("IDCompositionSurface.BeginDraw", hr);
        }
        // We lay out in pixels, scaling by DPI ourselves.
        dc.ID2D1RenderTarget.SetDpi(96, 96);
        // ClearType needs an opaque background; ours is translucent.
        dc.ID2D1RenderTarget.SetTextAntialiasMode(.GRAYSCALE);
        const translate: win32.D2D_MATRIX_3X2_F = .{ .Anonymous = .{ .Anonymous1 = .{
            .m11 = 1,
            .m12 = 0,
            .m21 = 0,
            .m22 = 1,
            .dx = @floatFromInt(offset.x),
            .dy = @floatFromInt(offset.y),
        } } };
        dc.ID2D1RenderTarget.SetTransform(&translate);
        t.frame_dc = dc;
        return dc;
    }

    fn endFrame(t: *Target, gpu: *Gpu) error{RecreateTarget}!void {
        if (t.frame_dc) |dc| {
            _ = dc.IUnknown.Release();
            t.frame_dc = null;
        }
        {
            const hr = t.surface.?.EndDraw();
            if (hr == win32.D2DERR_RECREATE_TARGET or hr == win32.DXGI_ERROR_DEVICE_REMOVED) return error.RecreateTarget;
            if (hr.failed) win32.panicHresult("IDCompositionSurface.EndDraw", hr);
        }
        {
            const hr = gpu.dcomp.IDCompositionDevice2.Commit();
            if (hr.failed) win32.panicHresult("Commit", hr);
        }
    }
};

fn scale(v: i32, dpi: u32) i32 {
    return win32.scaleDpi(i32, v, dpi);
}

test {
    _ = bb;
    _ = record;
    _ = @import("flac.zig");
    _ = @import("journal.zig");
    _ = @import("maxstring.zig");
}

const builtin = @import("builtin");
const std = @import("std");
const win32 = @import("win32").everything;
const wintrace = @import("wintrace");
const bb = @import("bb.zig");
const wasapi = @import("wasapi.zig");
const record = @import("record.zig");
