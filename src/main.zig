const std = @import("std");
const yazap = @import("yazap");
const builtin = @import("builtin");
const build_options = @import("build_options");
const lib = @import("lib.zig");

pub const Reporter = struct {
    portion_size: u64 = 1024,
    total_size: u64,
    total_file_count: u64,
    total_dir_count: u64,
    progress: std.Progress.Node,
    directories_progress:  std.Progress.Node,
    files_progress:  std.Progress.Node,
    timer: std.time.Timer,

    pub fn init() !Reporter {
        var progress = std.Progress.start(.{
            .estimated_total_items = 0,
            .root_name = "Time, sec",
        });
        const directories_progress = progress.start("Directories", @intCast(0));
        const files_progress = progress.start("Files", @intCast(0));
        const timer = try std.time.Timer.start();

        return Reporter{
            .total_size = 0,
            .total_file_count = 0,
            .total_dir_count = 0,
            .progress = progress,
            .directories_progress = directories_progress,
            .files_progress = files_progress,
            .timer = timer,
        };
    }

    pub fn update(self: *Reporter, entry: *std.fs.Dir.Walker.Entry) void {
        switch (entry.kind) {
            std.fs.Dir.Entry.Kind.file => {
                self.total_file_count += 1;
                const stat = entry.dir.statFile(entry.basename) catch {
                    return;
                };
                self.total_size += stat.size;
            },
            std.fs.Dir.Entry.Kind.directory => {
                self.total_dir_count += 1;
            },
            else => {},
        }
        if (self.total_file_count > self.portion_size and self.total_file_count % self.portion_size == 0) {
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

pub fn main() !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer {
        stdout.flush() catch {};
    }

    const allocator = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const query = std.Target.Query.fromTarget(&builtin.target);

    const app_descr_template =
        \\Fsinfo {s} ({s}), a non-interactive file system information tool implemented in Zig
        \\Copyright (C) 2025-2026 Alexander Egorov. All rights reserved.
    ;
    const app_descr = try std.fmt.allocPrint(
        allocator,
        app_descr_template,
        .{ build_options.version, @tagName(query.cpu_arch.?) },
    );

    var app = yazap.App.init(allocator, "fsinfo", app_descr);
    defer app.deinit();

    var root_cmd = app.rootCommand();
    root_cmd.setProperty(.help_on_empty_args);
    root_cmd.setProperty(.positional_arg_required);
    try root_cmd.addArg(yazap.Arg.positional("PATH", "Path to analyze", null));

    const matches = try app.parseProcess();
    const source = matches.getSingleValue("PATH");

    var dir = try std.fs.openDirAbsolute(source.?, .{ .iterate = true });
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    const exclusions = lib.Exlusions{
        .haystack = &[_][]const u8{ "/proc", "/dev", "/sys" },
    };
    var reporter = try Reporter.init();
    defer reporter.finish(stdout);

    while (true) {
        const entry_or_null = walker.next() catch {
            continue;
        };
        var entry = entry_or_null orelse {
            break;
        };
        if (exclusions.probe(entry.path)) {
            continue;
        }
        reporter.update(&entry);
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
