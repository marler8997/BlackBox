//! The installer's dialog, drawn in Black Box's colors: MessageBox can't be themed, and beeps.

pub const Line = struct {
    text: []const u8,
    muted: bool = false,
};

pub const Button = struct {
    label: []const u8,
    /// Enter presses the primary button. A dialog without one (a danger button's) needs a click.
    style: enum { primary, normal, danger },
};

pub const Spec = struct {
    title: []const u8,
    lines: []const Line,
    buttons: []const Button,
    /// Checked every 250 ms: once it's true, the dialog closes by itself.
    wait_for: ?*const fn () bool = null,
};

pub const Answer = union(enum) {
    button: usize,
    /// Escape or the close button.
    dismissed,
    waited,
};

pub fn show(spec: Spec) Answer {
    const hinstance = win32.GetModuleHandleW(null);
    const wc: win32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = .{},
        .lpfnWndProc = wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = win32.LoadIconW(hinstance, @ptrFromInt(1)),
        .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    };
    if (0 == win32.RegisterClassExW(&wc)) switch (win32.GetLastError()) {
        // By an earlier dialog.
        .ERROR_CLASS_ALREADY_EXISTS => {},
        else => |e| win32.panicWin32("RegisterClassEx", e),
    };

    var state: State = .{ .spec = spec };
    const hwnd = win32.CreateWindowExW(.{}, class_name, win32.L("Black Box Installer"), style, win32.CW_USEDEFAULT, win32.CW_USEDEFAULT, 0, 0, null, null, hinstance, &state) orelse
        win32.panicWin32("CreateWindowEx", win32.GetLastError());
    defer {
        if (0 == win32.DestroyWindow(hwnd)) win32.panicWin32("DestroyWindow", win32.GetLastError());
        state.fonts.deinit();
    }
    {
        const dark: win32.BOOL = 1;
        const hr = win32.DwmSetWindowAttribute(hwnd, win32.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, @sizeOf(win32.BOOL));
        if (hr.failed) win32.panicHresult("DwmSetWindowAttribute(dark mode)", hr);
    }
    state.setDpi(hwnd, win32.dpiFromHwnd(hwnd));
    {
        const frame = state.frameSize();
        var work: win32.RECT = undefined;
        if (0 == win32.SystemParametersInfoW(win32.SPI_GETWORKAREA, 0, &work, .{})) win32.panicWin32("SystemParametersInfo", win32.GetLastError());
        const x = work.left + @divTrunc(work.right - work.left - frame.cx, 2);
        const y = work.top + @divTrunc(work.bottom - work.top - frame.cy, 2);
        if (0 == win32.SetWindowPos(hwnd, null, x, y, frame.cx, frame.cy, .{ .NOZORDER = 1, .NOACTIVATE = 1 })) win32.panicWin32("SetWindowPos", win32.GetLastError());
    }
    if (spec.wait_for != null) {
        if (0 == win32.SetTimer(hwnd, 1, 250, null)) win32.panicWin32("SetTimer", win32.GetLastError());
    }
    _ = win32.ShowWindow(hwnd, win32.SW_SHOWNORMAL);

    while (state.answer == null) {
        var msg: win32.MSG = undefined;
        switch (win32.GetMessageW(&msg, null, 0, 0)) {
            -1 => win32.panicWin32("GetMessage", win32.GetLastError()),
            0 => std.debug.panic("WM_QUIT while a dialog was open", .{}),
            else => {},
        }
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
    return state.answer.?;
}

const class_name = win32.L("BlackBoxInstallerDialog");
const style: win32.WINDOW_STYLE = .{ .DLGFRAME = 1, .BORDER = 1, .SYSMENU = 1 };

/// Black Box's colors (src/bb.zig), made opaque over the window's: GDI doesn't blend.
const color = struct {
    const window: win32.COLORREF = .rgb(24, 24, 28);
    const text: win32.COLORREF = .rgb(235, 235, 240);
    const dim: win32.COLORREF = .rgb(175, 175, 185);
    const button: win32.COLORREF = .rgb(68, 68, 80);
    const button_hot: win32.COLORREF = .rgb(95, 95, 110);
    const accent: win32.COLORREF = .rgb(160, 88, 45);
    const accent_hot: win32.COLORREF = .rgb(188, 106, 58);
    const danger: win32.COLORREF = .rgb(160, 40, 40);
    const danger_hot: win32.COLORREF = .rgb(190, 50, 50);
};

