const std = @import("std");
const builtin = @import("builtin");
const lib = @import("lib.zig");
const reporter = @import("reporter.zig");

pub const open_options: std.Io.Dir.OpenOptions = .{
    .iterate = true,
    .follow_symlinks = false,
};

pub const default_exclusion_paths = [_][]const u8{ "/proc", "/dev", "/sys" };

pub const default_exclusions = lib.Exclusions{
    .haystack = &default_exclusion_paths,
};

/// Exclusion list = built-in pseudo-FS paths plus every `tmpfs` mount point
/// discovered from `/proc/self/mountinfo` on Linux (e.g. `/run`, `/tmp`).
/// Path strings live in `arena`.
pub fn buildExclusions(arena: std.mem.Allocator, io: std.Io) std.mem.Allocator.Error!lib.Exclusions {
    var list: std.ArrayList([]const u8) = .empty;
    try list.appendSlice(arena, &default_exclusion_paths);
    if (builtin.os.tag == .linux) {
        appendTmpfsMountPoints(arena, io, &list) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };
    }
    return .{ .haystack = try list.toOwnedSlice(arena) };
}

fn appendTmpfsMountPoints(
    arena: std.mem.Allocator,
    io: std.Io,
    list: *std.ArrayList([]const u8),
) !void {
    // `/proc` files report size 0; positional reads return empty — use streaming.
    var file = try std.Io.Dir.cwd().openFile(io, "/proc/self/mountinfo", .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var file_reader = file.readerStreaming(io, &buffer);
    const content = file_reader.interface.allocRemaining(arena, .limited(1024 * 1024)) catch |err| switch (err) {
        error.ReadFailed => return file_reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
    try appendTmpfsMountPointsFrom(arena, content, list);
}

fn appendTmpfsMountPointsFrom(
    arena: std.mem.Allocator,
    content: []const u8,
    list: *std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const dash = std.mem.indexOf(u8, line, " - ") orelse continue;
        var right = std.mem.tokenizeScalar(u8, line[dash + 3 ..], ' ');
        const fstype = right.next() orelse continue;
        if (!std.mem.eql(u8, fstype, "tmpfs")) continue;

        var left = std.mem.tokenizeScalar(u8, line[0..dash], ' ');
        _ = left.next(); // mount id
        _ = left.next(); // parent id
        _ = left.next(); // major:minor
        _ = left.next(); // root within filesystem
        const mount_point_esc = left.next() orelse continue;
        const mount_point = try unescapeMountPath(arena, mount_point_esc);
        try list.append(arena, mount_point);
    }
}

fn unescapeMountPath(arena: std.mem.Allocator, escaped: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    var i: usize = 0;
    while (i < escaped.len) {
        if (escaped[i] == '\\' and i + 3 < escaped.len) {
            const d0 = escaped[i + 1];
            const d1 = escaped[i + 2];
            const d2 = escaped[i + 3];
            if (d0 >= '0' and d0 <= '7' and d1 >= '0' and d1 <= '7' and d2 >= '0' and d2 <= '7') {
                const value: u8 = @intCast((d0 - '0') * 64 + (d1 - '0') * 8 + (d2 - '0'));
                try out.append(arena, value);
                i += 4;
                continue;
            }
        }
        try out.append(arena, escaped[i]);
        i += 1;
    }
    return try out.toOwnedSlice(arena);
}

/// Rejects a scan when the opened root resolves to an excluded path
/// (e.g. `fsinfo /proc`, or a tmpfs mount like `fsinfo /run`).
pub fn ensureRootAllowed(
    io: std.Io,
    dir: std.Io.Dir,
    exclusions: lib.Exclusions,
) (std.Io.Dir.RealPathError || error{PathExcluded})!void {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try dir.realPath(io, &buf);
    if (exclusions.probe(buf[0..n])) return error.PathExcluded;
}

const queue_slots_per_job: usize = 64;

fn cloneDir(io: std.Io, dir: std.Io.Dir) std.Io.Dir.OpenError!std.Io.Dir {
    if (builtin.os.tag == .windows) {
        return dir.openDir(io, ".", open_options);
    } else {
        const fd = std.c.dup(dir.handle);
        if (fd < 0) return error.Unexpected;
        return .{ .handle = fd };
    }
}

fn joinRelPath(gpa: std.mem.Allocator, parent: []const u8, name: []const u8) std.mem.Allocator.Error![]u8 {
    if (parent.len == 0) return gpa.dupe(u8, name);
    const out = try gpa.alloc(u8, parent.len + 1 + name.len);
    @memcpy(out[0..parent.len], parent);
    out[parent.len] = std.fs.path.sep;
    @memcpy(out[parent.len + 1 ..][0..name.len], name);
    return out;
}

fn logSkip(verbose: bool, comptime what: []const u8, path: []const u8, err: anyerror) void {
    if (!verbose) return;
    if (path.len == 0) {
        std.log.warn("skip {s}: {s}", .{ what, @errorName(err) });
    } else {
        std.log.warn("skip {s} {s}: {s}", .{ what, path, @errorName(err) });
    }
}

const DirJob = struct {
    dir: std.Io.Dir,
    /// Relative path from the scan root; empty for the root job itself.
    rel_path: []u8,

    fn deinit(self: DirJob, io: std.Io, gpa: std.mem.Allocator) void {
        self.dir.close(io);
        gpa.free(self.rel_path);
    }
};

const DirQueue = struct {
    mutex: std.Io.Mutex = .init,
    not_empty: std.Io.Condition = .init,
    items: std.ArrayList(DirJob) = .empty,
    capacity: usize,
    /// Directories pushed that have not finished `processDir` yet.
    pending: std.atomic.Value(usize) = .init(0),
    gpa: std.mem.Allocator,

    fn deinit(self: *DirQueue, io: std.Io) void {
        for (self.items.items) |job| {
            job.deinit(io, self.gpa);
        }
        self.items.deinit(self.gpa);
    }

    fn tryPush(self: *DirQueue, io: std.Io, job: DirJob) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.items.items.len >= self.capacity) return false;
        self.items.append(self.gpa, job) catch return false;
        self.not_empty.signal(io);
        return true;
    }

    fn popWait(self: *DirQueue, io: std.Io) ?DirJob {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        while (self.items.items.len == 0) {
            if (self.pending.load(.acquire) == 0) return null;
            self.not_empty.waitUncancelable(io, &self.mutex);
        }
        return self.items.pop().?;
    }

    fn markDone(self: *DirQueue, io: std.Io) void {
        if (self.pending.fetchSub(1, .acq_rel) == 1) {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.not_empty.broadcast(io);
        }
    }
};

