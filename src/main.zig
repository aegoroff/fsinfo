const std = @import("std");
const yazap = @import("yazap");
const builtin = @import("builtin");
const build_options = @import("build_options");
const lib = @import("lib.zig");
const reporter = @import("reporter.zig");

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

    var app = yazap.App.init(allocator, "fsinfo", app_descr);
    defer app.deinit();

    var root_cmd = app.rootCommand();
    root_cmd.setProperty(.help_on_empty_args);
    root_cmd.setProperty(.positional_arg_required);
    try root_cmd.addArg(yazap.Arg.positional("PATH", "Path to analyze", null));

    const matches = try app.parseProcess(init.io, init.minimal.args);
    const source = matches.getSingleValue("PATH");

    // `openDir` accepts both absolute and relative PATH (e.g. `.`); absolute-only API asserts.
    var dir = try std.Io.Dir.cwd().openDir(init.io, source.?, .{ .iterate = true });
    // Selective walk: only descend into directories that are not excluded.
    // Plain `walk` enters every directory before returning the entry, so
    // skipping an excluded path with `continue` would still traverse children.
    var walker = try dir.walkSelectively(allocator);
    defer walker.deinit();

    const exclusions = lib.Exlusions{
        .haystack = &[_][]const u8{ "/proc", "/dev", "/sys" },
    };
    var rep = reporter.Reporter.init(init.io);
    defer rep.finish(stdout);

    while (true) {
        const entry_or_null = walker.next(init.io) catch {
            continue;
        };
        var entry = entry_or_null orelse {
            break;
        };
        if (exclusions.probe(entry.path)) {
            continue;
        }
        if (entry.kind == .directory) {
            walker.enter(init.io, entry) catch {
                continue;
            };
        }
        rep.update(&entry);
    }
}

test "selective walk does not descend into excluded directories" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "keep", .default_dir);
    try tmp.dir.createDir(io, "proc", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "keep/a.txt", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "proc/secret.txt", .data = "secret" });

    const exclusions = lib.Exlusions{
        .haystack = &[_][]const u8{"/proc"},
    };

    var walker = try tmp.dir.walkSelectively(std.testing.allocator);
    defer walker.deinit();

    var seen_keep_a = false;
    var seen_proc = false;
    var seen_secret = false;

    while (true) {
        const entry = (try walker.next(io)) orelse break;
        if (exclusions.probe(entry.path)) {
            continue;
        }
        if (entry.kind == .directory) {
            try walker.enter(io, entry);
        }
        if (std.mem.eql(u8, entry.path, "keep/a.txt")) seen_keep_a = true;
        if (std.mem.eql(u8, entry.path, "proc")) seen_proc = true;
        if (std.mem.eql(u8, entry.path, "proc/secret.txt")) seen_secret = true;
    }

    try std.testing.expect(seen_keep_a);
    try std.testing.expect(!seen_proc);
    try std.testing.expect(!seen_secret);
}

test "openDir accepts relative and absolute scan roots" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "sub", .default_dir);

    var relative = try tmp.dir.openDir(io, "sub", .{ .iterate = true });
    defer relative.close(io);

    var dot = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer dot.close(io);
}

test {
    @import("std").testing.refAllDecls(@This());
}