const State = struct {
    spec: Spec,
    answer: ?Answer = null,
    hover: ?usize = null,
    /// Pressed on, so letting go over it clicks it.
    pressed: ?usize = null,
    tracking_mouse: bool = false,
    dpi: u32 = 0,
    fonts: Fonts = .{},
    layout: Layout = undefined,

    /// Fonts and layout for this DPI, which the line wrapping depends on.
    fn setDpi(s: *State, hwnd: win32.HWND, dpi: u32) void {
        if (s.dpi == dpi) return;
        s.dpi = dpi;
        s.fonts.deinit();
        s.fonts = .init(dpi);
        const hdc = win32.GetDC(hwnd) orelse win32.panicWin32("GetDC", win32.GetLastError());
        defer if (0 == win32.ReleaseDC(hwnd, hdc)) win32.panicWin32("ReleaseDC", win32.GetLastError());
        s.layout = .init(s.spec, dpi, hdc, s.fonts.body.?);
    }

    fn frameSize(s: *const State) win32.SIZE {
        var frame: win32.RECT = .{ .left = 0, .top = 0, .right = s.layout.client.cx, .bottom = s.layout.client.cy };
        if (0 == win32.AdjustWindowRectExForDpi(&frame, style, 0, .{}, s.dpi)) win32.panicWin32("AdjustWindowRectExForDpi", win32.GetLastError());
        return .{ .cx = frame.right - frame.left, .cy = frame.bottom - frame.top };
    }

    fn buttonAt(s: *const State, lparam: win32.LPARAM) ?usize {
        const x = win32.xFromLparam(lparam);
        const y = win32.yFromLparam(lparam);
        for (0..s.spec.buttons.len) |i| {
            const r = s.layout.button(s.spec.buttons.len, i);
            if (x >= r.left and x < r.right and y >= r.top and y < r.bottom) return i;
        }
        return null;
    }

    fn setHover(s: *State, hwnd: win32.HWND, hover: ?usize) void {
        if (s.hover == hover) return;
        s.hover = hover;
        win32.invalidateHwnd(hwnd);
    }

    fn paint(s: *const State, hwnd: win32.HWND) void {
        const hdc, const ps = win32.beginPaint(hwnd);
        defer win32.endPaint(hwnd, &ps);
        const l = &s.layout;
        fill(hdc, .{ .left = 0, .top = 0, .right = l.client.cx, .bottom = l.client.cy }, color.window);
        if (0 == win32.SetBkMode(hdc, .TRANSPARENT)) win32.panicWin32("SetBkMode", win32.GetLastError());

        const icon = win32.LoadImageW(win32.GetModuleHandleW(null), @ptrFromInt(1), .ICON, l.icon, l.icon, win32.LR_SHARED) orelse
            win32.panicWin32("LoadImage(icon)", win32.GetLastError());
        if (0 == win32.DrawIconEx(hdc, l.margin, l.margin, @ptrCast(icon), l.icon, l.icon, 0, null, win32.DI_NORMAL)) win32.panicWin32("DrawIconEx", win32.GetLastError());

        const old_font = win32.SelectObject(hdc, s.fonts.title.?) orelse win32.panicWin32("SelectObject", win32.GetLastError());
        defer _ = win32.SelectObject(hdc, old_font) orelse win32.panicWin32("SelectObject", win32.GetLastError());
        var title = l.title;
        drawText(hdc, s.spec.title, &title, color.text, .{ .SINGLELINE = 1, .VCENTER = 1, .END_ELLIPSIS = 1 });

        _ = win32.SelectObject(hdc, s.fonts.body.?) orelse win32.panicWin32("SelectObject", win32.GetLastError());
        for (s.spec.lines, l.lines[0..s.spec.lines.len]) |line, rect| {
            var r = rect;
            drawText(hdc, line.text, &r, if (line.muted) color.dim else color.text, wrap);
        }
        for (s.spec.buttons, 0..) |button, i| {
            const hot = s.hover == i;
            const back = switch (button.style) {
                .primary => if (hot) color.accent_hot else color.accent,
                .normal => if (hot) color.button_hot else color.button,
                .danger => if (hot) color.danger_hot else color.danger,
            };
            var r = l.button(s.spec.buttons.len, i);
            fill(hdc, r, back);
            drawText(hdc, button.label, &r, color.text, .{ .SINGLELINE = 1, .VCENTER = 1, .CENTER = 1 });
        }
    }
};

