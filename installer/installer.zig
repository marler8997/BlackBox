//! Installs Black Box for the current user to %LOCALAPPDATA%\BlackBox. Uninstalling is this
//! program again, copied there as uninstall.exe.
//!
//! The recordings live in the same folder, so uninstalling removes what was installed file by
//! file, never the folder as a whole. And a running Black Box is never closed for us: it may
//! be recording.

pub const panic = std.debug.FullPanic(onPanic);
pub const std_options: std.Options = .{
    .io_vtable = .threaded,
    // std's segfault handler logs and aborts without a way for us to handle it. Disabling
    // it routes to our unhandled exception filter like every other exception.
    .enable_segfault_handler = false,
};

const global = struct {
    /// How far the panic handler got. A panic while logging or showing the message box re-enters
    /// the handler, which skips the step that panicked instead of recursing forever.
    var panic_state: enum { none, log, msgbox } = .none;
    var crash_path: ?[:0]const u16 = null;
    var crash_report: ?union(enum) {
        file,
        no_path,
        file_failed: win32.WIN32_ERROR,
    } = null;
};

// Don't return errors from main: std's code that calls main would only log the trace,
// without the message box.
pub fn main(init: std.process.Init.Minimal) void {
    if (wintrace.SetUnhandledExceptionFilter(&unhandledExceptionFilter) != null)
        @panic("an unhandled exception filter was already installed");

    // The crash report's path, named now so a crash only has to create the file. In TEMP, not
    // Black Box's crashes folder: creating that would keep an uninstall from removing the
    // install folder.
    {
        var t: win32.SYSTEMTIME = undefined;
        win32.GetLocalTime(&t);
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "\\BlackBoxInstaller-{d:0>4}-{d:0>2}-{d:0>2}_{d:0>2}-{d:0>2}-{d:0>2}_pid{d}.txt", .{
            t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond, win32.GetCurrentProcessId(),
        }) catch unreachable;
        var wide: [name_buf.len]u16 = undefined;
        for (name, wide[0..name.len]) |c, *w| w.* = c;
        var path = Path.temp();
        path.append(wide[0..name.len]);
        // Needed until the process ends, so never freed.
        const copy = std.heap.smp_allocator.allocSentinel(u16, path.len, 0) catch @panic("out of memory for the crash report path");
        @memcpy(copy, path.slice());
        global.crash_path = copy;
    }

    // Leaves room to report a stack overflow.
    var guarantee: u32 = wintrace.stack_guarantee;
    if (0 == wintrace.SetThreadStackGuarantee(&guarantee)) win32.panicWin32("SetThreadStackGuarantee", win32.GetLastError());

    const mode = parseArgs(init.args);
    const dir = Path.known(&win32.FOLDERID_LocalAppData).join("BlackBox");
    const self = selfPath();
    // Run as the installed uninstall.exe, it uninstalls, even double-clicked without --uninstall.
    const uninstaller = dir.join(uninstaller_name);
    switch (if (self.eqlIgnoreCase(&uninstaller)) .uninstall else mode) {
        .install => install(&dir, &self, &uninstaller),
        .uninstall => uninstall(&dir, &self),
    }
}

const uninstaller_name = "uninstall.exe";
const uninstall_key = win32.L("Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\BlackBox");

pub const wintrace_options: wintrace.Options = .{ .mode = .small };

/// Points stderr at a new report file. Once per crash: an exception raised after a panic
/// (std.process.abort's breakpoint) must not start another report.
fn prepareCrashReport() void {
    if (global.crash_report == null) {
        const path = global.crash_path orelse {
            global.crash_report = .no_path;
            return;
        };
        const handle = win32.CreateFileW(path, win32.FILE_GENERIC_WRITE, .{ .READ = 1 }, null, win32.CREATE_NEW, win32.FILE_ATTRIBUTE_NORMAL, null);
        if (handle == win32.INVALID_HANDLE_VALUE) {
            global.crash_report = .{ .file_failed = win32.GetLastError() };
            return;
        }
        std.os.windows.peb().ProcessParameters.hStdError = handle;
        global.crash_report = .file;
    }
}

