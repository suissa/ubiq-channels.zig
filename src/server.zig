const std = @import("std");
const Event = @import("event.zig").Event;
const sse = @import("sse.zig");
const websocket = @import("websocket.zig");

const c_int = i32;
const SockLen = u32;
const AF_INET: c_int = 2;
const SOCK_STREAM: c_int = 1;
const SOL_SOCKET: c_int = 1;
const SO_REUSEADDR: c_int = 2;
const MSG_PEEK: c_int = 2;
const MSG_DONTWAIT: c_int = 0x40;

extern "c" fn socket(c_int, c_int, c_int) c_int;
extern "c" fn setsockopt(c_int, c_int, c_int, *const anyopaque, SockLen) c_int;
extern "c" fn bind(c_int, *const anyopaque, SockLen) c_int;
extern "c" fn listen(c_int, c_int) c_int;
extern "c" fn accept(c_int, ?*anyopaque, ?*SockLen) c_int;
extern "c" fn recv(c_int, *anyopaque, usize, c_int) isize;
extern "c" fn send(c_int, *const anyopaque, usize, c_int) isize;
extern "c" fn close(c_int) c_int;

const SockAddrIn = extern struct {
    family: u16,
    port: u16,
    addr: u32,
    zero: [8]u8 = [_]u8{0} ** 8,
};

const ClientKind = enum { sse, ws };
const Client = struct { fd: c_int, kind: ClientKind };
const max_clients = 128;
const max_request_bytes = 1024 * 1024 + 16384;

pub const Config = struct {
    host_octets: [4]u8 = .{ 127, 0, 0, 1 },
    port: u16 = 8080,
    max_payload_bytes: usize = 1024 * 1024,
    backlog: c_int = 128,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    config: Config,
    mutex: std.Thread.Mutex = .{},
    clients: [max_clients]?Client = [_]?Client{null} ** max_clients,

    pub fn init(allocator: std.mem.Allocator, config: Config) Server {
        return .{ .allocator = allocator, .config = config };
    }

    /// Blocks accepting HTTP/1.1 connections. Run behind a TLS reverse proxy in production.
    pub fn listenAndServe(self: *Server) !void {
        const fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return error.SocketCreateFailed;
        defer _ = close(fd);
        const reuse: c_int = 1;
        if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, @sizeOf(c_int)) != 0)
            return error.SocketOptionFailed;
        const address = SockAddrIn{
            .family = AF_INET,
            .port = std.mem.nativeToBig(u16, self.config.port),
            .addr = @bitCast([_]u8{ self.config.host_octets[0], self.config.host_octets[1], self.config.host_octets[2], self.config.host_octets[3] }),
        };
        if (bind(fd, &address, @sizeOf(SockAddrIn)) != 0) return error.BindFailed;
        if (listen(fd, self.config.backlog) != 0) return error.ListenFailed;
        while (true) {
            const client_fd = accept(fd, null, null);
            if (client_fd < 0) continue;
            const args = self.allocator.create(Connection) catch {
                _ = close(client_fd);
                continue;
            };
            args.* = .{ .server = self, .fd = client_fd };
            const thread = std.Thread.spawn(.{}, connectionMain, .{args}) catch {
                self.allocator.destroy(args);
                _ = close(client_fd);
                continue;
            };
            thread.detach();
        }
    }

    fn addClient(self: *Server, fd: c_int, kind: ClientKind) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.clients) |*slot| {
            if (slot.* == null) {
                slot.* = .{ .fd = fd, .kind = kind };
                return true;
            }
        }
        return false;
    }

    fn removeClient(self: *Server, fd: c_int) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.clients) |*slot| {
            if (slot.*) |client| {
                if (client.fd == fd) slot.* = null;
            }
        }
    }

    fn sendToClient(self: *Server, fd: c_int, bytes: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.clients) |slot| {
            if (slot) |client| {
                if (client.fd == fd) return sendAll(fd, bytes);
            }
        }
        return false;
    }

    fn publish(self: *Server, event: Event) !usize {
        const sse_bytes = try sse.encode(self.allocator, event, self.config.max_payload_bytes);
        defer self.allocator.free(sse_bytes);
        const ws_bytes = try websocket.encodeEvent(self.allocator, event, self.config.max_payload_bytes);
        defer self.allocator.free(ws_bytes);
        var delivered: usize = 0;
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.clients) |*slot| {
            if (slot.*) |client| {
                const bytes = if (client.kind == .sse) sse_bytes else ws_bytes;
                const written = sendAll(client.fd, bytes);
                if (written) delivered += 1 else slot.* = null;
            }
        }
        return delivered;
    }
};

