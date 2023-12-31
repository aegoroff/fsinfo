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
    const exclusions = Exlusions{
        .haystack = &[_][]const u8{ "/proc", "/dev", "/sys" },
    };
    while (true) {
        var entry_or_null = walker.next() catch {
            continue;
        };
        var entry = entry_or_null orelse {
            break;
        };
        if (exclusions.probe(entry.path)) {
            continue;
        }
        switch (entry.kind) {
            std.fs.IterableDir.Entry.Kind.file => {
                total_file_count += 1;
                const stat = entry.dir.statFile(entry.basename) catch {
                    continue;
                };
                total_size += stat.size;
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

const Exlusions = struct {
    haystack: []const []const u8,
    /// Probes `path` to be excluded from scanning
    fn probe(self: *const Exlusions, path: []const u8) bool {
        for (self.haystack) |prefix| {
            if (std.mem.startsWith(u8, path, prefix)) {
                return true;
            }
        }
        return false;
    }
};

test "exclusions match first" {
    var iter = Exlusions{
        .haystack = &[_][]const u8{ "/proc", "/dev", "/sys" },
    };

    try std.testing.expect(iter.probe("/proc/1"));
}

test "exclusions match not first" {
    var iter = Exlusions{
        .haystack = &[_][]const u8{ "/proc", "/dev", "/sys" },
    };

    try std.testing.expect(iter.probe("/dev/null"));
}

test "exclusions match exact" {
    var iter = Exlusions{
        .haystack = &[_][]const u8{ "/proc", "/dev", "/sys" },
    };

    try std.testing.expect(iter.probe("/dev"));
}

test "exclusions not match" {
    var iter = Exlusions{
        .haystack = &[_][]const u8{ "/proc", "/dev", "/sys" },
    };

    try std.testing.expect(!iter.probe("/usr/local"));
}
