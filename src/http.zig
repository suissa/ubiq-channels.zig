const std = @import("std");
const Event = @import("event.zig").Event;
pub fn encodeResponse(a: std.mem.Allocator, e: Event, max_bytes: usize) ![]u8 {
    try e.validate(max_bytes);
    return std.fmt.allocPrint(a, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n{s}", .{ e.content_type, e.payload.len, e.payload });
}
test "HTTP response has content length and no-store" {
    const e = Event{ .id = "1", .topic = "t", .payload = "{\"ok\":true}" };
    const out = try encodeResponse(std.testing.allocator, e, 1024);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Content-Length: 11\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Cache-Control: no-store") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, e.payload));
}
