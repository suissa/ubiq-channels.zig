const std = @import("std");
const Event = @import("event.zig").Event;
const sse = @import("sse.zig");
const ws = @import("websocket.zig");
const http = @import("http.zig");
pub const Transport = enum { sse, ws, http };
pub const Sink = *const fn (?*anyopaque, Transport, []const u8) anyerror!void;
pub const App = struct {
    allocator: std.mem.Allocator,
    max_payload_bytes: usize = 1024 * 1024,
    pub fn init(a: std.mem.Allocator) App { return .{ .allocator = a }; }
    pub fn channel(self: App, identity: []const u8) Builder { return .{ .app = self, .identity = identity }; }
};
pub const Builder = struct {
    app: App,
    identity: []const u8,
    transports: [3]Transport = undefined,
    count: usize = 0,
    pub fn transport(self: Builder, t: Transport) Builder {
        var b = self;
        for (b.transports[0..b.count]) |existing| if (existing == t) { return b; };
        if (b.count < b.transports.len) { b.transports[b.count] = t; b.count += 1; }
        return b;
    }
    pub fn build(self: Builder) !Channel {
        if (self.identity.len == 0 or std.mem.indexOfAny(u8, self.identity, "\r\n") != null) return error.InvalidChannelIdentity;
        if (self.count == 0) return error.NoTransportConfigured;
        return .{ .allocator = self.app.allocator, .identity = self.identity, .transports = try self.app.allocator.dupe(Transport, self.transports[0..self.count]), .max_payload_bytes = self.app.max_payload_bytes };
    }
};
pub const Report = struct { attempted: usize = 0, succeeded: usize = 0, failed: usize = 0 };
pub const Channel = struct {
    allocator: std.mem.Allocator,
    identity: []const u8,
    transports: []const Transport,
    max_payload_bytes: usize,
    pub fn deinit(self: Channel) void { self.allocator.free(self.transports); }
    pub fn publish(self: Channel, event: Event, context: ?*anyopaque, sink: Sink) !Report {
        try event.validate(self.max_payload_bytes);
        var r = Report{};
        for (self.transports) |t| {
            const bytes = switch (t) {
                .sse => try sse.encode(self.allocator, event, self.max_payload_bytes),
                .ws => try ws.encodeEvent(self.allocator, event, self.max_payload_bytes),
                .http => try http.encodeResponse(self.allocator, event, self.max_payload_bytes),
            };
            defer self.allocator.free(bytes);
            r.attempted += 1;
            sink(context, t, bytes) catch { r.failed += 1; continue; };
            r.succeeded += 1;
        }
        return r;
    }
};
test "fanout visits each configured transport once" {
    const app = App.init(std.testing.allocator);
    var c = try app.channel("entity:customer:123").transport(.sse).transport(.ws).transport(.http).transport(.ws).build();
    defer c.deinit();
    const Probe = struct {
        n: usize = 0,
        fn sink(ctx: ?*anyopaque, _: Transport, _: []const u8) anyerror!void { const p: *@This() = @ptrCast(@alignCast(ctx.?)); p.n += 1; }
    };
    var p = Probe{};
    const e = Event{ .id = "e1", .topic = "updated", .payload = "{}" };
    const r = try c.publish(e, &p, Probe.sink);
    try std.testing.expectEqual(@as(usize, 3), r.attempted);
    try std.testing.expectEqual(@as(usize, 3), r.succeeded);
    try std.testing.expectEqual(@as(usize, 3), p.n);
}
test "partial sink failure does not stop fanout" {
    const app = App.init(std.testing.allocator);
    var c = try app.channel("customer:1").transport(.sse).transport(.ws).transport(.http).build();
    defer c.deinit();
    const Probe = struct {
        n: usize = 0,
        fn sink(ctx: ?*anyopaque, t: Transport, _: []const u8) anyerror!void { const p: *@This() = @ptrCast(@alignCast(ctx.?)); p.n += 1; if (t == .ws) return error.SimulatedFailure; }
    };
    var p = Probe{};
    const e = Event{ .id = "e2", .topic = "updated", .payload = "{}" };
    const r = try c.publish(e, &p, Probe.sink);
    try std.testing.expectEqual(@as(usize, 2), r.succeeded);
    try std.testing.expectEqual(@as(usize, 1), r.failed);
    try std.testing.expectEqual(@as(usize, 3), p.n);
}
