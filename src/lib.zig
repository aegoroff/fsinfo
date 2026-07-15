const std = @import("std");

pub const Exlusions = struct {
    haystack: []const []const u8,
    /// Probes `path` to be excluded from scanning.
    /// `path` may be absolute or relative to the walk root (as from `Walker.Entry.path`).
    pub fn probe(self: *const Exlusions, path: []const u8) bool {
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

test "exclusions match first" {
    var iter = Exlusions{
        .haystack = &[_][]const u8{ "/proc", "/dev", "/sys" },
    };

    try std.testing.expect(iter.probe("/proc/1"));
}

test "exclusions match not first" {
    var iter = Exlusions{
        .haystack = &[_][]const u8{ "/proc", "/dev", "/sys" },
    };

    try std.testing.expect(iter.probe("/dev/null"));
}

test "exclusions match exact" {
    var iter = Exlusions{
        .haystack = &[_][]const u8{ "/proc", "/dev", "/sys" },
    };

    try std.testing.expect(iter.probe("/dev"));
}

test "exclusions not match" {
    var iter = Exlusions{
        .haystack = &[_][]const u8{ "/proc", "/dev", "/sys" },
    };

    try std.testing.expect(!iter.probe("/usr/local"));
}

test "exclusions match walker relative paths" {
    var iter = Exlusions{
        .haystack = &[_][]const u8{ "/proc", "/dev", "/sys" },
    };

    try std.testing.expect(iter.probe("proc"));
    try std.testing.expect(iter.probe("proc/1"));
    try std.testing.expect(iter.probe("dev/null"));
    try std.testing.expect(iter.probe("sys/fs"));
}

test "exclusions require path boundary" {
    var iter = Exlusions{
        .haystack = &[_][]const u8{ "/proc", "/dev", "/sys" },
    };

    try std.testing.expect(!iter.probe("processing"));
    try std.testing.expect(!iter.probe("/processing"));
    try std.testing.expect(!iter.probe("device"));
    try std.testing.expect(!iter.probe("sysfoo"));
    try std.testing.expect(!iter.probe("usr/proc"));
}