fn onPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    if (global.panic_state == .none) {
        global.panic_state = .log;
        prepareCrashReport();
        // Before the message box, which may never be dismissed.
        var buf: [256]u8 = undefined;
        var report = reportWriter(&buf);
        const w = &report;
        write: {
            w.print("panic: {s}\n", .{msg}) catch break :write;
            wintrace.writeCurrentStackTrace(w, ret_addr orelse @returnAddress()) catch break :write;
            w.flush() catch break :write;
        }
    }
    if (global.panic_state == .log) {
        global.panic_state = .msgbox;
        crashMsgbox("{s}", .{msg});
    }
    // Not std.debug.defaultPanic, which would print the message and trace again.
    std.process.abort();
}

/// The crash report (stderr, once prepareCrashReport points it at the file), written
/// directly: std.debug.lockStderr takes a lock this thread may hold already, in a panic, and
/// brings in std.Io.Threaded.
fn reportWriter(buffer: []u8) std.Io.Writer {
    return .{ .vtable = &.{ .drain = drainReport }, .buffer = buffer };
}

fn drainReport(w: *std.Io.Writer, data: []const []const u8, splat: usize) error{WriteFailed}!usize {
    try writeReport(w.buffered());
    w.end = 0;
    var written: usize = 0;
    for (data[0 .. data.len - 1]) |bytes| {
        try writeReport(bytes);
        written += bytes.len;
    }
    const last = data[data.len - 1];
    for (0..splat) |_| try writeReport(last);
    return written + splat * last.len;
}

fn writeReport(bytes: []const u8) error{WriteFailed}!void {
    const handle = std.os.windows.peb().ProcessParameters.hStdError;
    var rest = bytes;
    while (rest.len > 0) {
        var written: u32 = 0;
        if (0 == win32.WriteFile(handle, rest.ptr, @intCast(@min(rest.len, std.math.maxInt(u32))), &written, null)) return error.WriteFailed;
        rest = rest[written..];
    }
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

fn crashMsgbox(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt ++ "\n\n{f}", args ++ .{std.fmt.Alt(void, formatReportNote){ .data = {} }}) catch blk: {
        buf[buf.len - 3 ..].* = "...".*;
        break :blk &buf;
    };
    // Invalid UTF-8 (in a panic message) shows as '?'.
    var wide: [buf.len:0]u16 = undefined;
    const len = std.unicode.wtf8ToWtf16Le(&wide, text) catch blk: {
        for (text, 0..) |c, i| wide[i] = if (c < 0x80) c else '?';
        break :blk text.len;
    };
    wide[len] = 0;
    // Its failure is ignored: the report file is written, and there's nowhere left to say so.
    _ = win32.MessageBoxW(null, wide[0..len :0], win32.L("Black Box Installer crash"), .{ .ICONHAND = 1 });
}

fn formatReportNote(_: void, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (global.crash_report orelse .no_path) {
        .file => try w.print("Details were saved to {f}", .{std.unicode.fmtUtf16Le(global.crash_path.?)}),
        .no_path => try w.writeAll("Details couldn't be saved, this happened before the crash report file was named."),
        .file_failed => |e| try w.print("Details couldn't be saved to {f}: {f}", .{ std.unicode.fmtUtf16Le(global.crash_path.?), e }),
    }
}

const Mode = enum { install, uninstall };

fn parseArgs(args: std.process.Args) Mode {
    // The Windows iterator needs the command line as WTF-8 plus a byte: at most 3 bytes for
    // each of a command line's 32767 UTF-16 units.
    var buf: [3 * 32767 + 1]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    var it = args.iterateAllocator(fba.allocator()) catch unreachable;
    defer it.deinit();
    _ = it.skip();
    var mode: Mode = .install;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--uninstall")) {
            mode = .uninstall;
        } else msgboxExit("Unknown argument: {s}\n\nUsage: BlackBoxInstaller-" ++ @tagName(builtin.cpu.arch) ++ ".exe [--uninstall]", .{arg});
    }
    return mode;
}

