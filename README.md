# ubiq-channels.zig

A transport-neutral event channel DSL targeting Zig 0.16, with a POSIX TCP backend for HTTP/1.1, Server-Sent Events (SSE), and WebSocket. The repository also includes a Caddy edge configuration that exposes HTTP/2 over TLS and HTTP/1.1, while proxying to the Zig backend.

## HTTP/2 and HTTP/1.1 deployment

The Zig process currently speaks HTTP/1.1. HTTP/2 is provided at the edge by Caddy, which terminates TLS, negotiates HTTP/2 or HTTP/1.1 via ALPN, and proxies requests to the Zig process. This is a deliberate protocol boundary: the current Zig listener is **not** a native HTTP/2 implementation.

Run the Zig server on loopback:

```sh
zig build
./zig-out/bin/ubiq-server
```

Run Caddy with the included configuration (install Caddy first):

```sh
caddy run --config deploy/Caddyfile
```

Endpoints:
- `https://localhost:8443/health` — TLS endpoint that negotiates HTTP/2 when the client supports it, otherwise HTTP/1.1.
- `http://localhost:8081/health` — plaintext HTTP/1.1 endpoint.
- `GET /events` — persistent SSE stream with event delivery and periodic comment keep-alives.
- `GET /ws` — RFC 6455 WebSocket upgrade on the HTTP/1.1 upstream. Caddy proxies WebSocket upgrades automatically.
- `POST /publish` — publishes the raw request body to currently connected SSE and WebSocket subscribers. Set `X-Event-Id`, `X-Event-Topic`, and `Content-Type`; the body is the event payload.

Publish through the local TLS edge (the `-k` flag is only for local development with Caddy's internal certificate):

```sh
curl -k -i -X POST https://localhost:8443/publish \
  -H 'X-Event-Id: evt-1' \
  -H 'X-Event-Topic: orders.created' \
  -H 'Content-Type: application/json' \
  --data-binary '{"order":42}'
```

For production, replace `localhost` in `deploy/Caddyfile` with a domain you control and configure valid TLS. Do not expose the Zig backend port directly to the internet.

## TCP backend endpoints

Exported API: `ubiq.server.Server`. Configure the listener with `ubiq.server.Config` and call `listenAndServe()` from an executable that links libc.

Direct backend requests:
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

The Zig backend uses a bounded in-memory subscriber table (128 clients), HTTP/1.1 without TLS, and a simple request parser. Caddy provides TLS and external HTTP/2 negotiation; it does not make the Zig process a native HTTP/2 server. SSE is configured for immediate proxy flushing, and WebSocket upgrade forwarding is handled by Caddy over HTTP/1.1. Add authentication/authorization around `/publish`, apply connection/rate limits, and perform deployment-specific load and soak tests before public exposure. There is no durable replay, delivery acknowledgement, idempotency, or guaranteed delivery to disconnected subscribers.
