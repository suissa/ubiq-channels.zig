const std = @import("std");
const ubiq = @import("ubiq");

pub fn main() !void {
    var server = ubiq.server.Server.init(std.heap.page_allocator, .{});
    try server.listenAndServe();
}