const Fonts = struct {
    title: ?win32.HFONT = null,
    body: ?win32.HFONT = null,

    fn init(dpi: u32) Fonts {
        return .{ .title = font(dpi, 20, .SEMIBOLD), .body = font(dpi, 15, .NORMAL) };
    }

    fn deinit(f: *Fonts) void {
        if (f.title) |h| win32.deleteObject(h);
        if (f.body) |h| win32.deleteObject(h);
        f.* = .{};
    }

    fn font(dpi: u32, px: i32, weight: win32.FONT_WEIGHT) win32.HFONT {
        return win32.CreateFontW(
            -scale(px, dpi),
            0,
            0,
            0,
            @intCast(@intFromEnum(weight)),
            0,
            0,
            0,
            @intFromEnum(win32.DEFAULT_CHARSET),
            @intFromEnum(win32.OUT_DEFAULT_PRECIS),
            @as(u8, @bitCast(win32.CLIP_DEFAULT_PRECIS)),
            @intFromEnum(win32.CLEARTYPE_QUALITY),
            @intFromEnum(win32.FF_DONTCARE),
            win32.L("Segoe UI"),
        ) orelse win32.panicWin32("CreateFont", win32.GetLastError());
    }
};

/// Lines wrap at spaces, and inside a word too long for a line (a path).
const wrap: win32.DRAW_TEXT_FORMAT = .{ .WORDBREAK = 1, .EDITCONTROL = 1 };

/// In pixels, at a DPI.
const Layout = struct {
    client: win32.SIZE,
    margin: i32,
    icon: i32,
    title: win32.RECT,
    lines: [max_lines]win32.RECT,
    buttons_top: i32,
    button_width: i32,
    button_height: i32,
    gap: i32,

    const max_lines = 4;

    fn init(spec: Spec, dpi: u32, hdc: win32.HDC, body: win32.HFONT) Layout {
        if (spec.lines.len > max_lines) std.debug.panic("a dialog has {} lines, at most {} fit", .{ spec.lines.len, max_lines });
        const width = scale(480, dpi);
        const margin = scale(20, dpi);
        const gap = scale(10, dpi);
        const icon = scale(32, dpi);
        var l: Layout = .{
            .client = undefined,
            .margin = margin,
            .icon = icon,
            .title = .{ .left = margin + icon + gap, .top = margin, .right = width - margin, .bottom = margin + icon },
            .lines = undefined,
            .buttons_top = undefined,
            .button_width = scale(130, dpi),
            .button_height = scale(30, dpi),
            .gap = gap,
        };
        const old_font = win32.SelectObject(hdc, body) orelse win32.panicWin32("SelectObject", win32.GetLastError());
        defer _ = win32.SelectObject(hdc, old_font) orelse win32.panicWin32("SelectObject", win32.GetLastError());
        var y = margin + icon + gap;
        for (spec.lines, l.lines[0..spec.lines.len]) |line, *r| {
            r.* = .{ .left = margin, .top = y, .right = width - margin, .bottom = y };
            drawText(hdc, line.text, r, color.text, .{ .CALCRECT = 1, .WORDBREAK = 1, .EDITCONTROL = 1 });
            y = r.bottom + scale(4, dpi);
        }
        l.buttons_top = y + gap * 2;
        l.client = .{ .cx = width, .cy = l.buttons_top + l.button_height + margin };
        return l;
    }

    /// Right-aligned, in the order given.
    fn button(l: *const Layout, count: usize, i: usize) win32.RECT {
        const n: i32 = @intCast(count);
        const k: i32 = @intCast(i);
        const x = l.client.cx - l.margin - (n - k) * l.button_width - (n - 1 - k) * l.gap;
        return .{ .left = x, .top = l.buttons_top, .right = x + l.button_width, .bottom = l.buttons_top + l.button_height };
    }
};

fn scale(px: i32, dpi: u32) i32 {
    return @divTrunc(px * @as(i32, @intCast(dpi)) + 48, 96);
}

fn fill(hdc: win32.HDC, r: win32.RECT, c: win32.COLORREF) void {
    const brush = win32.createSolidBrush(c);
    defer win32.deleteObject(brush);
    win32.fillRect(hdc, r, brush);
}

