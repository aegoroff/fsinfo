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

const queue_slots_per_job: usize = 64;

fn cloneDir(io: std.Io, dir: std.Io.Dir) !std.Io.Dir {
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
    not_full: std.Io.Condition = .init,
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
        const job = self.items.pop().?;
        self.not_full.signal(io);
        return job;
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
};

fn submitDir(ctx: *WalkCtx, job: DirJob) void {
    _ = ctx.queue.pending.fetchAdd(1, .monotonic);
    if (ctx.queue.tryPush(ctx.io, job)) return;
    // Queue full: process inline so workers never all block on push.
    processDir(ctx, job);
}

fn processDir(ctx: *WalkCtx, job: DirJob) void {
    defer {
        job.deinit(ctx.io, ctx.gpa);
        ctx.queue.markDone(ctx.io);
    }

    var it = job.dir.iterate();
    while (true) {
        const entry_or_null = it.next(ctx.io) catch {
            continue;
        };
        const entry = entry_or_null orelse break;

        switch (entry.kind) {
            .file => {
                const stat = job.dir.statFile(ctx.io, entry.name, .{ .follow_symlinks = false }) catch {
                    continue;
                };
                ctx.rep.addFile(stat.size);
            },
            .directory => {
                const child_path = joinRelPath(ctx.gpa, job.rel_path, entry.name) catch {
                    continue;
                };
                if (ctx.exclusions.probe(child_path)) {
                    ctx.gpa.free(child_path);
                    continue;
                }
                const child_dir = job.dir.openDir(ctx.io, entry.name, open_options) catch {
                    ctx.gpa.free(child_path);
                    continue;
                };
                ctx.rep.addDir();
                submitDir(ctx, .{ .dir = child_dir, .rel_path = child_path });
            },
            else => {},
        }
        ctx.rep.maybeRefreshProgress();
    }
}

fn dirWorker(ctx: *WalkCtx) void {
    while (true) {
        const job = ctx.queue.popWait(ctx.io) orelse return;
        processDir(ctx, job);
    }
}

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
        const entry_or_null = walker.next(io) catch {
            continue;
        };
        const entry = entry_or_null orelse break;
        if (exclusions.probe(entry.path)) {
            continue;
        }
        if (entry.kind == .directory) {
            walker.enter(io, entry) catch {
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
) std.mem.Allocator.Error!void {
    try walkWithVisitor(io, gpa, dir, exclusions, rep, reportEntry);
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
) (std.mem.Allocator.Error || std.Io.Cancelable || std.Io.ConcurrentError || std.Io.UnexpectedError)!void {
    std.debug.assert(jobs >= 2);

    var queue: DirQueue = .{
        .capacity = jobs * queue_slots_per_job,
        .gpa = gpa,
    };
    defer queue.deinit(io);

    var ctx: WalkCtx = .{
        .io = io,
        .gpa = gpa,
        .exclusions = exclusions,
        .rep = rep,
        .queue = &queue,
    };

    var root_dir: ?std.Io.Dir = try cloneDir(io, dir);
    errdefer if (root_dir) |d| d.close(io);
    var root_path: ?[]u8 = try gpa.alloc(u8, 0);
    errdefer if (root_path) |p| gpa.free(p);

    submitDir(&ctx, .{ .dir = root_dir.?, .rel_path = root_path.? });
    root_dir = null;
    root_path = null;

    var group: std.Io.Group = .init;
    errdefer group.cancel(io);

    for (0..jobs) |_| {
        try group.concurrent(io, dirWorker, .{&ctx});
    }
    try group.await(io);
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

    try walkWithVisitor(io, std.testing.allocator, tmp.dir, exclusions, &seen, Seen.onEntry);

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

    try walkWithVisitor(io, std.testing.allocator, tmp.dir, exclusions, &seen, Seen.onEntry);

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
    try tmp.dir.symLink(io, "real", "link", .{ .is_directory = true });

    const exclusions = lib.Exclusions{
        .haystack = &[_][]const u8{"/proc"},
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
    try walkWithVisitor(io, std.testing.allocator, tmp.dir, exclusions, &serial, SerialTotals.onEntry);

    var parallel_rep = reporter.Reporter.init(io);
    try walkParallel(io, std.testing.allocator, tmp.dir, exclusions, &parallel_rep, 2);
    const parallel_files = parallel_rep.fileCount();
    const parallel_dirs = parallel_rep.dirCount();
    const parallel_bytes = parallel_rep.byteCount();
    parallel_rep.directories_progress.end();
    parallel_rep.files_progress.end();
    parallel_rep.progress.end();

    try std.testing.expectEqual(serial.files, parallel_files);
    try std.testing.expectEqual(serial.dirs, parallel_dirs);
    try std.testing.expectEqual(serial.bytes, parallel_bytes);
    // keep/, a/, a/b/, real/ — not proc/, not via link/
    try std.testing.expectEqual(@as(u64, 4), serial.files);
    try std.testing.expectEqual(@as(u64, 3), serial.dirs);
    try std.testing.expectEqual(@as(u64, 4 + 2 + 3 + 1), serial.bytes);
}
