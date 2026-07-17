const std = @import("std");
const grouped_int = @import("grouped_int.zig");

const kib = 1024;
const mib = 1024 * kib;
const gib = 1024 * mib;
const tib = 1024 * gib;

/// Upper bounds for buckets 0..8; bucket 9 is everything >= 10 TiB.
/// Half-open intervals: [0, 100 KiB), [100 KiB, 1 MiB), …, [10 TiB, ∞).
const thresholds = [_]u64{
    100 * kib,
    mib,
    10 * mib,
    100 * mib,
    gib,
    10 * gib,
    100 * gib,
    tib,
    10 * tib,
};

pub const bucket_count = thresholds.len + 1;

pub const labels = [_][]const u8{
    "0 B - 100 KiB",
    "100 KiB - 1 MiB",
    "1 MiB - 10 MiB",
    "10 MiB - 100 MiB",
    "100 MiB - 1 GiB",
    "1 GiB - 10 GiB",
    "10 GiB - 100 GiB",
    "100 GiB - 1 TiB",
    "1 TiB - 10 TiB",
    "10 TiB+",
};

comptime {
    if (labels.len != bucket_count) @compileError("labels length must match bucket_count");
}

pub fn bucketIndex(size: u64) usize {
    for (thresholds, 0..) |t, i| {
        if (size < t) return i;
    }
    return thresholds.len;
}

pub const Histogram = struct {
    counts: [bucket_count]std.atomic.Value(u64),
    sizes: [bucket_count]std.atomic.Value(u64),

    pub fn init() Histogram {
        var h: Histogram = undefined;
        for (&h.counts) |*c| c.* = .init(0);
        for (&h.sizes) |*s| s.* = .init(0);
        return h;
    }

    pub fn add(self: *Histogram, size: u64) void {
        const i = bucketIndex(size);
        _ = self.counts[i].fetchAdd(1, .monotonic);
        _ = self.sizes[i].fetchAdd(size, .monotonic);
    }

    /// Prints the histogram table.
    ///
    /// `writer` **must** point to stdout. `zig_cli.Table.render` writes directly to
    /// stdout via `std.Options.debug_io`, bypassing `writer`; passing any other
    /// destination splits output between two unrelated streams. The `writer.flush()`
    /// below is mandatory so the buffered title appears before the table.
    pub fn print(
        self: *const Histogram,
        gpa: std.mem.Allocator,
        writer: *std.Io.Writer,
        total_files: u64,
        total_size: u64,
    ) void {
        const Table = @import("zig_cli").prompt.Table;

        writer.print("File size histogram:\n", .{}) catch {};
        // Table.render bypasses `writer` and writes straight to stdout (see print contract);
        // flush first so the title precedes the table.
        writer.flush() catch {};

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const columns = [_]Table.Column{
            .{ .header = "#", .alignment = .right },
            .{ .header = "File size", .alignment = .left },
            .{ .header = "Count", .alignment = .right },
            .{ .header = "%", .alignment = .right },
            .{ .header = "Size", .alignment = .right },
            .{ .header = "%", .alignment = .right },
        };

        var table = Table.init(arena, &columns).withStyle(.rounded);
        defer table.deinit();

        for (0..bucket_count) |i| {
            const count = self.counts[i].load(.monotonic);
            const size = self.sizes[i].load(.monotonic);
            const count_pct = percent(count, total_files);
            const size_pct = percent(size, total_size);

            const num_s = std.fmt.allocPrint(arena, "{d}", .{i + 1}) catch continue;
            const count_s = std.fmt.allocPrint(arena, "{f}", .{grouped_int.fmt(count)}) catch continue;
            const count_pct_s = std.fmt.allocPrint(arena, "{d:.2}%", .{count_pct}) catch continue;
            const size_s = std.fmt.allocPrint(arena, "{Bi:.2}", .{size}) catch continue;
            const size_pct_s = std.fmt.allocPrint(arena, "{d:.2}%", .{size_pct}) catch continue;

            table.addRow(&.{ num_s, labels[i], count_s, count_pct_s, size_s, size_pct_s }) catch continue;
        }

        table.render() catch {};
        writer.print("\n", .{}) catch {};
    }
};

fn percent(part: u64, total: u64) f64 {
    if (total == 0) return 0;
    return @as(f64, @floatFromInt(part)) * 100.0 / @as(f64, @floatFromInt(total));
}

test "bucketIndex maps sizes to dirstat-compatible half-open ranges" {
    try std.testing.expectEqual(@as(usize, 0), bucketIndex(0));
    try std.testing.expectEqual(@as(usize, 0), bucketIndex(100 * kib - 1));
    try std.testing.expectEqual(@as(usize, 1), bucketIndex(100 * kib));
    try std.testing.expectEqual(@as(usize, 1), bucketIndex(mib - 1));
    try std.testing.expectEqual(@as(usize, 2), bucketIndex(mib));
    try std.testing.expectEqual(@as(usize, 4), bucketIndex(100 * mib));
    try std.testing.expectEqual(@as(usize, 5), bucketIndex(gib));
    try std.testing.expectEqual(@as(usize, 8), bucketIndex(tib));
    try std.testing.expectEqual(@as(usize, 9), bucketIndex(10 * tib));
    try std.testing.expectEqual(@as(usize, 9), bucketIndex(std.math.maxInt(u64)));
}

test "Histogram.add accumulates count and size per bucket" {
    var h = Histogram.init();
    h.add(10);
    h.add(50);
    h.add(200 * kib);
    try std.testing.expectEqual(@as(u64, 2), h.counts[0].load(.monotonic));
    try std.testing.expectEqual(@as(u64, 60), h.sizes[0].load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), h.counts[1].load(.monotonic));
    try std.testing.expectEqual(@as(u64, 200 * kib), h.sizes[1].load(.monotonic));
}

test "percent is zero when total is zero" {
    try std.testing.expectEqual(@as(f64, 0), percent(0, 0));
    try std.testing.expectEqual(@as(f64, 0), percent(5, 0));
    try std.testing.expectEqual(@as(f64, 50), percent(1, 2));
}