/// With CALCRECT, sets r's bottom to fit the text instead of drawing it.
fn drawText(hdc: win32.HDC, utf8: []const u8, r: *win32.RECT, c: win32.COLORREF, format: win32.DRAW_TEXT_FORMAT) void {
    // The installer's longest text is a message cut short at 2048 bytes: at most a unit each.
    var wide: [2048]u16 = undefined;
    if (utf8.len > wide.len) std.debug.panic("dialog text of {} bytes, at most {} fit: {s}", .{ utf8.len, wide.len, utf8 });
    const len = std.unicode.wtf8ToWtf16Le(&wide, utf8) catch std.debug.panic("dialog text isn't WTF-8: {s}", .{utf8});
    if (len == 0) return;
    if (win32.COLORREF.invalid == win32.SetTextColor(hdc, c)) win32.panicWin32("SetTextColor", win32.GetLastError());
    var f = format;
    f.NOPREFIX = 1;
    if (0 == win32.DrawTextW(hdc, @ptrCast(&wide), @intCast(len), r, f)) win32.panicWin32("DrawText", win32.GetLastError());
}

fn wndProc(hwnd: win32.HWND, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    if (msg == win32.WM_NCCREATE) {
        const create: *const win32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        win32.SetLastError(.NO_ERROR);
        if (0 == win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, @bitCast(@intFromPtr(create.lpCreateParams)))) {
            const err = win32.GetLastError();
            if (err != .NO_ERROR) win32.panicWin32("SetWindowLongPtr", err);
        }
        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }
    // Zero for the messages before WM_NCCREATE (WM_GETMINMAXINFO).
    const userdata = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (userdata == 0) return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const s: *State = @ptrFromInt(@as(usize, @bitCast(userdata)));
    switch (msg) {
        win32.WM_PAINT => {
            s.paint(hwnd);
            return 0;
        },
        win32.WM_ERASEBKGND => return 1,
        win32.WM_MOUSEMOVE => {
            if (!s.tracking_mouse) {
                var track: win32.TRACKMOUSEEVENT = .{ .cbSize = @sizeOf(win32.TRACKMOUSEEVENT), .dwFlags = .{ .LEAVE = 1 }, .hwndTrack = hwnd, .dwHoverTime = 0 };
                if (0 == win32.TrackMouseEvent(&track)) win32.panicWin32("TrackMouseEvent", win32.GetLastError());
                s.tracking_mouse = true;
            }
            s.setHover(hwnd, s.buttonAt(lparam));
            return 0;
        },
        win32.WM_MOUSELEAVE => {
            s.tracking_mouse = false;
            s.pressed = null;
            s.setHover(hwnd, null);
            return 0;
        },
        win32.WM_LBUTTONDOWN => {
            s.pressed = s.buttonAt(lparam);
            return 0;
        },
        win32.WM_LBUTTONUP => {
            if (s.buttonAt(lparam)) |i| if (s.pressed == i) {
                s.answer = .{ .button = i };
            };
            s.pressed = null;
            return 0;
        },
        win32.WM_KEYDOWN => {
            switch (@as(win32.VIRTUAL_KEY, @enumFromInt(wparam))) {
                win32.VK_ESCAPE => s.answer = .dismissed,
                win32.VK_RETURN => for (s.spec.buttons, 0..) |button, i| if (button.style == .primary) {
                    s.answer = .{ .button = i };
                    break;
                },
                else => {},
            }
            return 0;
        },
        win32.WM_TIMER => {
            if (s.spec.wait_for.?()) s.answer = .waited;
            return 0;
        },
        win32.WM_CLOSE => {
            s.answer = .dismissed;
            return 0;
        },
        win32.WM_GETDPISCALEDSIZE => {
            s.setDpi(hwnd, @intCast(wparam));
            const size: *win32.SIZE = @ptrFromInt(@as(usize, @bitCast(lparam)));
            size.* = s.frameSize();
            return 1;
        },
        win32.WM_DPICHANGED => {
            s.setDpi(hwnd, win32.hiword(wparam));
            const r: *const win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (0 == win32.SetWindowPos(hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, .{ .NOZORDER = 1, .NOACTIVATE = 1 }))
                win32.panicWin32("SetWindowPos", win32.GetLastError());
            win32.invalidateHwnd(hwnd);
            return 0;
        },
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

const std = @import("std");
const win32 = @import("win32").everything;
