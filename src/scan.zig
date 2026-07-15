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

fn parentPathOf(path: []const u8, basename: []const u8) []const u8 {
    if (path.len == basename.len) return path[0..0];
    // Walker builds `dir/basename`; drop the separator before basename.
    return path[0 .. path.len - basename.len - 1];
}

test "parentPathOf strips basename" {
    try std.testing.expectEqualStrings("", parentPathOf("file.txt", "file.txt"));
    try std.testing.expectEqualStrings("a", parentPathOf("a/b", "b"));
    try std.testing.expectEqualStrings("a/b", parentPathOf("a/b/c.txt", "c.txt"));
}

/// Owning duplicate of a parent directory; shared by jobs with files in that directory.
/// Identity is the parent path — not the FD number (FDs are recycled after `leave`).
const SharedDir = struct {
    dir: std.Io.Dir,
    parent_path: []const u8,
    refs: std.atomic.Value(usize),
    gpa: std.mem.Allocator,

    fn create(io: std.Io, gpa: std.mem.Allocator, src: std.Io.Dir, parent_path: []const u8) !*SharedDir {
        const cloned = try cloneDir(io, src);
        errdefer cloned.close(io);
        const path_copy = try gpa.dupe(u8, parent_path);
        errdefer gpa.free(path_copy);
        const self = try gpa.create(SharedDir);
        self.* = .{
            .dir = cloned,
            .parent_path = path_copy,
            .refs = .init(1),
            .gpa = gpa,
        };
        return self;
    }

    fn matches(self: *const SharedDir, path: []const u8, basename: []const u8) bool {
        return std.mem.eql(u8, self.parent_path, parentPathOf(path, basename));
    }

    fn retain(self: *SharedDir) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    fn release(self: *SharedDir, io: std.Io) void {
        if (self.refs.fetchSub(1, .release) == 1) {
            self.dir.close(io);
            self.gpa.free(self.parent_path);
            self.gpa.destroy(self);
        }
    }
};

fn cloneDir(io: std.Io, dir: std.Io.Dir) !std.Io.Dir {
    if (builtin.os.tag == .windows) {
        // CRT `dup` is not applicable to Windows HANDLEs; open "." via Io instead.
        return dir.openDir(io, ".", .{ .follow_symlinks = false });
    } else {
        const fd = std.c.dup(dir.handle);
        if (fd < 0) return error.Unexpected;
        return .{ .handle = fd };
    }
}

const StatJob = struct {
    parent: *SharedDir,
    basename: []const u8,

    fn deinit(self: StatJob, io: std.Io, gpa: std.mem.Allocator) void {
        self.parent.release(io);
        gpa.free(self.basename);
    }
};

const JobQueue = struct {
    mutex: std.Io.Mutex = .init,
    not_empty: std.Io.Condition = .init,
    not_full: std.Io.Condition = .init,
    items: std.ArrayList(StatJob) = .empty,
    capacity: usize,
    closed: bool = false,
    gpa: std.mem.Allocator,

    fn deinit(self: *JobQueue, io: std.Io) void {
        for (self.items.items) |job| {
            job.deinit(io, self.gpa);
        }
        self.items.deinit(self.gpa);
    }

    fn push(self: *JobQueue, io: std.Io, job: StatJob) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        while (self.items.items.len >= self.capacity and !self.closed) {
            self.not_full.waitUncancelable(io, &self.mutex);
        }
        if (self.closed) {
            job.deinit(io, self.gpa);
            return;
        }
        self.items.append(self.gpa, job) catch {
            job.deinit(io, self.gpa);
            return;
        };
        self.not_empty.signal(io);
    }

    fn pop(self: *JobQueue, io: std.Io) ?StatJob {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        while (self.items.items.len == 0 and !self.closed) {
            self.not_empty.waitUncancelable(io, &self.mutex);
        }
        const job = self.items.pop() orelse return null;
        self.not_full.signal(io);
        return job;
    }

    fn close(self: *JobQueue, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.closed = true;
        self.not_empty.broadcast(io);
        self.not_full.broadcast(io);
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

fn statWorker(
    io: std.Io,
    queue: *JobQueue,
    rep: *reporter.Reporter,
) void {
    while (true) {
        const job = queue.pop(io) orelse return;
        defer job.deinit(io, queue.gpa);
        const stat = job.parent.dir.statFile(io, job.basename, .{ .follow_symlinks = false }) catch {
            continue;
        };
        rep.addFile(stat.size);
    }
}

/// Single-threaded selective walk; parallel `statFile` via a bounded queue and `jobs` workers.
/// `jobs` must be >= 2; use `walk` for the single-threaded path.
///
/// Workers `statFile` on a dup'd parent directory + basename (same as the serial path),
/// not on a full path from the scan root.
pub fn walkParallel(
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: std.Io.Dir,
    exclusions: lib.Exclusions,
    rep: *reporter.Reporter,
    jobs: usize,
) (std.mem.Allocator.Error || std.Io.Cancelable || std.Io.ConcurrentError)!void {
    std.debug.assert(jobs >= 2);

    var queue: JobQueue = .{
        .capacity = jobs * queue_slots_per_job,
        .gpa = gpa,
    };
    defer queue.deinit(io);

    var group: std.Io.Group = .init;
    errdefer group.cancel(io);

    for (0..jobs) |_| {
        try group.concurrent(io, statWorker, .{ io, &queue, rep });
    }

    var walker = try dir.walkSelectively(gpa);
    defer {
        while (walker.stack.items.len > 0) {
            walker.leave(io);
        }
        walker.deinit();
    }

    var current_parent: ?*SharedDir = null;
    defer if (current_parent) |parent| parent.release(io);

    while (true) {
        const entry_or_null = walker.next(io) catch {
            continue;
        };
        const entry = entry_or_null orelse break;
        if (exclusions.probe(entry.path)) {
            continue;
        }
        switch (entry.kind) {
            .directory => {
                walker.enter(io, entry) catch {
                    continue;
                };
                rep.addDir();
            },
            .file => {
                if (current_parent == null or !current_parent.?.matches(entry.path, entry.basename)) {
                    if (current_parent) |parent| parent.release(io);
                    current_parent = SharedDir.create(
                        io,
                        gpa,
                        entry.dir,
                        parentPathOf(entry.path, entry.basename),
                    ) catch {
                        continue;
                    };
                }
                const parent = current_parent.?;
                parent.retain();
                const basename = gpa.dupe(u8, entry.basename) catch {
                    parent.release(io);
                    continue;
                };
                queue.push(io, .{ .parent = parent, .basename = basename });
            },
            else => {},
        }
        rep.maybeRefreshProgress();
    }

    queue.close(io);
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
    try tmp.dir.writeFile(io, .{ .sub_path = "root.txt", .data = "root" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a/x.txt", .data = "xx" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a/b/y.txt", .data = "yyy" });
    try tmp.dir.writeFile(io, .{ .sub_path = "proc/secret.txt", .data = "nope" });

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
    try std.testing.expectEqual(@as(u64, 3), serial.files);
    try std.testing.expectEqual(@as(u64, 2), serial.dirs);
    try std.testing.expectEqual(@as(u64, 4 + 2 + 3), serial.bytes);
}
