# ubiq-channels.zig

A transport-neutral event channel DSL targeting Zig 0.16, with a POSIX TCP backend for HTTP/1.1, Server-Sent Events (SSE), and WebSocket. Caddy provides the public protocol edge for HTTP/1.1, HTTP/2, and HTTP/3 while proxying requests to the Zig backend.

## Protocol selection

Edit `configs/protocols.yml` to enable or disable the protocols exposed by the Caddy edge:

```yaml
http1: true
http2: true
http3: true
grpc: true
tls_mode: internal
https_host: localhost
https_port: 8443
http_host: localhost
http_port: 8081
backend_host: 127.0.0.1
backend_port: 8080
grpc_host: 127.0.0.1
grpc_port: 9090
```

Regenerate `deploy/Caddyfile` after changing the YAML:

```sh
python3 scripts/render_protocols.py
python3 scripts/render_protocols.py --check
```

CI checks that the committed Caddyfile matches the YAML. HTTP/2 requires HTTP/1.1 to remain enabled in this Caddy setup. Use `tls_mode: internal` for local development or `tls_mode: managed` with a public hostname and publicly trusted TLS.

## HTTP/1.1, HTTP/2, HTTP/3, and gRPC deployment

The Zig process currently speaks HTTP/1.1. Caddy terminates TLS and negotiates HTTP/3 over QUIC, HTTP/2 via ALPN, or HTTP/1.1, then proxies requests to the Zig process. This preserves SSE streaming and WebSocket upgrades while providing modern HTTP protocols at the edge. The Zig listener is **not** a native HTTP/2 or HTTP/3 implementation.

When `grpc: true`, Caddy routes `/ubiq.channels.v1.ChannelService/*` over h2c to the optional Go gRPC bridge on `grpc_host:grpc_port`. The bridge implements the standard gRPC/HTTP2 transport, exposes `ChannelService.Publish(google.protobuf.Struct)`, and forwards event publication to the Zig `/publish` endpoint. It also exposes the standard gRPC health service. The bridge is a separate process; it is not embedded into the Zig binary.

HTTP/3 requires TLS and UDP reachability on the HTTPS port. In production, allow UDP on the HTTPS port through your firewall and load balancer. The local configuration uses port 8443.

Run the Zig server on loopback:

```sh
zig build
./zig-out/bin/ubiq-server
```

In a second terminal, start the optional gRPC bridge (Go 1.24+; it forwards to the Zig HTTP backend):

```sh
cd grpcbridge
go mod tidy
UBIQ_GRPC_ADDR=127.0.0.1:9090 UBIQ_HTTP_BACKEND=http://127.0.0.1:8080/publish go run .
```

Run Caddy with the included configuration (install Caddy first):

```sh
caddy run --config deploy/Caddyfile
```

Endpoints:
- `https://localhost:8443/health` — TLS edge supporting HTTP/3, HTTP/2, and HTTP/1.1 negotiation.
- `https://localhost:8443/ubiq.channels.v1.ChannelService/Publish` — gRPC Publish method (requires the bridge running).
- `http://localhost:8081/health` — plaintext HTTP/1.1 endpoint.
- `GET /events` — persistent SSE stream with event delivery and periodic comment keep-alives.
- `GET /ws` — RFC 6455 WebSocket upgrade on the HTTP/1.1 upstream. Caddy proxies WebSocket upgrades automatically.
- `POST /publish` — publishes the raw request body to currently connected SSE and WebSocket subscribers. Set `X-Event-Id`, `X-Event-Topic`, and `Content-Type`; the body is the event payload.

Check protocol negotiation with a curl build that supports the relevant protocols:

```sh
curl -k --http2 -I https://localhost:8443/health
curl -k --http3-only -I https://localhost:8443/health
```

The `-k` flag is only for local development with Caddy's internal certificate. HTTP/3 testing also requires a curl build with HTTP/3 support and UDP connectivity to port 8443.

Call gRPC Publish with `grpcurl` (from the repository root; Caddy's local certificate is self-signed):

```sh
grpcurl -insecure -import-path . -proto proto/channel.proto \
  -d '{"id":"evt-1","topic":"orders.created","content_type":"application/json","payload":"{\"order\":42}"}' \
  localhost:8443 ubiq.channels.v1.ChannelService/Publish
```

The request uses `google.protobuf.Struct` fields `id`, `topic`, `payload`, and optional `content_type`. The response contains `accepted`, `subscribers`, and `backend_status`. Set `grpc: false` in `configs/protocols.yml` and regenerate the Caddyfile to disable the gRPC route.

Publish through the local TLS edge:

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

The Zig backend uses a bounded in-memory subscriber table (128 clients), HTTP/1.1 without TLS, and a simple request parser. Caddy provides TLS and external HTTP/1.1, HTTP/2, and HTTP/3 negotiation; it does not make the Zig process a native HTTP/2 or HTTP/3 server. SSE is configured for immediate proxy flushing, and WebSocket upgrade forwarding is handled by Caddy over HTTP/1.1. Add authentication/authorization around `/publish`, apply connection/rate limits, and perform deployment-specific load and soak tests before public exposure. There is no durable replay, delivery acknowledgement, idempotency, or guaranteed delivery to disconnected subscribers.
