# ubiq-channels.zig

A transport-neutral event channel DSL targeting Zig 0.16, with protocol codecs and a POSIX TCP server for HTTP/1.1, Server-Sent Events (SSE), and WebSocket.

## TCP server

The server exposes these endpoints:
- `GET /health` returns a health response.
- `GET /events` opens a persistent SSE stream with event delivery and periodic comment keep-alives.
- `GET /ws` performs the RFC 6455 HTTP Upgrade handshake and keeps a WebSocket session open. Client frames must be masked; close and ping/pong control frames are handled.
- `POST /publish` publishes the raw request body to currently connected SSE and WebSocket subscribers. Set `X-Event-Id`, `X-Event-Topic`, and `Content-Type`; the body is the event payload.

Exported API: `ubiq.server.Server`. Configure the listener with `ubiq.server.Config` and call `listenAndServe()` from an executable that links libc.

Example requests:
```sh
curl -N http://127.0.0.1:8080/events
curl -i -X POST http://127.0.0.1:8080/publish \
  -H 'X-Event-Id: evt-1' \
  -H 'X-Event-Topic: orders.created' \
  -H 'Content-Type: application/json' \
  --data-binary '{"order":42}'
```

## Transport-neutral channel DSL

```zig
const app = ubiq.App.init(allocator);
var channel = try app.channel("entity:customer:123")
    .transport(.sse)
    .transport(.ws)
    .transport(.http)
    .build();
defer channel.deinit();

const event = ubiq.Event{ .id = "evt-123", .topic = "customer.updated", .payload = "{\"customer_id\":123}" };
const report = try channel.publish(event, context, sink);
```

The DSL fan-out core invokes a sink callback in declaration order. The TCP server is a standalone adapter: `/publish` fans out to currently connected SSE and WebSocket clients. The HTTP transport in the DSL remains a one-response encoder rather than a persistent subscriber type.

## Tests

```sh
zig build test
```

The suite covers protocol encoding, fan-out, input validation, and encoding stress. CI pins Zig 0.16.0. The benchmark reporter consumes measurements from an external executable and does not fabricate network benchmark results.

## Operational limits

This is an initial server implementation, not a hardened internet-facing deployment. It uses a bounded in-memory subscriber table (128 clients), HTTP/1.1 without TLS, and a simple request parser. Put it behind a TLS reverse proxy, add authentication/authorization around `/publish`, apply connection/rate limits, and perform deployment-specific load and soak tests before public exposure. There is no durable replay, delivery acknowledgement, idempotency, or guaranteed delivery to disconnected subscribers.