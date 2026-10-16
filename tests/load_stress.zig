const std = @import("std");
const ubiq = @import("../src/root.zig");
test "load stress encodes 10000 events over all adapters" {
    const a = std.testing.allocator;
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        const payload = try std.fmt.allocPrint(a, "{{\"sequence\":{d}}}", .{i}); defer a.free(payload);
        const e = ubiq.Event{ .id = "load", .topic = "load.test", .payload = payload };
        const x = try ubiq.sse.encode(a, e, 1024); defer a.free(x);
        const y = try ubiq.websocket.encodeEvent(a, e, 1024); defer a.free(y);
        const z = try ubiq.http.encodeResponse(a, e, 1024); defer a.free(z);
        try std.testing.expect(x.len > 0 and y.len > 0 and z.len > 0);
    }
}
