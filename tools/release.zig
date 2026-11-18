//! `zig build release`: releases master's head, as a draft. GitHub's release workflow
//! (.github/workflows/release.yml) builds and publishes it, on a clean runner; this checks
//! the commit is the one you have and is pushed, starts the workflow, waits for it, and says
//! where the draft is and how to try, publish or throw it away. Needs git, and the GitHub CLI
//! (gh) logged in.

const usage =
    \\usage: release REPOSITORY [--dry-run]
    \\  --dry-run   check, and say what it would do, without starting the workflow
    \\
;

pub fn main(init: std.process.Init.Minimal) !u8 {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer if (debug_allocator.deinit() == .leak) std.debug.panic("release leaked memory", .{});
    const gpa = debug_allocator.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{ .environ = init.environ, .argv0 = .init(init.args) });
    defer threaded.deinit();
    const io = threaded.io();

    var args = try init.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip();
    const root = args.next() orelse {
        std.debug.print(usage, .{});
        return 1;
    };
    var dry_run = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else {
            std.debug.print("release: unknown argument '{s}'\n\n" ++ usage, .{arg});
            return 1;
        }
    }
    const r: Runner = .{ .gpa = gpa, .io = io, .root = root };

    // What's released is master on GitHub: it must be what you have, all of it.
    const status = try r.output(&.{ "git", "status", "--porcelain", "--untracked-files=no" });
    defer gpa.free(status);
    if (status.len != 0) {
        std.debug.print("release: the working tree has changes (commit or stash them first):\n{s}\n", .{status});
        return 1;
    }
    try r.check(&.{ "git", "fetch", "--quiet", "origin", branch });
    const head = try r.output(&.{ "git", "rev-parse", "HEAD" });
    defer gpa.free(head);
    const remote = try r.output(&.{ "git", "rev-parse", "origin/" ++ branch });
    defer gpa.free(remote);
    if (!std.mem.eql(u8, head, remote)) {
        std.debug.print("release: HEAD ({s}) isn't origin/" ++ branch ++ " ({s}): release.yml releases what's on GitHub, so check out " ++ branch ++ " and push it first\n", .{ head[0..7], remote[0..7] });
        return 1;
    }

    // The tag the workflow makes (see release.yml): the commit's time and its hash.
    const committed = try r.output(&.{ "git", "show", "-s", "--format=%ct", "HEAD" });
    defer gpa.free(committed);
    const seconds = std.fmt.parseInt(u64, committed, 10) catch {
        std.debug.print("release: git gave a commit time that isn't one: '{s}'\n", .{committed});
        return 1;
    };
    var tag_buf: [32]u8 = undefined;
    const tag = releaseTag(&tag_buf, seconds, head[0..7]);

    switch (try r.releaseState(tag)) {
        .published => {
            std.debug.print("release: {s} is already published\n", .{tag});
            return 0;
        },
        .draft => std.debug.print("release: {s} has a draft already: the workflow replaces it\n", .{tag}),
        .none => {},
    }
    const start = [_][]const u8{ "gh", "workflow", "run", "release.yml", "--ref", branch };
    if (dry_run) {
        std.debug.print("release: would run 'gh workflow run release.yml --ref " ++ branch ++ "', making the draft {s}\n", .{tag});
        return 0;
    }
    try r.check(&start);
    std.debug.print("release: started the release workflow for {s}\n", .{head[0..7]});

    // Its run: the newest one for this commit, once GitHub lists it.
    const run_id = for (0..30) |_| {
        const list = try r.output(&.{ "gh", "run", "list", "--workflow", "release.yml", "--event", "workflow_dispatch", "--commit", head, "--limit", "1", "--json", "databaseId", "--jq", ".[0].databaseId // empty" });
        if (list.len != 0) break list;
        gpa.free(list);
        try io.sleep(.fromSeconds(2), .awake);
    } else {
        std.debug.print("release: GitHub doesn't list the run after a minute: see the repository's Actions tab\n", .{});
        return 1;
    };
    defer gpa.free(run_id);
    if (!try r.inherit(&.{ "gh", "run", "watch", run_id, "--exit-status" })) {
        std.debug.print("release: the release workflow failed: gh run view {s} --log-failed\n", .{run_id});
        return 1;
    }
    if (try r.releaseState(tag) != .draft) {
        std.debug.print("release: the workflow finished, but there's no draft {s}\n", .{tag});
        return 1;
    }
    const url = try r.output(&.{ "gh", "release", "view", tag, "--json", "url", "--jq", ".url" });
    defer gpa.free(url);
    std.debug.print(
        \\
        \\release: the draft {0s} is ready: {1s}
        \\
        \\Try it:     gh release download {0s} -D BlackBox-{0s}
        \\Publish it: gh release edit {0s} --draft=false --latest
        \\Or not:     gh release delete {0s} --yes
        \\
    , .{ tag, url });
    return 0;
}