fn install(dir: *const Path, self: *const Path, uninstaller: *const Path) void {
    claimMutex();
    const machine = machineArch();
    waitForBlackBoxToQuit("update it");

    const exe = dir.join("BlackBox.exe");
    const updating = win32.GetFileAttributesW(exe.z()) != win32.INVALID_FILE_ATTRIBUTES or switch (win32.GetLastError()) {
        .ERROR_FILE_NOT_FOUND, .ERROR_PATH_NOT_FOUND => false,
        else => |e| msgboxExit("Couldn't check for {f}: {f}", .{ exe.fmt(), e }),
    };
    makeDir(dir);
    makeDir(&dir.join("bin"));
    var bytes: u64 = 0;
    var found = false;
    inline for (comptime payload.Arch.native.installerArches()) |arch| if (arch == machine) {
        found = true;
        inline for (payload.files, 0..) |file, f| {
            bytes += installFile(&dir.join(file), @embedFile(comptime payload.importName(arch, f)));
        }
    };
    // Unreachable in practice: only the ARM64 installer lacks a build, and it can't run on x64.
    if (!found) msgboxExit("This installer has no Black Box for this {t} PC. Download the installer for it from https://github.com/marler8997/BlackBox/releases/latest", .{machine});
    if (0 == win32.CopyFileW(self.z(), uninstaller.z(), 0))
        msgboxExit("Couldn't copy the installer to {f}: {f}", .{ uninstaller.fmt(), win32.GetLastError() });

    addToPath(&dir.join("bin"));
    writeShortcut(dir, &exe);
    writeUninstallKey(dir, &exe, uninstaller, bytes);

    if (message(.{ .YESNO = 1, .ICONASTERISK = 1 }, "Black Box is {s}, in {f}. It's in the Start Menu, and the command line's blackbox is in new consoles.\n\nStart Black Box now?", .{
        if (updating) "updated" else "installed",
        dir.fmt(),
    }) == .YES) launch(&exe, null);
}

fn uninstall(dir: *const Path, self: *const Path) void {
    // Windows won't delete a running program, so it runs from a copy in TEMP (left there).
    if (self.startsWithIgnoreCase(dir)) {
        const copy = Path.temp().join("blackbox-uninstall.exe");
        if (0 == win32.CopyFileW(self.z(), copy.z(), 0))
            msgboxExit("Couldn't copy the uninstaller to {f}: {f}", .{ copy.fmt(), win32.GetLastError() });
        launch(&copy, win32.L("--uninstall"));
        return;
    }
    claimMutex();
    const rec = dir.join("rec");
    if (message(.{ .YESNO = 1, .ICONHAND = 1, .ICONQUESTION = 1, .DEFBUTTON2 = 1 }, "Uninstall Black Box?\n\nYour recordings stay, in {f}.", .{rec.fmt()}) != .YES) return;
    waitForBlackBoxToQuit("uninstall it");

    inline for (payload.files) |file| {
        const path = dir.join(file);
        deleteFile(&path);
        deleteFile(&path.join2(".old"));
        deleteFile(&path.join2(".installing"));
    }
    deleteFile(&dir.join(uninstaller_name));
    removeDirIfEmpty(&dir.join("bin"));
    removeDirIfEmpty(dir);

    removeFromPath(&dir.join("bin"));
    deleteFile(&shortcutPath());
    switch (win32.RegDeleteTreeW(win32.HKEY_CURRENT_USER, uninstall_key)) {
        .NO_ERROR, .ERROR_FILE_NOT_FOUND => {},
        else => |e| msgboxExit("Couldn't remove Black Box from the installed apps: {f}", .{e}),
    }
    _ = message(.{ .ICONASTERISK = 1 }, "Black Box is uninstalled. Your recordings are still in {f}.", .{rec.fmt()});
}

