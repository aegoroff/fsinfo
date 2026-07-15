const std = @import("std");
const reporter = @import("reporter.zig");
const scan = @import("scan.zig");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer {
        stdout.flush() catch {};
    }

    const opts = cli.parse(init.gpa, init.io, init.minimal.args) catch |err| {
        if (err == error.InvalidJobs) {
            var stderr_buffer: [256]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
            const stderr = &stderr_writer.interface;
            stderr.print("error: --jobs must be between 1 and {d}\n", .{cli.maxJobs()}) catch {};
            stderr.flush() catch {};
            std.process.exit(2);
        }
        return err;
    };
    defer init.gpa.free(opts.path);

    // `openDir` accepts both absolute and relative PATH (e.g. `.`); absolute-only API asserts.
    var dir = try std.Io.Dir.cwd().openDir(init.io, opts.path, scan.open_options);
    defer dir.close(init.io);

    scan.ensureRootAllowed(init.io, dir, scan.default_exclusions) catch |err| {
        if (err == error.PathExcluded) {
            var stderr_buffer: [256]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
            const stderr = &stderr_writer.interface;
            stderr.print("error: path is excluded from scanning ({s})\n", .{opts.path}) catch {};
            stderr.flush() catch {};
            std.process.exit(2);
        }
        return err;
    };

    var rep = reporter.Reporter.init(init.io);
    defer rep.finish(stdout);

    if (opts.jobs == 1) {
        try scan.walk(init.io, init.gpa, dir, scan.default_exclusions, &rep);
    } else {
        try scan.walkParallel(init.io, init.gpa, dir, scan.default_exclusions, &rep, opts.jobs);
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
