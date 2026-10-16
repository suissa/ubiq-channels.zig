const std = @import("std");
const ubiq = @import("../src/root.zig");
test "security rejects channel identity injection" {
    const app = ubiq.App.init(std.testing.allocator);
    try std.testing.expectError(error.InvalidChannelIdentity, app.channel("x\r\nX: y").transport(.sse).build());
}
test "security rejects oversized payloads on all encoders" {
    const e = ubiq.Event{ .id = "e", .topic = "t", .payload = "123456" };
    try std.testing.expectError(error.PayloadTooLarge, ubiq.sse.encode(std.testing.allocator, e, 5));
    try std.testing.expectError(error.PayloadTooLarge, ubiq.websocket.encodeTextFrame(std.testing.allocator, e.payload, 5));
    try std.testing.expectError(error.PayloadTooLarge, ubiq.http.encodeResponse(std.testing.allocator, e, 5));
}
