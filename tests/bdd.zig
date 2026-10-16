const std = @import("std");
const ubiq = @import("../src/root.zig");
test "BDD given a customer channel when publishing then all transports are invoked" {
    const app = ubiq.App.init(std.testing.allocator);
    var c = try app.channel("entity:customer:123").transport(.sse).transport(.ws).transport(.http).build();
    defer c.deinit();
    const Probe = struct {
        seen: [3]bool = .{false,false,false},
        fn sink(ctx: ?*anyopaque, t: ubiq.Transport, _: []const u8) anyerror!void {
            const p: *@This() = @ptrCast(@alignCast(ctx.?));
            p.seen[@intFromEnum(t)] = true;
        }
    };
    var p = Probe{};
    const e = ubiq.Event{ .id = "evt-1", .topic = "customer.updated", .payload = "{\"id\":123}" };
    const r = try c.publish(e, &p, Probe.sink);
    try std.testing.expectEqual(@as(usize, 3), r.succeeded);
    try std.testing.expect(p.seen[0] and p.seen[1] and p.seen[2]);
}