/// IsWow64Process2 gives the machine's architecture even to an emulated process: the x86_64
/// installer, emulated on an ARM64 PC, installs the ARM64 build.
fn machineArch() payload.Arch {
    var process: win32.IMAGE_FILE_MACHINE = undefined;
    var native: win32.IMAGE_FILE_MACHINE = undefined;
    if (0 == win32.IsWow64Process2(win32.GetCurrentProcess(), &process, &native))
        win32.panicWin32("IsWow64Process2", win32.GetLastError());
    return switch (native) {
        .AMD64 => .x86_64,
        .ARM64 => .aarch64,
        else => msgboxExit("Black Box runs on x86_64 and ARM64 Windows, this PC is neither (machine 0x{x}).", .{@backingInt(native)}),
    };
}

fn claimMutex() void {
    _ = win32.CreateMutexW(null, 1, win32.L("BlackBoxInstallerRunning")) orelse win32.panicWin32("CreateMutex", win32.GetLastError());
    if (win32.GetLastError() == .ERROR_ALREADY_EXISTS) msgboxExit("Black Box Installer is already running.", .{});
}

/// FindWindowW gives null both for no window and for failing, which this tells apart.
fn blackBoxRunning() bool {
    win32.SetLastError(.NO_ERROR);
    if (win32.FindWindowW(win32.L("BlackBoxMainWindow"), null) != null) return true;
    const err = win32.GetLastError();
    if (err != .NO_ERROR) msgboxExit("Couldn't check whether Black Box is running: {f}", .{err});
    return false;
}

fn waitForBlackBoxToQuit(comptime to: []const u8) void {
    while (blackBoxRunning()) {
        // MB_RETRYCANCEL is 5: zigwin32 has its bits as OKCANCEL and YESNO.
        if (message(.{ .OKCANCEL = 1, .YESNO = 1, .ICONASTERISK = 1 }, "Black Box is running. Quit it to " ++ to ++ ".\n\nIf it's recording, stop the recording first. Black Box closes once the recording's files are finished.", .{}) != .RETRY)
            win32.ExitProcess(1);
    }
}

/// Decompressed to NAME.installing, then moved over NAME. Returns its size.
fn installFile(dest: *const Path, compressed: []const u8) u64 {
    const tmp = dest.join2(".installing");
    var bytes: u64 = 0;
    {
        const file = win32.CreateFileW(tmp.z(), win32.FILE_GENERIC_WRITE, .{}, null, win32.CREATE_ALWAYS, win32.FILE_ATTRIBUTE_NORMAL, null);
        if (file == win32.INVALID_HANDLE_VALUE) msgboxExit("Couldn't create {f}: {f}", .{ tmp.fmt(), win32.GetLastError() });
        defer win32.closeHandle(file);
        var in: std.Io.Reader = .fixed(compressed);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var decompress: std.compress.flate.Decompress = .init(&in, .zlib, &window);
        var chunk: [64 * 1024]u8 = undefined;
        while (true) {
            const n = decompress.reader.readSliceShort(&chunk) catch
                msgboxExit("This installer is damaged: {f} doesn't decompress ({?t}). Download it again.", .{ dest.fmt(), decompress.err });
            if (n == 0) break;
            writeAll(file, chunk[0..n], &tmp);
            bytes += n;
        }
        if (0 == win32.FlushFileBuffers(file)) msgboxExit("Couldn't write {f}: {f}", .{ tmp.fmt(), win32.GetLastError() });
    }
    const flags: win32.MOVE_FILE_FLAGS = .{ .REPLACE_EXISTING = 1, .WRITE_THROUGH = 1 };
    if (0 != win32.MoveFileExW(tmp.z(), dest.z(), flags)) return bytes;
    switch (win32.GetLastError()) {
        // In use (the command line, recovering a recording): a running program can be renamed
        // but not replaced. Moved aside, removed by the next install or uninstall.
        .ERROR_ACCESS_DENIED, .ERROR_SHARING_VIOLATION, .ERROR_USER_MAPPED_FILE => {},
        else => |e| msgboxExit("Couldn't replace {f}: {f}", .{ dest.fmt(), e }),
    }
    const old = dest.join2(".old");
    deleteFile(&old);
    if (0 == win32.MoveFileExW(dest.z(), old.z(), .{ .REPLACE_EXISTING = 1 }))
        msgboxExit("{f} is in use: close what's using it and run the installer again ({f})", .{ dest.fmt(), win32.GetLastError() });
    if (0 == win32.MoveFileExW(tmp.z(), dest.z(), flags))
        msgboxExit("Couldn't replace {f}: {f}", .{ dest.fmt(), win32.GetLastError() });
    return bytes;
}

