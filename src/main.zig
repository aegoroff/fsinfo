const std = @import("std");
const reporter = @import("reporter.zig");
const scan = @import("scan.zig");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !void {
    // Parallel walk can hold many directory FDs (queue + in-flight); raise soft NOFILE first.
    std.process.raiseFileDescriptorLimit();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer {
        stdout.flush() catch {};
    }

    const opts = cli.parse(init.gpa, init.minimal.args) catch |err| switch (err) {
        error.HelpRequested => return,
        error.InvalidJobs => {
            std.log.err("--jobs must be between 1 and {d}", .{cli.maxJobs()});
            std.process.exit(2);
        },
        // zig-cli already printed `Error: …` for these; avoid a second Zig error line.
        error.OutOfMemory => return err,
        else => std.process.exit(2),
    };
    defer init.gpa.free(opts.path);

    const exclusions = try scan.buildExclusions(init.arena.allocator(), init.io);

    // `openDir` accepts both absolute and relative PATH (e.g. `.`); absolute-only API asserts.
    var dir = try std.Io.Dir.cwd().openDir(init.io, opts.path, scan.open_options);
    defer dir.close(init.io);

    scan.ensureRootAllowed(init.io, dir, exclusions) catch |err| {
        if (err == error.PathExcluded) {
            std.log.err("path is excluded from scanning ({s})", .{opts.path});
            std.process.exit(2);
        }
        return err;
    };

    var rep = reporter.Reporter.init(
        init.io,
        opts.verbose,
        opts.histogram,
    );
    defer rep.finish(init.gpa, stdout);

    if (opts.jobs == 1) {
        try scan.walk(
            init.io,
            init.gpa,
            dir,
            exclusions,
            &rep,
            opts.verbose,
        );
    } else {
        try scan.walkParallel(
            init.io,
            init.gpa,
            dir,
            exclusions,
            &rep,
            opts.jobs,
            opts.verbose,
        );
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