const branch = "master";

/// The release's tag, as release.yml makes it: when the commit was made (UTC) and its hash,
/// e.g. 2026_11_17_10_42-8b271f7, so releases sort by date and each names its commit.
fn releaseTag(buf: *[32]u8, unix_seconds: u64, short: *const [7]u8) []const u8 {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = unix_seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day = epoch.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}_{d:0>2}_{d:0>2}_{d:0>2}_{d:0>2}-{s}", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        short,
    }) catch unreachable;
}

test releaseTag {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1970_01_01_00_00-0123abc", releaseTag(&buf, 0, "0123abc"));
    try std.testing.expectEqualStrings("2000_02_29_12_00-8b271f7", releaseTag(&buf, 951825600, "8b271f7"));
}

/// Runs git and gh in the repository.
const Runner = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,

    /// The command's output, trimmed: it must succeed. Allocated.
    fn output(r: Runner, argv: []const []const u8) ![]u8 {
        const result = try r.run(argv);
        defer r.gpa.free(result.stderr);
        errdefer r.gpa.free(result.stdout);
        if (!result.term.success()) {
            std.debug.print("release: '{s}' failed: {any}\n{s}", .{ argv[0], result.term, result.stderr });
            return error.CommandFailed;
        }
        const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
        std.mem.copyForwards(u8, result.stdout, trimmed);
        return r.gpa.realloc(result.stdout, trimmed.len);
    }

    /// The command, which must succeed, its output not needed.
    fn check(r: Runner, argv: []const []const u8) !void {
        r.gpa.free(try r.output(argv));
    }

    /// The command with our stdout and stderr (to watch it): whether it succeeded.
    fn inherit(r: Runner, argv: []const []const u8) !bool {
        var child = std.process.spawn(r.io, .{ .argv = argv, .cwd = .{ .path = r.root } }) catch |err| {
            std.debug.print("release: running '{s}' failed: {t}\n", .{ argv[0], err });
            return err;
        };
        return (try child.wait(r.io)).success();
    }

    fn run(r: Runner, argv: []const []const u8) !std.process.RunResult {
        return std.process.run(r.gpa, r.io, .{ .argv = argv, .cwd = .{ .path = r.root } }) catch |err| {
            std.debug.print("release: running '{s}' failed: {t} (is it installed{s}?)\n", .{ argv[0], err, if (std.mem.eql(u8, argv[0], "gh")) ", and logged in" else "" });
            return err;
        };
    }

    /// Whether `tag` is released: published, a draft, or neither.
    fn releaseState(r: Runner, tag: []const u8) !enum { none, draft, published } {
        const result = try r.run(&.{ "gh", "release", "view", tag, "--json", "isDraft", "--jq", ".isDraft" });
        defer r.gpa.free(result.stdout);
        defer r.gpa.free(result.stderr);
        if (result.term.success()) {
            const is_draft = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
            return if (std.mem.eql(u8, is_draft, "true")) .draft else .published;
        }
        if (std.mem.indexOf(u8, result.stderr, "release not found") != null) return .none;
        std.debug.print("release: 'gh release view {s}' failed: {s}", .{ tag, result.stderr });
        return error.CommandFailed;
    }
};

const std = @import("std");
