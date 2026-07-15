const std = @import("std");
const progress_portion: u64 = 1024;

pub const Reporter = struct {
    total_size: std.atomic.Value(u64),
    total_file_count: std.atomic.Value(u64),
    total_dir_count: std.atomic.Value(u64),
    /// Next file count that should refresh progress UI (claimed via CAS).
    next_progress_at: std.atomic.Value(u64),
    progress: std.Progress.Node,
    directories_progress: std.Progress.Node,
    files_progress: std.Progress.Node,
    start: std.Io.Timestamp,
    io: std.Io,

    pub fn init(io: std.Io) Reporter {
        var progress = std.Progress.start(io, .{
            .estimated_total_items = 0,
            .root_name = "Time, sec",
        });
        const directories_progress = progress.start("Directories", 0);
        const files_progress = progress.start("Files", 0);

        return Reporter{
            .total_size = .init(0),
            .total_file_count = .init(0),
            .total_dir_count = .init(0),
            .next_progress_at = .init(progress_portion),
            .progress = progress,
            .directories_progress = directories_progress,
            .files_progress = files_progress,
            .start = std.Io.Clock.real.now(io),
            .io = io,
        };
    }

    pub fn addDir(self: *Reporter) void {
        _ = self.total_dir_count.fetchAdd(1, .monotonic);
    }

    pub fn addFile(self: *Reporter, size: u64) void {
        _ = self.total_file_count.fetchAdd(1, .monotonic);
        _ = self.total_size.fetchAdd(size, .monotonic);
    }

    pub fn fileCount(self: *const Reporter) u64 {
        return self.total_file_count.load(.monotonic);
    }

    pub fn dirCount(self: *const Reporter) u64 {
        return self.total_dir_count.load(.monotonic);
    }

    pub fn byteCount(self: *const Reporter) u64 {
        return self.total_size.load(.monotonic);
    }

    /// Safe to call concurrently while workers mutate counters.
    pub fn maybeRefreshProgress(self: *Reporter) void {
        const files = self.fileCount();
        const next = self.next_progress_at.load(.monotonic);
        if (files < next) return;
        const new_next = files - (files % progress_portion) + progress_portion;
        if (self.next_progress_at.cmpxchgStrong(next, new_next, .monotonic, .monotonic) != null) {
            return;
        }
        self.files_progress.setCompletedItems(@intCast(files));
        self.directories_progress.setCompletedItems(@intCast(self.dirCount()));
        self.progress.setCompletedItems(elapsedSeconds(self.start.durationTo(std.Io.Clock.real.now(self.io))));
    }

    pub fn update(self: *Reporter, entry: *const std.Io.Dir.Walker.Entry) void {
        switch (entry.kind) {
            std.Io.File.Kind.file => {
                const stat = entry.dir.statFile(self.io, entry.basename, .{ .follow_symlinks = false }) catch {
                    return;
                };
                self.addFile(stat.size);
            },
            std.Io.File.Kind.directory => {
                self.addDir();
            },
            else => {},
        }
        self.maybeRefreshProgress();
    }

    pub fn finish(self: *Reporter, writer: *std.Io.Writer) void {
        self.directories_progress.end();
        self.files_progress.end();
        self.progress.end();

        const end = std.Io.Clock.real.now(self.io);
        const duration = self.start.durationTo(end);

        const print_args = .{
            "Total files:",
            "Total directories:",
            "Total files size:",
            self.fileCount(),
            self.dirCount(),
            self.byteCount(),
            "Time taken:",
        };
        writer.print("{0s:<19} {3d}\n{1s:<19} {4d}\n{2s:<19} {5Bi:.2} ({5} bytes)\n{6s:<19} ", print_args) catch {};
        duration.format(writer) catch {};
        writer.print("\n", .{}) catch {};
    }
};

fn shouldUpdateProgress(file_count: u64) bool {
    return file_count >= progress_portion and file_count % progress_portion == 0;
}

fn elapsedSeconds(duration: std.Io.Duration) usize {
    const secs = duration.toSeconds();
    if (secs <= 0) return 0;
    return @intCast(secs);
}

test "progress updates at portion boundary including first" {
    try std.testing.expect(!shouldUpdateProgress(0));
    try std.testing.expect(!shouldUpdateProgress(1023));
    try std.testing.expect(shouldUpdateProgress(1024));
    try std.testing.expect(!shouldUpdateProgress(1025));
    try std.testing.expect(shouldUpdateProgress(2048));
}

test "elapsedSeconds saturates non-positive durations" {
    try std.testing.expectEqual(@as(usize, 0), elapsedSeconds(.fromSeconds(0)));
    try std.testing.expectEqual(@as(usize, 0), elapsedSeconds(.fromSeconds(-1)));
    try std.testing.expectEqual(@as(usize, 3), elapsedSeconds(.fromSeconds(3)));
}
