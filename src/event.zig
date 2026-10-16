const std = @import("std");
pub const Event = struct {
    id: []const u8,
    topic: []const u8,
    content_type: []const u8 = "application/json",
    payload: []const u8,
    pub fn validate(self: Event, max_bytes: usize) !void {
        if (self.id.len == 0 or self.topic.len == 0) return error.InvalidEvent;
        if (self.payload.len > max_bytes) return error.PayloadTooLarge;
        if (std.mem.indexOfAny(u8, self.id, "\r\n") != null or
            std.mem.indexOfAny(u8, self.topic, "\r\n") != null or
            std.mem.indexOfAny(u8, self.content_type, "\r\n") != null) return error.InvalidEvent;
    }
};
test "event rejects CRLF header injection" {
    const e = Event{ .id = "x\r\nX: y", .topic = "t", .payload = "{}" };
    try std.testing.expectError(error.InvalidEvent, e.validate(1024));
}