const WalkCtx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    exclusions: lib.Exclusions,
    rep: *reporter.Reporter,
    queue: *DirQueue,
    verbose: bool,

    /// Enqueue `job`, or park it on `overflow` when the shared queue is full.
    /// Without an overflow list (initial root submit), falls back to iterative `processDir`.
    fn submitDir(self: *WalkCtx, job: DirJob, overflow: ?*std.ArrayList(DirJob)) void {
        _ = self.queue.pending.fetchAdd(1, .monotonic);
        if (self.queue.tryPush(self.io, job)) return;
        if (overflow) |o| {
            o.append(self.gpa, job) catch |err| {
                // Overflow list OOM: still make progress without blocking all workers.
                logSkip(self.verbose, "overflow enqueue", job.rel_path, err);
                self.processDir(job);
            };
            return;
        }
        self.processDir(job);
    }

    /// Process `job` and any jobs that could not fit on the shared queue, iteratively
    /// (no recursive `processDir` on queue-full — avoids stack overflow on wide trees).
    fn processDir(self: *WalkCtx, job: DirJob) void {
        var overflow: std.ArrayList(DirJob) = .empty;
        defer {
            for (overflow.items) |leftover| {
                leftover.deinit(self.io, self.gpa);
                self.queue.markDone(self.io);
            }
            overflow.deinit(self.gpa);
        }

        var current: ?DirJob = job;
        while (current) |j| {
            self.processDirOne(j, &overflow);
            current = overflow.pop();
        }
    }

    fn processDirOne(self: *WalkCtx, job: DirJob, overflow: *std.ArrayList(DirJob)) void {
        defer {
            job.deinit(self.io, self.gpa);
            self.queue.markDone(self.io);
        }

        var it = job.dir.iterate();
        while (true) {
            const entry_or_null = it.next(self.io) catch |err| {
                logSkip(self.verbose, "readdir", job.rel_path, err);
                continue;
            };
            const entry = entry_or_null orelse break;

            const child_path = joinRelPath(self.gpa, job.rel_path, entry.name) catch |err| {
                logSkip(self.verbose, "join path", entry.name, err);
                continue;
            };
            if (self.exclusions.probe(child_path)) {
                self.gpa.free(child_path);
                continue;
            }

            switch (entry.kind) {
                .file => {
                    defer self.gpa.free(child_path);
                    const stat = job.dir.statFile(self.io, entry.name, .{ .follow_symlinks = false }) catch |err| {
                        logSkip(self.verbose, "statFile", child_path, err);
                        continue;
                    };
                    self.rep.addFile(stat.size);
                },
                .directory => {
                    const child_dir = job.dir.openDir(self.io, entry.name, open_options) catch |err| {
                        logSkip(self.verbose, "openDir", child_path, err);
                        self.gpa.free(child_path);
                        continue;
                    };
                    self.rep.addDir();
                    self.submitDir(.{ .dir = child_dir, .rel_path = child_path }, overflow);
                },
                else => {
                    self.gpa.free(child_path);
                },
            }
            self.rep.maybeRefreshProgress();
        }
    }

    fn worker(self: *WalkCtx) void {
        while (true) {
            const job = self.queue.popWait(self.io) orelse return;
            self.processDir(job);
        }
    }
};

