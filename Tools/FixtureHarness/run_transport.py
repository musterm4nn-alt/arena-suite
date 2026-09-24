"""Loopback-only synthetic HTTP/WS server; never accepts Arena credentials or URLs."""

import base64
import gzip
import hashlib
import pathlib
import socketserver
import subprocess
import threading
import time

BODY = "data: café\r\n\r\n: synthetic\n\ndata: tail".encode()
redirect_hits = []


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(10)
        request = self.rfile.readline().decode("ascii").split()
        if len(request) != 3:
            return
        headers = {}
        while line := self.rfile.readline():
            if line == b"\r\n":
                break
            key, value = line.decode("ascii").split(":", 1)
            headers[key.lower()] = value.strip()
        path = request[1]
        if headers.get("content-length"):
            self.rfile.read(int(headers["content-length"]))
        if path in ("/ws", "/ws-below-limit", "/ws-above-limit"):
            key = headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
            accept = base64.b64encode(hashlib.sha1(key.encode()).digest())
            self.wfile.write(
                b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: "
                + accept
                + b"\r\n\r\n"
            )
            if path == "/ws":
                # Text fragmented inside a UTF-8 scalar, ping between fragments, then binary.
                self.wfile.write(
                    b"\x01\x04caf\xc3\x89\x01p\x80\x01\xa9\x82\x03\x00\xff\x01"
                )
            else:
                # Each frame is 64 bytes, below the client's 1 KiB message limit.
                # Total binary message: 512 bytes (accepted) or 2048 (rejected).
                frames = 8 if path == "/ws-below-limit" else 32
                for index in range(frames):
                    opcode = 2 if index == 0 else 0
                    final = 0x80 if index == frames - 1 else 0
                    self.wfile.write(bytes([opcode | final, 64]) + b"x" * 64)
            self.wfile.flush()
            try:
                self.rfile.read(1)  # Wait for pong/close; bounded by socket timeout.
            except TimeoutError:
                pass
            return
        body = BODY
        extra = b""
        status = b"200 OK"
        if path in ("/redirect", "/redirect-307", "/redirect-308"):
            status = {
                "/redirect": b"302 Found",
                "/redirect-307": b"307 Temporary Redirect",
                "/redirect-308": b"308 Permanent Redirect",
            }[path]
            extra = f"Location: http://localhost:{self.server.server_address[1]}/redirect-target\r\n".encode()
            body = b""
        elif path == "/redirect-target":
            redirect_hits.append(True)
            body = b"unexpected"
        elif path in ("/set-a", "/set-b"):
            value = "A" if path == "/set-a" else "B"
            extra = f"Set-Cookie: probe={value}; Path=/; HttpOnly\r\n".encode()
            body = b""
        elif path == "/cookies":
            body = headers.get("cookie", "").encode()
        elif path == "/gzip":
            body = gzip.compress(BODY, mtime=0)
            extra = b"Content-Encoding: gzip\r\n"
        elif path == "/large":
            body = b"x" * 65536
        elif path == "/cancel-prefix":
            self.wfile.write(
                b"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: text/event-stream\r\nContent-Length: 999\r\n\r\n"
                + BODY
            )
            self.wfile.flush()
            time.sleep(4)
            return
        elif path == "/truncated":
            self.wfile.write(
                b"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: text/event-stream\r\nContent-Length: 999\r\n\r\n"
                + BODY
            )
            self.wfile.flush()
            # Allow Foundation to deliver the prefix before the intentional premature EOF.
            time.sleep(0.5)
            return
        elif path == "/trailers":
            self.wfile.write(
                b"HTTP/1.1 200 OK\r\nConnection: close\r\nTransfer-Encoding: chunked\r\nTrailer: X-Trailer\r\nX-Probe: first\r\nX-Probe: second\r\n\r\n"
            )
            self.wfile.write(
                f"{len(body):x}\r\n".encode()
                + body
                + b"\r\n0\r\nX-Trailer: final\r\n\r\n"
            )
            return
        self.wfile.write(
            b"HTTP/1.1 "
            + status
            + b"\r\nConnection: close\r\n"
            + extra
            + f"Content-Length: {len(body)}\r\n\r\n".encode()
        )
        if path == "/fragmented":
            for byte in body:
                self.wfile.write(bytes([byte]))
                self.wfile.flush()
        else:
            self.wfile.write(body)


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True


if __name__ == "__main__":
    root = pathlib.Path(__file__).resolve().parent
    subprocess.run(["swift", "build", "--package-path", str(root)], check=True)
    binary_dir = subprocess.check_output(
        ["swift", "build", "--package-path", str(root), "--show-bin-path"], text=True
    ).strip()
    with Server(("127.0.0.1", 0), Handler) as server:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            subprocess.run(
                [
                    str(pathlib.Path(binary_dir) / "TransportProbe"),
                    str(server.server_address[1]),
                ],
                check=True,
                timeout=45,
            )
            assert not redirect_hits, "Redirect target received a request"
            print("redirect: refused; target received no request")
        finally:
            server.shutdown()
