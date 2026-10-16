const std = @import("std");
const Event = @import("event.zig").Event;
pub fn encodeTextFrame(a: std.mem.Allocator, payload: []const u8, max_bytes: usize) ![]u8 {
    if (payload.len > max_bytes) return error.PayloadTooLarge;
    const h: usize = if (payload.len <= 125) 2 else if (payload.len <= 65535) 4 else 10;
    const out = try a.alloc(u8, h + payload.len);
    out[0] = 0x81;
    if (h == 2) {
        out[1] = @intCast(payload.len);
    } else if (h == 4) {
        out[1] = 126;
        out[2] = @intCast((payload.len >> 8) & 255);
        out[3] = @intCast(payload.len & 255);
    } else {
        out[1] = 127;
        for (0..8) |i| out[2 + i] = @intCast((payload.len >> @intCast((7 - i) * 8)) & 255);
    }
    @memcpy(out[h..], payload);
    return out;
}
pub fn encodeEvent(a: std.mem.Allocator, e: Event, max_bytes: usize) ![]u8 {
    try e.validate(max_bytes);
    return encodeTextFrame(a, e.payload, max_bytes);
}
test "WebSocket emits an unmasked server text frame" {
    const out = try encodeTextFrame(std.testing.allocator, "hello", 1024);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(u8, 0x81), out[0]);
    try std.testing.expectEqual(@as(u8, 5), out[1]);
    try std.testing.expectEqualStrings("hello", out[2..]);
}
test "WebSocket extended length for 126 bytes" {
    const p = try std.testing.allocator.alloc(u8, 126);
    defer std.testing.allocator.free(p);
    @memset(p, 'x');
    const out = try encodeTextFrame(std.testing.allocator, p, 1024);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(u8, 126), out[1]);
    try std.testing.expectEqual(@as(u8, 126), out[3]);
}