/// Selective walk: only descend into directories that are not excluded.
/// Plain `walk` enters every directory before returning the entry, so
/// skipping an excluded path with `continue` would still traverse children.
/// Directory symlinks are typically reported as `.sym_link` and are not entered.
pub fn walkWithVisitor(
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: std.Io.Dir,
    exclusions: lib.Exclusions,
    context: anytype,
    comptime onEntry: fn (@TypeOf(context), *const std.Io.Dir.Walker.Entry) void,
    verbose: bool,
) std.mem.Allocator.Error!void {
    var walker = try dir.walkSelectively(gpa);
    defer {
        // `deinit` does not close nested dir FDs left on the stack (e.g. early abort).
        while (walker.stack.items.len > 0) {
            walker.leave(io);
        }
        walker.deinit();
    }

    while (true) {
        const entry_or_null = walker.next(io) catch |err| {
            logSkip(verbose, "walker.next", "", err);
            continue;
        };
        const entry = entry_or_null orelse break;
        if (exclusions.probe(entry.path)) {
            continue;
        }
        if (entry.kind == .directory) {
            walker.enter(io, entry) catch |err| {
                logSkip(verbose, "enter", entry.path, err);
                continue;
            };
        }
        onEntry(context, &entry);
    }
}

fn reportEntry(rep: *reporter.Reporter, entry: *const std.Io.Dir.Walker.Entry) void {
    rep.update(entry);
}

pub fn walk(
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: std.Io.Dir,
    exclusions: lib.Exclusions,
    rep: *reporter.Reporter,
    verbose: bool,
) std.mem.Allocator.Error!void {
    try walkWithVisitor(io, gpa, dir, exclusions, rep, reportEntry, verbose);
}

/// Parallel directory walk via a shared work queue of owning directory FDs.
/// `jobs` must be >= 2; use `walk` for the single-threaded path.
pub fn walkParallel(
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: std.Io.Dir,
    exclusions: lib.Exclusions,
    rep: *reporter.Reporter,
    jobs: usize,
    verbose: bool,
) (std.mem.Allocator.Error || std.Io.ConcurrentError || std.Io.Dir.OpenError)!void {
    std.debug.assert(jobs >= 2);

    const capacity = std.math.mul(usize, jobs, queue_slots_per_job) catch {
        return error.OutOfMemory;
    };
    var queue: DirQueue = .{
        .capacity = capacity,
        .gpa = gpa,
    };
    defer queue.deinit(io);

    var ctx: WalkCtx = .{
        .io = io,
        .gpa = gpa,
        .exclusions = exclusions,
        .rep = rep,
        .queue = &queue,
        .verbose = verbose,
    };

    var root_dir: ?std.Io.Dir = try cloneDir(io, dir);
    errdefer if (root_dir) |d| d.close(io);
    var root_path: ?[]u8 = try gpa.alloc(u8, 0);
    errdefer if (root_path) |p| gpa.free(p);

    ctx.submitDir(.{ .dir = root_dir.?, .rel_path = root_path.? }, null);
    root_dir = null;
    root_path = null;

    var group: std.Io.Group = .init;
    errdefer group.cancel(io);

    for (0..jobs) |_| {
        try group.concurrent(io, WalkCtx.worker, .{&ctx});
    }
    try group.await(io);
}

