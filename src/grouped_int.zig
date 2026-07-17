const std = @import("std");

/// Thin wrapper so `{f}` prints `n` with comma thousands separators (`1,234,567`).
pub fn fmt(n: u64) Formattable {
    return .{ .n = n };
}

pub const Formattable = struct {
    n: u64,

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [32]u8 = undefined;
        const slice = bufPrint(&buf, self.n);
        try writer.writeAll(slice);
    }
};

/// Writes into `buf` (needs at least 26 bytes for `u64`) and returns the used slice.
pub fn bufPrint(buf: []u8, value: u64) []u8 {
    std.debug.assert(buf.len >= 26);
    var i: usize = buf.len;
    var n = value;
    var digits: usize = 0;
    while (true) {
        i -= 1;
        buf[i] = @intCast('0' + (n % 10));
        n /= 10;
        digits += 1;
        if (n == 0) break;
        if (digits % 3 == 0) {
            i -= 1;
            buf[i] = ',';
        }
    }
    return buf[i..];
}

test "bufPrint groups thousands with commas" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0", bufPrint(&buf, 0));
    try std.testing.expectEqualStrings("12", bufPrint(&buf, 12));
    try std.testing.expectEqualStrings("999", bufPrint(&buf, 999));
    try std.testing.expectEqualStrings("1,000", bufPrint(&buf, 1000));
    try std.testing.expectEqualStrings("12,345", bufPrint(&buf, 12345));
    try std.testing.expectEqualStrings("1,234,567", bufPrint(&buf, 1_234_567));
    try std.testing.expectEqualStrings("1,422,801", bufPrint(&buf, 1_422_801));
    try std.testing.expectEqualStrings(
        "18,446,744,073,709,551,615",
        bufPrint(&buf, std.math.maxInt(u64)),
    );
}
