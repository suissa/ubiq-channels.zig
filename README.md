# ubiq-channels.zig

A transport-neutral event channel DSL targeting Zig 0.16, with an initial fan-out core and protocol encoders for SSE, WebSocket server text frames, and HTTP/1.1 responses.

## Implemented

- Fluent channel builder with accumulating, deduplicated transport selections.
- Event fan-out and per-transport success/failure accounting.
- SSE event framing, RFC 6455 server text-frame encoding, and HTTP/1.1 response encoding.
- Payload limits and CR/LF validation for event metadata and HTTP headers.
- Unit, BDD-style, adapter integration, security, and 10,000-event encoding stress tests.
- GitHub Actions CI pinned to Zig 0.16.0.

## Example

    const app = ubiq.App.init(allocator);
    var channel = try app.channel("entity:customer:123")
        .transport(.sse)
        .transport(.ws)
        .transport(.http)
        .build();
    defer channel.deinit();

    const event = ubiq.Event{
        .id = "evt-123",
        .topic = "customer.updated",
        .payload = "{\"customer_id\":123}",
    };
    const report = try channel.publish(event, context, sink);

The sink callback writes encoded bytes to the appropriate connection/session. Transport selections are processed in declaration order; duplicates are ignored. A failed sink is counted and does not stop the remaining transports.

## Test

    zig build test

## Important scope boundary

This initial version is a protocol codec and dispatch core, not yet a network server. It does not accept TCP connections, implement the WebSocket HTTP upgrade handshake, manage persistent SSE subscribers, or send HTTP requests over sockets. The tests cover the byte/protocol boundary, not live-network integration. The load/stress test exercises 10,000 encodings and is not a substitute for concurrent network load or soak testing.

Benchmarks comparing actual transports require a runnable network server, equivalent payloads, controlled concurrency, warm-up, and measured latency/throughput. No benchmark results are claimed until those experiments are executed.

## Security

- Set a conservative max payload size for untrusted events.
- Perform authorization before invoking a sink; no auth provider is implemented yet.
- Use TLS at the server/socket layer.
- Replay, durable delivery, idempotency, acknowledgements, and backpressure are not implemented yet.