fn writeAll(file: win32.HANDLE, data: []const u8, path: *const Path) void {
    var rest = data;
    while (rest.len > 0) {
        var written: u32 = 0;
        if (0 == win32.WriteFile(file, rest.ptr, @intCast(rest.len), &written, null))
            msgboxExit("Couldn't write {f}: {f}", .{ path.fmt(), win32.GetLastError() });
        rest = rest[written..];
    }
}

fn makeDir(path: *const Path) void {
    if (0 != win32.CreateDirectoryW(path.z(), null)) return;
    switch (win32.GetLastError()) {
        .ERROR_ALREADY_EXISTS => {},
        else => |e| msgboxExit("Couldn't create {f}: {f}", .{ path.fmt(), e }),
    }
}

fn deleteFile(path: *const Path) void {
    if (0 != win32.DeleteFileW(path.z())) return;
    switch (win32.GetLastError()) {
        .ERROR_FILE_NOT_FOUND, .ERROR_PATH_NOT_FOUND => {},
        else => |e| msgboxExit("Couldn't delete {f}: {f}", .{ path.fmt(), e }),
    }
}

fn removeDirIfEmpty(path: *const Path) void {
    if (0 != win32.RemoveDirectoryW(path.z())) return;
    switch (win32.GetLastError()) {
        .ERROR_DIR_NOT_EMPTY, .ERROR_FILE_NOT_FOUND, .ERROR_PATH_NOT_FOUND => {},
        else => |e| msgboxExit("Couldn't remove {f}: {f}", .{ path.fmt(), e }),
    }
}

fn launch(exe: *const Path, args: ?[*:0]const u16) void {
    const result = win32.ShellExecuteW(null, win32.L("open"), exe.z(), args, null, win32.SW_SHOWNORMAL);
    // Above 32 is success.
    if (@intFromPtr(result) <= 32) msgboxExit("Couldn't start {f}: error {d}", .{ exe.fmt(), @intFromPtr(result) });
}

/// The longest value an environment variable can have, in UTF-16 units.
const max_env_len = 32767;

const PathValue = struct {
    kind: win32.REG_VALUE_TYPE,
    buf: [max_env_len]u16,
    len: usize,

    fn text(v: *const PathValue) []const u16 {
        return v.buf[0..v.len];
    }
};

fn closeKey(key: win32.HKEY) void {
    const err = win32.RegCloseKey(key);
    if (err != .NO_ERROR) win32.panicWin32("RegCloseKey", err);
}

fn openEnvironment() win32.HKEY {
    var key: ?win32.HKEY = null;
    const err = win32.RegOpenKeyExW(win32.HKEY_CURRENT_USER, win32.L("Environment"), 0, .{ .QUERY_VALUE = 1, .SET_VALUE = 1 }, &key);
    if (err != .NO_ERROR) msgboxExit("Couldn't open your environment variables: {f}", .{err});
    return key.?;
}

fn readPath(key: win32.HKEY, v: *PathValue) void {
    var size: u32 = @sizeOf(@TypeOf(v.buf));
    switch (win32.RegQueryValueExW(key, win32.L("Path"), null, &v.kind, @ptrCast(&v.buf), &size)) {
        .NO_ERROR => {},
        .ERROR_FILE_NOT_FOUND => {
            v.* = .{ .kind = .EXPAND_SZ, .buf = undefined, .len = 0 };
            return;
        },
        else => |e| msgboxExit("Couldn't read your PATH: {f}", .{e}),
    }
    v.len = size / 2;
    while (v.len > 0 and v.buf[v.len - 1] == 0) v.len -= 1;
}

