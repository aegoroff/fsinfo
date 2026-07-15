const std = @import("std");
const yazap = @import("yazap");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const Options = struct {
    /// Owned by the caller; free with `gpa.free`.
    path: []u8,
    jobs: usize,
};

fn defaultJobs() usize {
    const cpu_count = std.Thread.getCpuCount() catch 1;
    return @max(cpu_count / 2, 1);
}

pub fn parse(gpa: std.mem.Allocator, io: std.Io, args: std.process.Args) !Options {
    const query = std.Target.Query.fromTarget(&builtin.target);

    const app_descr_template =
        \\Fsinfo {s} ({s}), a non-interactive file system information tool implemented in Zig
        \\Copyright (C) 2025-2026 Alexander Egorov. All rights reserved.
    ;
    const app_descr = try std.fmt.allocPrint(
        gpa,
        app_descr_template,
        .{ build_options.version, @tagName(query.cpu_arch.?) },
    );
    defer gpa.free(app_descr);

    var app = yazap.App.init(gpa, "fsinfo", app_descr);
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

    const matches = try app.parseProcess(io, args);
    const path = try gpa.dupe(u8, matches.getSingleValue("PATH").?);
    errdefer gpa.free(path);

    const jobs: usize = blk: {
        if (matches.getSingleValue("jobs")) |value| {
            break :blk try std.fmt.parseInt(usize, value, 10);
        }
        break :blk defaultJobs();
    };
    if (jobs == 0) return error.InvalidJobs;

    return .{ .path = path, .jobs = jobs };
}

test "defaultJobs is at least one" {
    try std.testing.expect(defaultJobs() >= 1);
}
