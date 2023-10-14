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
        var entry = try walker.next() orelse {
            break;
        };
        switch (entry.kind) {
            std.fs.IterableDir.Entry.Kind.file => {
                //try stdout.print("{s}\n", .{entry.path});
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
    const total_size_str = humanize(allocator, total_size);
    defer allocator.free(total_size_str);
    try stdout.print("Total files: {d}\nTotal directories: {d}\nTotal files size: {s}\n", .{ total_file_count, total_dir_count, total_size_str });
}

fn humanize(allocator: std.mem.Allocator, n: u64) []const u8 {
    const units = [_][]const u8{ "bytes", "Kb", "Mb", "Gb", "Tb", "Pb", "Eb", "Zb", "Yb", "Bb", "GPb" };
    const thousand: u64 = 1024;
    const unit: usize = if (n < thousand) 0 else std.math.log2(n) / std.math.log2(thousand);

    const size = @as(f32, @floatFromInt(n)) / @as(f32, @floatFromInt(std.math.pow(u64, thousand, unit)));

    const result = std.fmt.allocPrint(allocator, "{d} {s}", .{ size, units[unit] }) catch "";
    return result;
}

test "humanize bytes" {
    const ally = std.testing.allocator;
    const actual = humanize(ally, 100);
    defer ally.free(actual);
    try std.testing.expectEqualStrings("100 bytes", actual);
}

test "humanize Kb" {
    const ally = std.testing.allocator;
    const actual = humanize(ally, 1024);
    defer ally.free(actual);
    try std.testing.expectEqualStrings("1 Kb", actual);
}

test "humanize Mb" {
    const ally = std.testing.allocator;
    const actual = humanize(ally, 1024 * 1024);
    defer ally.free(actual);
    try std.testing.expectEqualStrings("1 Mb", actual);
}

test "humanize 2 Mb" {
    const ally = std.testing.allocator;
    const actual = humanize(ally, 2 * 1024 * 1024);
    defer ally.free(actual);
    try std.testing.expectEqualStrings("2 Mb", actual);
}

test "humanize 1.953125 Mb" {
    const ally = std.testing.allocator;
    const actual = humanize(ally, 2 * 1000 * 1024);
    defer ally.free(actual);
    try std.testing.expectEqualStrings("1.953125 Mb", actual);
}

test "humanize Gb" {
    const ally = std.testing.allocator;
    const actual = humanize(ally, 1024 * 1024 * 1024);
    defer ally.free(actual);
    try std.testing.expectEqualStrings("1 Gb", actual);
}