fn writePath(key: win32.HKEY, kind: win32.REG_VALUE_TYPE, text: []const u16, buf: *[max_env_len + 1]u16) void {
    if (text.len > max_env_len) msgboxExit("Your PATH would be longer than Windows allows, so the command line isn't added to it.", .{});
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;
    const err = win32.RegSetValueExW(key, win32.L("Path"), 0, kind, @ptrCast(buf), @intCast((text.len + 1) * 2));
    if (err != .NO_ERROR) msgboxExit("Couldn't change your PATH: {f}", .{err});
    // So new consoles (started by Explorer) get it without signing out.
    const hwnd_broadcast: win32.HWND = @ptrFromInt(0xffff); // missing from zigwin32
    if (0 == win32.SendMessageTimeoutW(hwnd_broadcast, win32.WM_SETTINGCHANGE, 0, @bitCast(@intFromPtr(win32.L("Environment"))), .{ .ABORTIFHUNG = 1 }, 5000, null)) switch (win32.GetLastError()) {
        // A program too busy to answer: it sees the change next time it reads the environment.
        .ERROR_TIMEOUT => {},
        else => |e| msgboxExit("Couldn't tell Windows the PATH changed: {f}", .{e}),
    };
}

fn pathEntries(text: []const u16) std.mem.SplitIterator(u16, .scalar) {
    return std.mem.splitScalar(u16, text, ';');
}

fn addToPath(bin: *const Path) void {
    const key = openEnvironment();
    defer closeKey(key);
    var current: PathValue = undefined;
    readPath(key, &current);
    var it = pathEntries(current.text());
    while (it.next()) |entry| if (bin.eqlIgnoreCaseSlice(entry)) return;
    var buf: [max_env_len + 1]u16 = undefined;
    const sep: []const u16 = if (current.len == 0) &.{} else win32.L(";");
    const len = current.len + sep.len + bin.len;
    if (len > max_env_len) msgboxExit("Your PATH would be longer than Windows allows, so the command line isn't added to it.", .{});
    var joined: [max_env_len]u16 = undefined;
    @memcpy(joined[0..current.len], current.text());
    @memcpy(joined[current.len..][0..sep.len], sep);
    @memcpy(joined[current.len + sep.len ..][0..bin.len], bin.slice());
    writePath(key, current.kind, joined[0..len], &buf);
}

fn removeFromPath(bin: *const Path) void {
    const key = openEnvironment();
    defer closeKey(key);
    var current: PathValue = undefined;
    readPath(key, &current);
    var kept: [max_env_len]u16 = undefined;
    var len: usize = 0;
    var found = false;
    var it = pathEntries(current.text());
    while (it.next()) |entry| {
        if (bin.eqlIgnoreCaseSlice(entry)) {
            found = true;
            continue;
        }
        // Fits: no longer than what it came from.
        if (len > 0) {
            kept[len] = ';';
            len += 1;
        }
        @memcpy(kept[len..][0..entry.len], entry);
        len += entry.len;
    }
    if (!found) return;
    var buf: [max_env_len + 1]u16 = undefined;
    writePath(key, current.kind, kept[0..len], &buf);
}

fn shortcutPath() Path {
    return Path.known(&win32.FOLDERID_Programs).join("Black Box.lnk");
}

