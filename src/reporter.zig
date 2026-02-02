const std = @import("std");
const portion_size: u64 = 1024;

pub const Reporter = struct {
    total_size: u64,
    total_file_count: u64,
    total_dir_count: u64,
    progress: std.Progress.Node,
    directories_progress: std.Progress.Node,
    files_progress: std.Progress.Node,
    timer: std.time.Timer,
    io: std.Io,

    pub fn init(io: std.Io) !Reporter {
        var progress = std.Progress.start(io, .{
            .estimated_total_items = 0,
            .root_name = "Time, sec",
        });
        const directories_progress = progress.start("Directories", 0);
        const files_progress = progress.start("Files", 0);
        const timer = try std.time.Timer.start();

        return Reporter{
            .total_size = 0,
            .total_file_count = 0,
            .total_dir_count = 0,
            .progress = progress,
            .directories_progress = directories_progress,
            .files_progress = files_progress,
            .timer = timer,
            .io = io,
        };
    }

    pub fn update(self: *Reporter, entry: *std.Io.Dir.Walker.Entry) void {
        switch (entry.kind) {
            std.Io.File.Kind.file => {
                self.total_file_count += 1;
                const stat = entry.dir.statFile(self.io, entry.basename, .{ .follow_symlinks = false }) catch {
                    return;
                };
                self.total_size += stat.size;
            },
            std.Io.File.Kind.directory => {
                self.total_dir_count += 1;
            },
            else => {},
        }
        if (self.total_file_count > portion_size and self.total_file_count % portion_size == 0) {
            self.files_progress.setCompletedItems(@intCast(self.total_file_count));
            self.directories_progress.setCompletedItems(@intCast(self.total_dir_count));
            const elapsed = self.timer.read() / 1000000000;
            self.progress.setCompletedItems(@intCast(elapsed));
        }
    }

    pub fn finish(self: *Reporter, writer: *std.Io.Writer) void {
        self.directories_progress.end();
        self.files_progress.end();
        self.progress.end();

        const elapsed = self.timer.read();
        const print_args = .{
            "Total files:",
            "Total directories:",
            "Total files size:",
            self.total_file_count,
            self.total_dir_count,
            self.total_size,
            "Time taken:",
            elapsed,
        };
        writer.print("{0s:<19} {3d}\n{1s:<19} {4d}\n{2s:<19} {5Bi:.2} ({5} bytes)\n{6s:<19} {7D}\n", print_args) catch {};
    }
};
