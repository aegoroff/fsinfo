const std = @import("std");
const yazap = @import("yazap");
const builtin = @import("builtin");
const build_options = @import("build_options");
const reporter = @import("reporter.zig");
const scan = @import("scan.zig");

pub fn defaultJobs() usize {
    const cpu_count = std.Thread.getCpuCount() catch 1;
    return @max(cpu_count / 2, 1);
}

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer {
        stdout.flush() catch {};
    }

    const allocator = init.gpa;
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
    defer allocator.free(app_descr);

    var app = yazap.App.init(allocator, "fsinfo", app_descr);
    defer app.deinit();

    var root_cmd = app.rootCommand();
    root_cmd.setProperty(.help_on_empty_args);
    root_cmd.setProperty(.positional_arg_required);
    try root_cmd.addArg(yazap.Arg.positional("PATH", "Path to analyze", null));
    try root_cmd.addArg(yazap.Arg.singleValueOption(
        "jobs",
        'j',
        "Parallel directory-walk workers (default: half the CPU count)",
    ));

    const matches = try app.parseProcess(init.io, init.minimal.args);
    const source = matches.getSingleValue("PATH");

    const jobs: usize = blk: {
        if (matches.getSingleValue("jobs")) |value| {
            break :blk try std.fmt.parseInt(usize, value, 10);
        }
        break :blk defaultJobs();
    };
    if (jobs == 0) return error.InvalidJobs;

    // `openDir` accepts both absolute and relative PATH (e.g. `.`); absolute-only API asserts.
    var dir = try std.Io.Dir.cwd().openDir(init.io, source.?, scan.open_options);
    defer dir.close(init.io);

    var rep = reporter.Reporter.init(init.io);
    defer rep.finish(stdout);

    if (jobs == 1) {
        try scan.walk(init.io, allocator, dir, scan.default_exclusions, &rep);
    } else {
        try scan.walkParallel(init.io, allocator, dir, scan.default_exclusions, &rep, jobs);
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "defaultJobs is at least one" {
    try std.testing.expect(defaultJobs() >= 1);
}
