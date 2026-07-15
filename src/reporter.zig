const std = @import("std");
const progress_portion: u64 = 1024;

pub const Reporter = struct {
    total_size: u64,
    total_file_count: u64,
    total_dir_count: u64,
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
            .total_size = 0,
            .total_file_count = 0,
            .total_dir_count = 0,
            .progress = progress,
            .directories_progress = directories_progress,
            .files_progress = files_progress,
            .start = std.Io.Clock.real.now(io),
            .io = io,
        };
    }

    pub fn update(self: *Reporter, entry: *const std.Io.Dir.Walker.Entry) void {
        switch (entry.kind) {
            std.Io.File.Kind.file => {
                const stat = entry.dir.statFile(self.io, entry.basename, .{ .follow_symlinks = false }) catch {
                    return;
                };
                self.total_file_count += 1;
                self.total_size += stat.size;
            },
            std.Io.File.Kind.directory => {
                self.total_dir_count += 1;
            },
            else => {},
        }
        if (shouldUpdateProgress(self.total_file_count)) {
            self.files_progress.setCompletedItems(@intCast(self.total_file_count));
            self.directories_progress.setCompletedItems(@intCast(self.total_dir_count));
            self.progress.setCompletedItems(elapsedSeconds(self.start.durationTo(std.Io.Clock.real.now(self.io))));
        }
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
            self.total_file_count,
            self.total_dir_count,
            self.total_size,
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