fn writeShortcut(dir: *const Path, exe: *const Path) void {
    {
        const hr = win32.CoInitializeEx(null, win32.COINIT_APARTMENTTHREADED);
        if (hr.failed) win32.panicHresult("CoInitializeEx", hr);
    }
    defer win32.CoUninitialize();
    var link: *win32.IShellLinkW = undefined;
    {
        const hr = win32.CoCreateInstance(win32.CLSID_ShellLink, null, win32.CLSCTX_INPROC_SERVER, win32.IID_IShellLinkW, @ptrCast(&link));
        if (hr.failed) win32.panicHresult("CoCreateInstance(ShellLink)", hr);
    }
    defer _ = link.IUnknown.Release();
    for ([_]struct { []const u8, win32.HRESULT }{
        .{ "SetPath", link.SetPath(exe.z()) },
        .{ "SetWorkingDirectory", link.SetWorkingDirectory(dir.z()) },
        .{ "SetIconLocation", link.SetIconLocation(exe.z(), 0) },
    }) |call| if (call[1].failed) msgboxExit("Couldn't make the Start Menu shortcut ({s}): {f}", .{ call[0], call[1] });
    var file: *win32.IPersistFile = undefined;
    {
        const hr = link.IUnknown.QueryInterface(win32.IID_IPersistFile, @ptrCast(&file));
        if (hr.failed) win32.panicHresult("QueryInterface(IPersistFile)", hr);
    }
    defer _ = file.IUnknown.Release();
    const path = shortcutPath();
    const hr = file.Save(path.z(), 1);
    if (hr.failed) msgboxExit("Couldn't save the Start Menu shortcut {f}: hresult {f}", .{ path.fmt(), hr });
}

fn writeUninstallKey(dir: *const Path, exe: *const Path, uninstaller: *const Path, bytes: u64) void {
    var key: ?win32.HKEY = null;
    const err = win32.RegCreateKeyExW(win32.HKEY_CURRENT_USER, uninstall_key, 0, null, .{}, .{ .SET_VALUE = 1 }, null, &key, null);
    if (err != .NO_ERROR) msgboxExit("Couldn't add Black Box to the installed apps: {f}", .{err});
    defer closeKey(key.?);
    setString(key.?, win32.L("DisplayName"), win32.L("Black Box"));
    setString(key.?, win32.L("InstallLocation"), dir.slice());
    setString(key.?, win32.L("DisplayIcon"), exe.slice());
    setString(key.?, win32.L("UninstallString"), uninstaller.quoted().slice());
    setDword(key.?, win32.L("NoModify"), 1);
    setDword(key.?, win32.L("NoRepair"), 1);
    setDword(key.?, win32.L("EstimatedSize"), @intCast(bytes / 1024));
}

fn setString(key: win32.HKEY, name: [:0]const u16, value: []const u16) void {
    var buf: [win32.MAX_PATH + 3]u16 = undefined;
    @memcpy(buf[0..value.len], value);
    buf[value.len] = 0;
    const err = win32.RegSetValueExW(key, name, 0, .SZ, @ptrCast(&buf), @intCast((value.len + 1) * 2));
    if (err != .NO_ERROR) msgboxExit("Couldn't add Black Box to the installed apps: {f}", .{err});
}

fn setDword(key: win32.HKEY, name: [:0]const u16, value: u32) void {
    const err = win32.RegSetValueExW(key, name, 0, .DWORD, @ptrCast(&value), 4);
    if (err != .NO_ERROR) msgboxExit("Couldn't add Black Box to the installed apps: {f}", .{err});
}

