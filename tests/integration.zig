const std = @import("std");
const ubiq = @import("../src/root.zig");
test "integration event payload survives all protocol encoders" {
    const e = ubiq.Event{ .id = "evt-1", .topic = "orders.created", .payload = "{\"order\":42}" };
    const a = try ubiq.sse.encode(std.testing.allocator, e, 1024); defer std.testing.allocator.free(a);
    const b = try ubiq.websocket.encodeEvent(std.testing.allocator, e, 1024); defer std.testing.allocator.free(b);
    const c = try ubiq.http.encodeResponse(std.testing.allocator, e, 1024); defer std.testing.allocator.free(c);
    try std.testing.expect(std.mem.indexOf(u8, a, e.payload) != null);
    try std.testing.expect(std.mem.indexOf(u8, b, e.payload) != null);
    try std.testing.expect(std.mem.endsWith(u8, c, e.payload));
}
