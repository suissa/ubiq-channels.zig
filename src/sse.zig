const std = @import("std");
const Event = @import("event.zig").Event;
pub fn encode(a: std.mem.Allocator, e: Event, max_bytes: usize) ![]u8 {
    try e.validate(max_bytes);
    if (std.mem.indexOfAny(u8, e.payload, "\r\n") != null) return error.InvalidPayload;
    return std.fmt.allocPrint(a, "id: {s}\nevent: {s}\ndata: {s}\n\n", .{ e.id, e.topic, e.payload });
}
test "SSE frames one event" {
    const e = Event{ .id = "1", .topic = "updated", .payload = "{}" };
    const out = try encode(std.testing.allocator, e, 1024);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("id: 1\nevent: updated\ndata: {}\n\n", out);
}
test "SSE rejects data line injection" {
    const e = Event{ .id = "1", .topic = "updated", .payload = "x\ndata: forged" };
    try std.testing.expectError(error.InvalidPayload, encode(std.testing.allocator, e, 1024));
}
