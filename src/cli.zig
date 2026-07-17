const std = @import("std");
const zig_cli = @import("zig_cli");
const builtin = @import("builtin");
const build_options = @import("build_options");

/// Floor for the `--jobs` cap; raised to the logical CPU count when that is larger.
pub const min_max_jobs: usize = 128;

pub const Options = struct {
    /// Owned by the caller; free with `gpa.free`.
    path: []u8,
    jobs: usize,
    /// When set, skipped walk entries (permission errors, OOM, openDir failures, …)
    /// are reported via `std.log.warn`.
    verbose: bool,
    /// When set, print a file-size histogram after the scan.
    histogram: bool,
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

const Capture = struct {
    gpa: std.mem.Allocator,
    options: ?Options = null,
};

/// Filled by `onParsed` while `parse` runs (zig-cli actions are fn pointers).
var capture: Capture = undefined;

fn onParsed(ctx: *zig_cli.BaseCommand.ParseContext) !void {
    const path_arg = ctx.getArgument(0) orelse return error.MissingRequiredArgument;
    const path = try capture.gpa.dupe(u8, path_arg);
    errdefer capture.gpa.free(path);

    const jobs: usize = blk: {
        if (ctx.getOption("jobs")) |value| {
            break :blk std.fmt.parseInt(usize, value, 10) catch return error.InvalidJobs;
        }
        break :blk defaultJobs();
    };

    capture.options = .{
        .path = path,
        .jobs = try validateJobs(jobs),
        .verbose = ctx.hasOption("verbose"),
        .histogram = ctx.hasOption("histogram"),
    };
}

fn wantsHelp(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return true;
    }
    return false;
}

/// Expand attached short values (`-j1` → `-j`, `1`) that zig-cli's parser does not accept.
fn normalizeArgs(gpa: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);

    for (args) |arg| {
        if (arg.len >= 3 and arg[0] == '-' and arg[1] != '-' and arg[1] == 'j') {
            try list.append(gpa, arg[0..2]);
            try list.append(gpa, arg[2..]);
            continue;
        }
        try list.append(gpa, arg);
    }
    return try list.toOwnedSlice(gpa);
}

fn collectArgs(gpa: std.mem.Allocator, args: std.process.Args) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);

    var iter = std.process.Args.Iterator.init(args);
    _ = iter.skip();
    while (iter.next()) |arg| {
        try list.append(gpa, arg);
    }
    return try list.toOwnedSlice(gpa);
}

fn buildCommand(gpa: std.mem.Allocator, description: []const u8) !*zig_cli.BaseCommand {
    const cmd = try zig_cli.BaseCommand.init(gpa, "fsinfo", description);
    errdefer {
        cmd.deinit();
        gpa.destroy(cmd);
    }

    _ = try cmd.addArgument(
        zig_cli.Argument.init("PATH", "Path to analyze", .string).withRequired(true),
    );
    _ = try cmd.addOption(
        zig_cli.Option.init(
            "jobs",
            "jobs",
            "Parallel directory-walk workers (default: half the CPU count; max 128 or CPU count)",
            .int,
        ).withShort('j'),
    );
    _ = try cmd.addOption(
        zig_cli.Option.init(
            "verbose",
            "verbose",
            "Log skipped entries (permission errors, open failures, allocation failures, ...)",
            .bool,
        ).withShort('v'),
    );
    _ = try cmd.addOption(
        zig_cli.Option.init(
            "histogram",
            "histogram",
            "Print file size histogram (count and bytes per size range)",
            .bool,
        ),
    );
    _ = cmd.setAction(onParsed);
    return cmd;
}

fn optionValueLabel(option_type: zig_cli.Option.OptionType) []const u8 {
    return switch (option_type) {
        .string => " <VALUE>",
        .int => " <INT>",
        .float => " <FLOAT>",
        .bool => "",
    };
}

fn optionLeftWidth(opt: zig_cli.Option) usize {
    return 6 + 2 + opt.long.len + optionValueLabel(opt.option_type).len;
}

fn argumentLeftWidth(arg: zig_cli.Argument) usize {
    var width: usize = 4 + arg.name.len; // "  <name>"
    if (arg.variadic) width += 3;
    return width;
}

fn writePadding(writer: *std.Io.Writer, used: usize, column: usize) !void {
    var i = used;
    while (i < column) : (i += 1) {
        try writer.writeByte(' ');
    }
}

