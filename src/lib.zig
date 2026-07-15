const std = @import("std");

pub const Exclusions = struct {
    haystack: []const []const u8,
    /// Probes `path` to be excluded from scanning.
    /// `path` may be absolute or relative to the walk root (as from `Walker.Entry.path`).
    pub fn probe(self: *const Exclusions, path: []const u8) bool {
        for (self.haystack) |prefix| {
            if (matchesExcludedPrefix(path, prefix)) {
                return true;
            }
        }
        return false;
    }
};

fn stripLeadingSeps(path: []const u8) []const u8 {
    var i: usize = 0;
    while (i < path.len and std.fs.path.isSep(path[i])) : (i += 1) {}
    return path[i..];
}

/// True when `path` is `excluded` or `excluded` followed by a path separator.
/// Leading separators on either side are ignored so `/proc` matches walker paths like `proc/1`.
fn matchesExcludedPrefix(path: []const u8, excluded: []const u8) bool {
    const path_norm = stripLeadingSeps(path);
    const excl_norm = stripLeadingSeps(excluded);
    if (excl_norm.len == 0) return false;
    if (!std.mem.startsWith(u8, path_norm, excl_norm)) return false;
    if (path_norm.len == excl_norm.len) return true;
    return std.fs.path.isSep(path_norm[excl_norm.len]);
}

test "exclusions table" {
    const haystack = [_][]const u8{ "/proc", "/dev", "/sys" };
    const exclusions = Exclusions{ .haystack = &haystack };

    const Case = struct {
        path: []const u8,
        excluded: bool,
    };
    const cases = [_]Case{
        .{ .path = "/proc/1", .excluded = true },
        .{ .path = "/dev/null", .excluded = true },
        .{ .path = "/dev", .excluded = true },
        .{ .path = "/sys/fs", .excluded = true },
        .{ .path = "proc", .excluded = true },
        .{ .path = "proc/1", .excluded = true },
        .{ .path = "dev/null", .excluded = true },
        .{ .path = "sys/fs", .excluded = true },
        .{ .path = "/usr/local", .excluded = false },
        .{ .path = "processing", .excluded = false },
        .{ .path = "/processing", .excluded = false },
        .{ .path = "device", .excluded = false },
        .{ .path = "sysfoo", .excluded = false },
        .{ .path = "usr/proc", .excluded = false },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.excluded, exclusions.probe(case.path));
    }
}

test "exclusions respect native path separators" {
    const exclusions = Exclusions{
        .haystack = &[_][]const u8{"proc"},
    };
    if (std.fs.path.sep == '/') {
        try std.testing.expect(exclusions.probe("proc/1"));
        try std.testing.expect(!exclusions.probe("proc\\1"));
    } else {
        try std.testing.expect(exclusions.probe("proc\\1"));
    }
}
