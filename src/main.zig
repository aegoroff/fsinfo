const std = @import("std");
const clap = @import("clap");

pub fn main() !void {
    // stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    const stdout = std.io.getStdOut().writer();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\-p, --path <str>        Path to walk.
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
    const source = res.args.path orelse {
        return clap.help(stdout, clap.Help, &params, .{});
    };
    var dir = try std.fs.openIterableDirAbsolute(source, .{});
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var total_size: u64 = 0;
    var total_file_count: u64 = 0;
    var total_dir_count: u64 = 0;
    while (true) {
        var entry_or_null = walker.next() catch {
            continue;
        };
        var entry = entry_or_null orelse {
            break;
        };
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
    }
    const print_args = .{ "Total files:", "Total directories:", "Total files size:", total_file_count, total_dir_count, std.fmt.fmtIntSizeBin(total_size), total_size };
    try stdout.print("{0s:<19} {3d}\n{1s:<19} {4d}\n{2s:<19} {5:.2} ({6} bytes)\n", print_args);
}