const Connection = struct { server: *Server, fd: c_int };

fn connectionMain(args: *Connection) void {
    const server = args.server;
    const fd = args.fd;
    server.allocator.destroy(args);
    defer _ = close(fd);
    handleConnection(server, fd) catch {};
    server.removeClient(fd);
}

fn sendAll(fd: c_int, bytes: []const u8) bool {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = send(fd, bytes[offset..].ptr, bytes.len - offset, 0);
        if (n <= 0) return false;
        offset += @intCast(n);
    }
    return true;
}

fn sendText(fd: c_int, bytes: []const u8) void {
    _ = sendAll(fd, bytes);
}

fn recvExact(fd: c_int, out: []u8) !void {
    var offset: usize = 0;
    while (offset < out.len) {
        const n = recv(fd, out[offset..].ptr, out.len - offset, 0);
        if (n <= 0) return error.ConnectionClosed;
        offset += @intCast(n);
    }
}

fn findHeader(request: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, request, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name))
            return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

fn headerContains(request: []const u8, name: []const u8, expected: []const u8) bool {
    const value = findHeader(request, name) orelse return false;
    var pieces = std.mem.splitScalar(u8, value, ',');
    while (pieces.next()) |piece| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, piece, " "), expected)) return true;
    }
    return false;
}

fn readRequest(allocator: std.mem.Allocator, fd: c_int, limit: usize) ![]u8 {
    var buffer = try allocator.alloc(u8, limit);
    errdefer allocator.free(buffer);
    var used: usize = 0;
    var header_end: ?usize = null;
    var expected_total: ?usize = null;
    while (used < limit) {
        const n = recv(fd, buffer[used..].ptr, limit - used, 0);
        if (n <= 0) return error.IncompleteRequest;
        used += @intCast(n);
        if (header_end == null) {
            if (std.mem.indexOf(u8, buffer[0..used], "\r\n\r\n")) |at| {
                header_end = at + 4;
                const header = buffer[0..at];
                var content_length: usize = 0;
                if (findHeader(header, "Content-Length")) |value| {
                    content_length = std.fmt.parseInt(usize, value, 10) catch return error.InvalidContentLength;
                }
                if (content_length > limit - at - 4) return error.PayloadTooLarge;
                expected_total = at + 4 + content_length;
            }
        }
        if (expected_total) |total| {
            if (used >= total) return buffer[0..total];
        }
    }
    return error.RequestTooLarge;
}