/// zig-cli's Help pads each row independently (and hardcodes `--help`), which misaligns columns.
fn printHelp(cmd: *zig_cli.BaseCommand) !void {
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &buf);
    const out = &file_writer.interface;

    const help_left = "  -h, --help";
    var left_column: usize = help_left.len;
    for (cmd.arguments.items) |arg| {
        left_column = @max(left_column, argumentLeftWidth(arg));
    }
    for (cmd.options.items) |opt| {
        left_column = @max(left_column, optionLeftWidth(opt));
    }
    const desc_column = left_column + 2;

    try out.print("\n{s} v{s}\n{s}\n\n", .{ "fsinfo", build_options.version, cmd.description });

    try out.print("USAGE:\n  {s}", .{cmd.name});
    if (cmd.options.items.len > 0) try out.print(" [OPTIONS]", .{});
    for (cmd.arguments.items) |arg| {
        if (arg.required) {
            try out.print(" <{s}>", .{arg.name});
        } else {
            try out.print(" [{s}]", .{arg.name});
        }
        if (arg.variadic) try out.print("...", .{});
    }
    try out.print("\n\n", .{});

    if (cmd.arguments.items.len > 0) {
        try out.print("ARGUMENTS:\n", .{});
        for (cmd.arguments.items) |arg| {
            try out.print("  <{s}>", .{arg.name});
            if (arg.variadic) try out.print("...", .{});
            try writePadding(out, argumentLeftWidth(arg), desc_column);
            try out.print("{s}", .{arg.description});
            if (!arg.required) try out.print(" (optional)", .{});
            try out.print("\n", .{});
        }
        try out.print("\n", .{});
    }

    if (cmd.options.items.len > 0) {
        try out.print("OPTIONS:\n", .{});
        for (cmd.options.items) |opt| {
            if (opt.short) |s| {
                try out.print("  -{c}, ", .{s});
            } else {
                try out.print("      ", .{});
            }
            try out.print("--{s}{s}", .{ opt.long, optionValueLabel(opt.option_type) });
            try writePadding(out, optionLeftWidth(opt), desc_column);
            try out.print("{s}\n", .{opt.description});
        }
        try out.print("{s}", .{help_left});
        try writePadding(out, help_left.len, desc_column);
        try out.print("Print help\n\n", .{});
    }

    try out.flush();
}

pub fn parse(gpa: std.mem.Allocator, args: std.process.Args) !Options {
    const query = std.Target.Query.fromTarget(&builtin.target);
    const description = try std.fmt.allocPrint(
        gpa,
        \\A non-interactive file system information tool implemented in Zig ({s})
        \\Copyright (C) 2025-2026 Alexander Egorov. All rights reserved.
    ,
        .{@tagName(query.cpu_arch.?)},
    );
    defer gpa.free(description);

    const cmd = try buildCommand(gpa, description);
    defer {
        cmd.deinit();
        gpa.destroy(cmd);
    }

    const raw_args = try collectArgs(gpa, args);
    defer gpa.free(raw_args);
    const arg_slice = try normalizeArgs(gpa, raw_args);
    defer gpa.free(arg_slice);

    if (arg_slice.len == 0 or wantsHelp(arg_slice)) {
        try printHelp(cmd);
        return error.HelpRequested;
    }

    capture = .{ .gpa = gpa };
    var parser = zig_cli.Parser.init(gpa);
    try parser.parse(cmd, arg_slice);
    return capture.options orelse error.MissingRequiredArgument;
}

test "defaultJobs is at least one" {
    try std.testing.expect(defaultJobs() >= 1);
}

test "maxJobs is at least 128" {
    try std.testing.expect(maxJobs() >= min_max_jobs);
}

test "normalizeArgs expands attached -j value" {
    const raw = [_][]const u8{ "-j1", "src", "--histogram" };
    const normalized = try normalizeArgs(std.testing.allocator, &raw);
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqual(@as(usize, 4), normalized.len);
    try std.testing.expectEqualStrings("-j", normalized[0]);
    try std.testing.expectEqualStrings("1", normalized[1]);
    try std.testing.expectEqualStrings("src", normalized[2]);
    try std.testing.expectEqualStrings("--histogram", normalized[3]);
}

test "optionLeftWidth matches printed left column" {
    const jobs = zig_cli.Option.init("jobs", "jobs", "", .int).withShort('j');
    try std.testing.expectEqual(@as(usize, "  -j, --jobs <INT>".len), optionLeftWidth(jobs));

    const histogram = zig_cli.Option.init("histogram", "histogram", "", .bool);
    try std.testing.expectEqual(@as(usize, "      --histogram".len), optionLeftWidth(histogram));
}
