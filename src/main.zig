const std = @import("std");
const clap = @import("clap");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Display this help and exit.
        \\<str>       Path to analyze.
        \\
    );
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
    }) catch |err| {
        // Report useful error and exit
        diag.report(stdout, err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.help(stdout, clap.Help, &params, .{});
    }

    const allocator = std.heap.c_allocator;

    const source = if (res.positionals.len == 1) res.positionals[0] else {
        return clap.help(stdout, clap.Help, &params, .{});
    };

    var dir = try std.fs.openIterableDirAbsolute(source, .{});
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var total_size: u64 = 0;
    var total_file_count: u64 = 0;
    var total_dir_count: u64 = 0;
    var progress = std.Progress{};
    var files_progress = progress.start("Files", total_file_count);
    files_progress.setUnit("");
    var directories_progress = files_progress.start("Directories", total_dir_count);
    directories_progress.setUnit("");
    const portion_size = 1024;
    var exclusions = StartsWithIterator{
        .needles = &[_][]const u8{ "/proc", "/dev", "/sys" },
        .haystack = "",
    };
    while (true) {
        var entry_or_null = walker.next() catch {
            continue;
        };
        var entry = entry_or_null orelse {
            break;
        };
        exclusions.haystack = entry.path;
        if (exclusions.next() != null) {
            continue;
        }
        switch (entry.kind) {
            std.fs.IterableDir.Entry.Kind.file => {
                const stat = try entry.dir.statFile(entry.basename);
                total_size += stat.size;
                total_file_count += 1;
            },
            std.fs.IterableDir.Entry.Kind.directory => {
                total_dir_count += 1;
            },
            else => {},
        }
        if (total_file_count > portion_size and total_file_count % portion_size == 0) {
            files_progress.setCompletedItems(total_file_count);
            directories_progress.setCompletedItems(total_dir_count);
            progress.maybeRefresh();
        }
    }
    files_progress.end();
    directories_progress.end();
    const print_args = .{ "Total files:", "Total directories:", "Total files size:", total_file_count, total_dir_count, std.fmt.fmtIntSizeBin(total_size), total_size };
    try stdout.print("{0s:<19} {3d}\n{1s:<19} {4d}\n{2s:<19} {5:.2} ({6} bytes)\n", print_args);
}

const StartsWithIterator = struct {
    needles: []const []const u8,
    haystack: []const u8,
    index: usize = 0,
    fn next(self: *StartsWithIterator) ?[]const u8 {
        const index = self.index;
        for (self.needles[index..]) |needle| {
            self.index += 1;
            if (std.mem.startsWith(u8, self.haystack, needle)) {
                return needle;
            }
        }
        return null;
    }
};

test "starts match" {
    var iter = StartsWithIterator{
        .needles = &[_][]const u8{ "/proc", "/dev", "/sys" },
        .haystack = "/proc/1",
    };

    try std.testing.expect(iter.next() != null);
}

test "starts not match" {
    var iter = StartsWithIterator{
        .needles = &[_][]const u8{ "/proc", "/dev", "/sys" },
        .haystack = "/usr/local",
    };

    try std.testing.expect(iter.next() == null);
}