test "ensureRootAllowed rejects excluded absolute roots" {
    if (builtin.os.tag != .linux) return;
    const io = std.testing.io;

    var proc_dir = std.Io.Dir.cwd().openDir(io, "/proc", open_options) catch return;
    defer proc_dir.close(io);
    try std.testing.expectError(error.PathExcluded, ensureRootAllowed(io, proc_dir, default_exclusions));

    var proc_child = std.Io.Dir.cwd().openDir(io, "/proc/1", open_options) catch return;
    defer proc_child.close(io);
    try std.testing.expectError(error.PathExcluded, ensureRootAllowed(io, proc_child, default_exclusions));

    var usr_dir = try std.Io.Dir.cwd().openDir(io, "/usr", open_options);
    defer usr_dir.close(io);
    try ensureRootAllowed(io, usr_dir, default_exclusions);
}

test "unescapeMountPath decodes octal escapes" {
    const path = try unescapeMountPath(std.testing.allocator, "/run/with\\040space");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/run/with space", path);
}

test "appendTmpfsMountPointsFrom collects tmpfs targets" {
    const sample =
        \\24 1 0:22 / /run rw,nosuid - tmpfs tmpfs rw
        \\25 24 0:23 / /run/user/1000 rw - tmpfs tmpfs rw
        \\26 1 0:24 / /home rw - ext4 /dev/sda1 rw
        \\27 1 0:25 / /tmp rw - tmpfs tmpfs rw
        \\28 1 0:26 / /mnt/with\040space rw - tmpfs tmpfs rw
    ;
    var list: std.ArrayList([]const u8) = .empty;
    defer {
        for (list.items) |p| std.testing.allocator.free(p);
        list.deinit(std.testing.allocator);
    }
    try appendTmpfsMountPointsFrom(std.testing.allocator, sample, &list);

    try std.testing.expectEqual(@as(usize, 4), list.items.len);
    try std.testing.expectEqualStrings("/run", list.items[0]);
    try std.testing.expectEqualStrings("/run/user/1000", list.items[1]);
    try std.testing.expectEqualStrings("/tmp", list.items[2]);
    try std.testing.expectEqualStrings("/mnt/with space", list.items[3]);
}

test "buildExclusions includes Linux tmpfs mounts" {
    if (builtin.os.tag != .linux) return;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const exclusions = try buildExclusions(arena_state.allocator(), io);

    try std.testing.expect(exclusions.probe("/proc"));
    try std.testing.expect(exclusions.probe("/dev"));
    try std.testing.expect(exclusions.probe("/sys"));

    // Typical systemd hosts expose at least one of these as tmpfs.
    // Do not use `/dev/shm` here: it is already covered by the `/dev` prefix.
    try std.testing.expect(exclusions.probe("/run") or exclusions.probe("/tmp"));
}

test "selective walk does not descend into excluded directories" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .follow_symlinks = false });
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "keep", .default_dir);
    try tmp.dir.createDir(io, "proc", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "keep/a.txt", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "proc/secret.txt", .data = "secret" });

    const exclusions = lib.Exclusions{
        .haystack = &[_][]const u8{"/proc"},
    };

    const Seen = struct {
        keep_a: bool = false,
        proc: bool = false,
        secret: bool = false,

        fn onEntry(self: *@This(), entry: *const std.Io.Dir.Walker.Entry) void {
            if (std.mem.eql(u8, entry.path, "keep/a.txt")) self.keep_a = true;
            if (std.mem.eql(u8, entry.path, "proc")) self.proc = true;
            if (std.mem.eql(u8, entry.path, "proc/secret.txt")) self.secret = true;
        }
    };
    var seen: Seen = .{};

    try walkWithVisitor(io, std.testing.allocator, tmp.dir, exclusions, &seen, Seen.onEntry, false);

    try std.testing.expect(seen.keep_a);
    try std.testing.expect(!seen.proc);
    try std.testing.expect(!seen.secret);
}

