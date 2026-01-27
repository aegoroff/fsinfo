const std = @import("std");
const yazap = @import("yazap");
const builtin = @import("builtin");
const build_options = @import("build_options");
const lib = @import("lib.zig");
const reporter = @import("reporter.zig");

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
    var rep = try reporter.Reporter.init();
    defer rep.finish(stdout);

    const cpu_count = try std.Thread.getCpuCount() / 2;
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{
        .allocator = allocator,
        .n_jobs = @max(cpu_count, 2),
    });
    defer pool.deinit();

    var wg: std.Thread.WaitGroup = .{};

    while (true) {
        const entry_or_null = walker.next() catch {
            continue;
        };
        const entry = entry_or_null orelse {
            break;
        };
        if (exclusions.probe(entry.path)) {
            continue;
        }
        pool.spawnWg(&wg, reporter.Reporter.update, .{ &rep, entry });
    }
    wg.wait();
}

test {
    @import("std").testing.refAllDecls(@This());
}
