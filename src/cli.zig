const std = @import("std");
const yazap = @import("yazap");
const builtin = @import("builtin");
const build_options = @import("build_options");

/// Floor for the `--jobs` cap; raised to the logical CPU count when that is larger.
pub const min_max_jobs: usize = 128;

pub const Options = struct {
    /// Owned by the caller; free with `gpa.free`.
    path: []u8,
    jobs: usize,
};

fn cpuCount() usize {
    return std.Thread.getCpuCount() catch 1;
}

fn defaultJobs() usize {
    return @max(cpuCount() / 2, 1);
}

/// Cap at least 128 workers, or the logical CPU count when higher (I/O-bound walk).
pub fn maxJobs() usize {
    return @max(min_max_jobs, cpuCount());
}

fn validateJobs(jobs: usize) error{InvalidJobs}!usize {
    if (jobs == 0 or jobs > maxJobs()) return error.InvalidJobs;
    return jobs;
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
        "Parallel directory-walk workers (default: half the CPU count; max 128 or CPU count)",
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

    return .{ .path = path, .jobs = try validateJobs(jobs) };
}

test "defaultJobs is at least one" {
    try std.testing.expect(defaultJobs() >= 1);
}

test "maxJobs is at least 128" {
    try std.testing.expect(maxJobs() >= min_max_jobs);
}

test "validateJobs rejects zero and values above maxJobs" {
    const cap = maxJobs();
    try std.testing.expectError(error.InvalidJobs, validateJobs(0));
    try std.testing.expectEqual(@as(usize, 1), try validateJobs(1));
    try std.testing.expectEqual(cap, try validateJobs(cap));
    try std.testing.expectError(error.InvalidJobs, validateJobs(cap + 1));
    try std.testing.expectError(error.InvalidJobs, validateJobs(std.math.maxInt(usize)));
}