test "selective walk does not descend through directory symlinks" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .follow_symlinks = false });
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "real", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "real/hidden.txt", .data = "x" });
    try tmp.dir.symLink(io, "real", "link", .{ .is_directory = true });

    const exclusions = lib.Exclusions{ .haystack = &.{} };

    const Seen = struct {
        hidden_via_link: bool = false,
        entered_link: bool = false,

        fn onEntry(self: *@This(), entry: *const std.Io.Dir.Walker.Entry) void {
            if (entry.kind == .directory and std.mem.eql(u8, entry.path, "link")) {
                self.entered_link = true;
            }
            if (std.mem.eql(u8, entry.path, "link/hidden.txt")) {
                self.hidden_via_link = true;
            }
        }
    };
    var seen: Seen = .{};

    try walkWithVisitor(io, std.testing.allocator, tmp.dir, exclusions, &seen, Seen.onEntry, false);

    try std.testing.expect(!seen.entered_link);
    try std.testing.expect(!seen.hidden_via_link);
}

test "openDir accepts relative and absolute scan roots" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .follow_symlinks = false });
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "sub", .default_dir);

    var relative = try tmp.dir.openDir(io, "sub", open_options);
    defer relative.close(io);

    var dot = try tmp.dir.openDir(io, ".", open_options);
    defer dot.close(io);
}

test "parallel walk matches serial totals" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true, .follow_symlinks = false });
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "a", .default_dir);
    try tmp.dir.createDir(io, "a/b", .default_dir);
    try tmp.dir.createDir(io, "proc", .default_dir);
    try tmp.dir.createDir(io, "real", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "root.txt", .data = "root" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a/x.txt", .data = "xx" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a/b/y.txt", .data = "yyy" });
    try tmp.dir.writeFile(io, .{ .sub_path = "proc/secret.txt", .data = "nope" });
    try tmp.dir.writeFile(io, .{ .sub_path = "real/hidden.txt", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ignored.txt", .data = "skip" });
    try tmp.dir.symLink(io, "real", "link", .{ .is_directory = true });

    const exclusions = lib.Exclusions{
        .haystack = &[_][]const u8{ "/proc", "/ignored.txt" },
    };

    // Avoid a second `Reporter`/`Progress.start` in the same process: count serial via visitor.
    const SerialTotals = struct {
        io: std.Io,
        files: u64 = 0,
        dirs: u64 = 0,
        bytes: u64 = 0,

        fn onEntry(self: *@This(), entry: *const std.Io.Dir.Walker.Entry) void {
            switch (entry.kind) {
                .file => {
                    const stat = entry.dir.statFile(self.io, entry.basename, .{ .follow_symlinks = false }) catch return;
                    self.files += 1;
                    self.bytes += stat.size;
                },
                .directory => self.dirs += 1,
                else => {},
            }
        }
    };
    var serial: SerialTotals = .{ .io = io };
    try walkWithVisitor(io, std.testing.allocator, tmp.dir, exclusions, &serial, SerialTotals.onEntry, false);

    var parallel_rep = reporter.Reporter.init(io, false);
    try walkParallel(io, std.testing.allocator, tmp.dir, exclusions, &parallel_rep, 2, false);
    const parallel_files = parallel_rep.fileCount();
    const parallel_dirs = parallel_rep.dirCount();
    const parallel_bytes = parallel_rep.byteCount();
    parallel_rep.directories_progress.end();
    parallel_rep.files_progress.end();
    parallel_rep.progress.end();

    try std.testing.expectEqual(serial.files, parallel_files);
    try std.testing.expectEqual(serial.dirs, parallel_dirs);
    try std.testing.expectEqual(serial.bytes, parallel_bytes);
    // a/, a/b/, real/ — not proc/, not via link/; ignored.txt excluded as a file
    try std.testing.expectEqual(@as(u64, 4), serial.files);
    try std.testing.expectEqual(@as(u64, 3), serial.dirs);
    try std.testing.expectEqual(@as(u64, 4 + 2 + 3 + 1), serial.bytes);
}
