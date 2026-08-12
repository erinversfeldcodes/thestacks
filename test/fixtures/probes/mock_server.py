#!/usr/bin/env python3
"""Tiny HTTP mock server for probe-production tests.

    mock_server.py --port 8765 --mode healthy|fail-5xx|blackhole

healthy: everything 200 (login returns a fake token, upload 202).
fail-5xx: --fail-ratio of GET /api/catalogue return 500; auth/health 200.
blackhole: never respond (probe-timeout path). State is in-process;
each test spawns its own instance on its own port.
"""

from __future__ import annotations

import argparse
import json
import random
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer


def make_handler(mode: str, fail_ratio: float):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def _record(self, status: int) -> None:
            sys.stdout.write(
                json.dumps(
                    {
                        "method": self.command,
                        "path": self.path,
                        "status": status,
                        "ts": time.time(),
                    }
                )
                + "\n"
            )
            sys.stdout.flush()

        def _respond(self, status: int, body: bytes = b"{}") -> None:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            self._record(status)

        def do_GET(self):
            if mode == "blackhole":
                time.sleep(60)
                return
            if self.path.startswith("/api/health"):
                self._respond(200, b'{"status":"ok"}')
                return
            if self.path.startswith("/api/catalogue"):
                if mode == "fail-5xx" and random.random() < fail_ratio:
                    self._respond(500, b'{"error":"simulated"}')
                elif mode == "fail-4xx-and-5xx" and random.random() < fail_ratio:
                    if random.random() < 0.5:
                        self._respond(500, b'{"error":"simulated"}')
                    else:
                        self._respond(401, b'{"error":"unauthorised"}')
                else:
                    self._respond(200, b'{"items":[]}')
                return
            if self.path.startswith("/api/bookshelves/"):
                self._respond(200, b'{"books":[]}')
                return
            self._respond(404)

        def do_POST(self):
            if mode == "blackhole":
                time.sleep(60)
                return
            length = int(self.headers.get("Content-Length", "0") or "0")
            if length:
                self.rfile.read(length)
            if self.path.startswith("/api/auth/login"):
                if mode == "auth-fail":
                    self._respond(401, b'{"error":"invalid"}')
                else:
                    self._respond(200, b'{"token":"fake-token"}')
                return
            if self.path.startswith("/api/upload"):
                self._respond(202, b'{"image_id":"00000000-0000-0000-0000-000000000000"}')
                return
            self._respond(404)

    return Handler


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument(
        "--mode",
        choices=[
            "healthy",
            "fail-5xx",
            "fail-4xx-and-5xx",
            "blackhole",
            "auth-fail",
        ],
        default="healthy",
    )
    parser.add_argument("--fail-ratio", type=float, default=0.25)
    args = parser.parse_args()

    server = HTTPServer(("127.0.0.1", args.port), make_handler(args.mode, args.fail_ratio))
    sys.stderr.write(f"mock_server listening on 127.0.0.1:{args.port} mode={args.mode}\n")
    sys.stderr.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
