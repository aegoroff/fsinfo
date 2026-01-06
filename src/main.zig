const std = @import("std");
const yazap = @import("yazap");
const builtin = @import("builtin");
const build_options = @import("build_options");
const lib = @import("lib.zig");

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
    var total_size: u64 = 0;
    var total_file_count: u64 = 0;
    var total_dir_count: u64 = 0;
    var progress = std.Progress.start(.{
        .estimated_total_items = 0,
        .root_name = "Time, sec",
    });
    var directories_progress = progress.start("Directories", @intCast(total_dir_count));
    var files_progress = progress.start("Files", @intCast(total_file_count));

    const portion_size = 1024;
    const exclusions = lib.Exlusions{
        .haystack = &[_][]const u8{ "/proc", "/dev", "/sys" },
    };
    var timer = try std.time.Timer.start();
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
        switch (entry.kind) {
            std.fs.Dir.Entry.Kind.file => {
                total_file_count += 1;
                const stat = entry.dir.statFile(entry.basename) catch {
                    continue;
                };
                total_size += stat.size;
            },
            std.fs.Dir.Entry.Kind.directory => {
                total_dir_count += 1;
            },
            else => {},
        }
        if (total_file_count > portion_size and total_file_count % portion_size == 0) {
            files_progress.setCompletedItems(@intCast(total_file_count));
            directories_progress.setCompletedItems(@intCast(total_dir_count));
            const elapsed = timer.read() / 1000000000;
            progress.setCompletedItems(@intCast(elapsed));
        }
    }
    directories_progress.end();
    files_progress.end();
    progress.end();

    const elapsed = timer.read();
    const print_args = .{
        "Total files:",
        "Total directories:",
        "Total files size:",
        total_file_count,
        total_dir_count,
        total_size,
        "Time taken:",
        elapsed,
    };
    try stdout.print("{0s:<19} {3d}\n{1s:<19} {4d}\n{2s:<19} {5Bi:.2} ({5} bytes)\n{6s:<19} {7D}\n", print_args);
}

test {
    @import("std").testing.refAllDecls(@This());
}
