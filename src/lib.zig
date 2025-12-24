const std = @import("std");

pub const Exlusions = struct {
    haystack: []const []const u8,
    /// Probes `path` to be excluded from scanning
    pub fn probe(self: *const Exlusions, path: []const u8) bool {
        for (self.haystack) |prefix| {
            if (std.mem.startsWith(u8, path, prefix)) {
                return true;
            }
        }
        return false;
    }
};

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