/// At most MAX_PATH long: what CreateFileW and the rest take without a \\?\ prefix.
const Path = struct {
    buf: [win32.MAX_PATH + 1]u16 = undefined,
    len: usize = 0,

    fn from(s: []const u16) Path {
        var p: Path = .{};
        p.append(s);
        return p;
    }

    fn known(id: *const win32.Guid) Path {
        var folder: ?[*:0]u16 = null;
        const hr = win32.SHGetKnownFolderPath(id, .DEFAULT, null, &folder);
        if (hr.failed) win32.panicHresult("SHGetKnownFolderPath", hr);
        defer win32.CoTaskMemFree(folder);
        return .from(std.mem.span(folder.?));
    }

    fn temp() Path {
        var p: Path = .{};
        const n = win32.GetTempPathW(p.buf.len, @ptrCast(&p.buf));
        if (n == 0) win32.panicWin32("GetTempPath", win32.GetLastError());
        if (n >= p.buf.len) msgboxExit("The TEMP folder's path is longer than Windows allows.", .{});
        // It ends with a backslash, which join adds.
        p.len = n - 1;
        p.buf[p.len] = 0;
        return p;
    }

    fn join(p: *const Path, comptime rel: []const u8) Path {
        return p.join2("\\" ++ rel);
    }

    fn join2(p: *const Path, comptime suffix: []const u8) Path {
        var r = p.*;
        r.append(win32.L(suffix));
        return r;
    }

    fn quoted(p: *const Path) Path {
        var r: Path = .{};
        r.append(win32.L("\""));
        r.append(p.slice());
        r.append(win32.L("\""));
        return r;
    }

    fn append(p: *Path, s: []const u16) void {
        if (p.len + s.len > win32.MAX_PATH) msgboxExit("The path {f}{f} is longer than Windows allows.", .{ p.fmt(), std.unicode.fmtUtf16Le(s) });
        @memcpy(p.buf[p.len..][0..s.len], s);
        p.len += s.len;
        p.buf[p.len] = 0;
    }

    fn slice(p: *const Path) []const u16 {
        return p.buf[0..p.len];
    }

    fn z(p: *const Path) [*:0]const u16 {
        return p.buf[0..p.len :0];
    }

    fn fmt(p: *const Path) @TypeOf(std.unicode.fmtUtf16Le(&.{})) {
        return std.unicode.fmtUtf16Le(p.slice());
    }

    fn eqlIgnoreCase(p: *const Path, other: *const Path) bool {
        return p.eqlIgnoreCaseSlice(other.slice());
    }

    fn eqlIgnoreCaseSlice(p: *const Path, other: []const u16) bool {
        return other.len == p.len and p.startsWithIgnoreCaseSlice(other);
    }

    fn startsWithIgnoreCase(p: *const Path, dir: *const Path) bool {
        return p.len >= dir.len and dir.startsWithIgnoreCaseSlice(p.buf[0..dir.len]) and
            (p.len == dir.len or p.buf[dir.len] == '\\');
    }

    /// Ignoring case the way Windows' file names do.
    fn startsWithIgnoreCaseSlice(p: *const Path, prefix: []const u16) bool {
        if (prefix.len > p.len) return false;
        return switch (win32.CompareStringOrdinal(@ptrCast(p.buf[0..prefix.len].ptr), @intCast(prefix.len), @ptrCast(prefix.ptr), @intCast(prefix.len), 1)) {
            0 => win32.panicWin32("CompareStringOrdinal", win32.GetLastError()),
            2 => true, // CSTR_EQUAL
            else => false,
        };
    }
};

fn selfPath() Path {
    var p: Path = .{};
    const n = win32.GetModuleFileNameW(null, @ptrCast(&p.buf), p.buf.len);
    if (n == 0) win32.panicWin32("GetModuleFileName", win32.GetLastError());
    if (n >= p.buf.len) msgboxExit("The installer's path is longer than Windows allows.", .{});
    p.len = n;
    p.buf[n] = 0;
    return p;
}

fn message(style: win32.MESSAGEBOX_STYLE, comptime fmt: []const u8, args: anytype) win32.MESSAGEBOX_RESULT {
    var utf8: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&utf8);
    // Too long, it's cut short, at a whole character (WTF-8: an argument may be).
    w.print(fmt, args) catch {};
    var text = w.buffered();
    while (!std.unicode.wtf8ValidateSlice(text)) text = text[0 .. text.len - 1];
    var wide: [utf8.len:0]u16 = undefined;
    const n = std.unicode.wtf8ToWtf16Le(&wide, text) catch unreachable; // validated
    wide[n] = 0;
    const answer = win32.MessageBoxW(null, &wide, win32.L("Black Box Installer"), style);
    // Not msgboxExit, which needs a message box: a panic writes the crash report instead.
    if (@backingInt(answer) == 0) win32.panicWin32("MessageBox", win32.GetLastError());
    return answer;
}

fn msgboxExit(comptime fmt: []const u8, args: anytype) noreturn {
    _ = message(.{ .ICONHAND = 1 }, fmt, args);
    win32.ExitProcess(1);
}

const std = @import("std");
const win32 = @import("win32").everything;
const wintrace = @import("wintrace");
const builtin = @import("builtin");
const payload = @import("payload.zig");
