const std = @import("std");
const ubiq = @import("ubiq");

test "security rejects channel identity injection" {
    const app = ubiq.App.init(std.testing.allocator);
    try std.testing.expectError(error.InvalidChannelIdentity, app.channel("x\r\nX: y").transport(.sse).build());
}

test "security rejects empty channel identity and missing transport" {
    const app = ubiq.App.init(std.testing.allocator);
    try std.testing.expectError(error.InvalidChannelIdentity, app.channel("").transport(.sse).build());
    try std.testing.expectError(error.NoTransportConfigured, app.channel("valid:channel").build());
}

test "security rejects oversized payloads on all encoders" {
    const e = ubiq.Event{ .id = "e", .topic = "t", .payload = "123456" };
    try std.testing.expectError(error.PayloadTooLarge, ubiq.sse.encode(std.testing.allocator, e, 5));
    try std.testing.expectError(error.PayloadTooLarge, ubiq.websocket.encodeTextFrame(std.testing.allocator, e.payload, 5));
    try std.testing.expectError(error.PayloadTooLarge, ubiq.http.encodeResponse(std.testing.allocator, e, 5));
}

test "security rejects HTTP content type header injection" {
    const e = ubiq.Event{ .id = "e", .topic = "t", .content_type = "application/json\r\nX-Injected: yes", .payload = "{}" };
    try std.testing.expectError(error.InvalidEvent, ubiq.http.encodeResponse(std.testing.allocator, e, 1024));
}
