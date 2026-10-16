#!/usr/bin/env python3
"""Live smoke tests for the TCP server endpoints and push transports."""
import http.client
import socket
import subprocess
import sys
import time

HOST, PORT = "127.0.0.1", 8080

def connect_ready(process):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"server exited with code {process.returncode}")
        try:
            with socket.create_connection((HOST, PORT), timeout=0.2):
                return
        except OSError:
            time.sleep(0.1)
    raise TimeoutError("server did not start listening")

def publish(payload=b'{"smoke":true}'):
    conn = http.client.HTTPConnection(HOST, PORT, timeout=3)
    conn.request("POST", "/publish", body=payload, headers={
        "X-Event-Id": "smoke-1",
        "X-Event-Topic": "smoke",
        "Content-Type": "application/json",
        "Content-Length": str(len(payload)),
    })
    response = conn.getresponse()
    body = response.read()
    conn.close()
    assert response.status == 202, (response.status, body)
    assert b'"accepted":true' in body, body
    return body

def main(binary):
    process = subprocess.Popen([binary], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    sse = None
    ws = None
    try:
        connect_ready(process)
        conn = http.client.HTTPConnection(HOST, PORT, timeout=3)
        conn.request("GET", "/health")
        health = conn.getresponse()
        assert health.status == 200
        assert health.read() == b'{"ok":true}'
        conn.close()

        sse = socket.create_connection((HOST, PORT), timeout=3)
        sse.sendall(b"GET /events HTTP/1.1\r\nHost: localhost\r\nAccept: text/event-stream\r\n\r\n")
        sse_buffer = b""
        while b"\r\n\r\n" not in sse_buffer:
            sse_buffer += sse.recv(4096)
        assert b"200 OK" in sse_buffer.split(b"\r\n\r\n", 1)[0]
        assert b"text/event-stream" in sse_buffer

        ws = socket.create_connection((HOST, PORT), timeout=3)
        ws.sendall((
            "GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
            "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
        ).encode())
        ws_buffer = b""
        while b"\r\n\r\n" not in ws_buffer:
            ws_buffer += ws.recv(4096)
        ws_headers = ws_buffer.split(b"\r\n\r\n", 1)[0]
        assert b"101 Switching Protocols" in ws_headers, ws_headers
        assert b"Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" in ws_headers, ws_headers

        result = publish()
        assert b'"subscribers":2' in result, result
        sse_buffer = sse_buffer.split(b"\r\n\r\n", 1)[1]
        deadline = time.monotonic() + 3
        while b'data: {"smoke":true}\n\n' not in sse_buffer and time.monotonic() < deadline:
            sse_buffer += sse.recv(4096)
        assert b'data: {"smoke":true}\n\n' in sse_buffer, sse_buffer

        ws_buffer = ws_buffer.split(b"\r\n\r\n", 1)[1]
        deadline = time.monotonic() + 3
        while not ws_buffer and time.monotonic() < deadline:
            ws_buffer += ws.recv(4096)
        assert ws_buffer[:1] == b"\x81", ws_buffer
        assert b'{"smoke":true}' in ws_buffer, ws_buffer
        print("Live server smoke tests passed: health, SSE, WebSocket handshake, and event fan-out.")
    finally:
        if sse is not None:
            sse.close()
        if ws is not None:
            ws.close()
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()

if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: live_smoke.py path/to/ubiq-server")
    main(sys.argv[1])