fn handleConnection(server: *Server, fd: c_int) !void {
    const request = try readRequest(server.allocator, fd, @min(max_request_bytes, server.config.max_payload_bytes + 16384));
    defer server.allocator.free(request);
    const header_end = (std.mem.indexOf(u8, request, "\r\n\r\n") orelse return error.InvalidRequest) + 4;
    const header = request[0 .. header_end - 4];
    if (findHeader(header, "Transfer-Encoding") != null) {
        sendText(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    }
    var first = std.mem.splitSequence(u8, header, "\r\n");
    const line = first.next() orelse return error.InvalidRequest;
    var parts = std.mem.splitScalar(u8, line, ' ');
    const method = parts.next() orelse return error.InvalidRequest;
    const path = parts.next() orelse return error.InvalidRequest;
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/health")) {
        sendText(fd, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n{\"ok\":true}");
        return;
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/events")) {
        sendText(fd, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-cache, no-transform\r\nX-Accel-Buffering: no\r\nConnection: keep-alive\r\n\r\n: connected\n\n");
        if (!server.addClient(fd, .sse)) {
            sendText(fd, ": subscriber-capacity-reached\n\n");
            return;
        }
        while (true) {
            std.Thread.sleep(15 * std.time.ns_per_s);
            if (!server.sendToClient(fd, ": keep-alive\n\n")) break;
        }
        return;
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/ws")) {
        try websocketUpgrade(server, fd, header);
        return;
    }
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/publish")) {
        const id = findHeader(header, "X-Event-Id") orelse {
            sendText(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            return;
        };
        const topic = findHeader(header, "X-Event-Topic") orelse {
            sendText(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            return;
        };
        const content_type = findHeader(header, "Content-Type") orelse "application/json";
        const request_body = request[header_end..];
        const event = Event{ .id = id, .topic = topic, .content_type = content_type, .payload = request_body };
        const delivered = server.publish(event) catch {
            sendText(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            return;
        };
        const response_body = try std.fmt.allocPrint(server.allocator, "{{\"accepted\":true,\"subscribers\":{d}}}", .{delivered});
        defer server.allocator.free(response_body);
        const response = try std.fmt.allocPrint(server.allocator, "HTTP/1.1 202 Accepted\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n{s}", .{ response_body.len, response_body });
        defer server.allocator.free(response);
        sendText(fd, response);
        return;
    }
    sendText(fd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
}

fn websocketUpgrade(server: *Server, fd: c_int, request: []const u8) !void {
    if (!headerContains(request, "Upgrade", "websocket") or
        !headerContains(request, "Connection", "Upgrade") or
        !(findHeader(request, "Sec-WebSocket-Version") != null and std.mem.eql(u8, findHeader(request, "Sec-WebSocket-Version").?, "13")))
    {
        sendText(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    }
    const key = findHeader(request, "Sec-WebSocket-Key") orelse {
        sendText(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    };
    if (key.len > 128) return error.InvalidWebSocketKey;
    const joined = try std.mem.concat(server.allocator, u8, &.{ key, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11" });
    defer server.allocator.free(joined);
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(joined, &digest, .{});
    const encoder = std.base64.standard.Encoder;
    const encoded = try server.allocator.alloc(u8, encoder.calcSize(digest.len));
    defer server.allocator.free(encoded);
    _ = encoder.encode(encoded, &digest);
    const response = try std.fmt.allocPrint(server.allocator, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{encoded});
    defer server.allocator.free(response);
    if (!server.addClient(fd, .ws)) {
        sendText(fd, "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    }
    if (!sendAll(fd, response)) return error.ConnectionClosed;
    var frame_header: [2]u8 = undefined;
    while (true) {
        try recvExact(fd, &frame_header);
        const opcode = frame_header[0] & 0x0f;
        if ((frame_header[0] & 0x70) != 0 or (frame_header[0] & 0x80) == 0)
            return error.UnsupportedWebSocketFragment;
        const masked = (frame_header[1] & 0x80) != 0;
        if (!masked) return error.UnmaskedClientFrame;
        var payload_len: usize = frame_header[1] & 0x7f;
        if (payload_len == 126) {
            var ext: [2]u8 = undefined;
            try recvExact(fd, &ext);
            payload_len = (@as(usize, ext[0]) << 8) | ext[1];
        } else if (payload_len == 127) {
            var ext: [8]u8 = undefined;
            try recvExact(fd, &ext);
            payload_len = 0;
            for (ext) |byte| payload_len = (payload_len << 8) | byte;
        }
        if (payload_len > server.config.max_payload_bytes or payload_len > 65536) return error.PayloadTooLarge;
        if (opcode >= 8 and payload_len > 125) return error.InvalidControlFrame;
        var mask: [4]u8 = undefined;
        try recvExact(fd, &mask);
        const payload = try server.allocator.alloc(u8, payload_len);
        defer server.allocator.free(payload);
        var got: usize = 0;
        while (got < payload_len) {
            const read = recv(fd, payload[got..].ptr, payload_len - got, 0);
            if (read <= 0) return error.InvalidWebSocketFrame;
            got += @intCast(read);
        }
        for (payload, 0..) |*byte, i| byte.* ^= mask[i % 4];
        if (opcode == 8) {
            _ = sendAll(fd, &.{ 0x88, 0x00 });
            return;
        }
        if (opcode == 9) {
            const pong = try websocket.encodeControlFrame(server.allocator, 10, payload);
            defer server.allocator.free(pong);
            if (!server.sendToClient(fd, pong)) return error.ConnectionClosed;
        } else if (opcode != 1 and opcode != 2 and opcode != 10) return error.InvalidWebSocketOpcode;
    }
}

test "server defaults to loopback and has bounded subscribers" {
    const s = Server.init(std.testing.allocator, .{});
    try std.testing.expectEqual(@as(u16, 8080), s.config.port);
    try std.testing.expectEqual(@as(usize, 128), s.clients.len);
}
