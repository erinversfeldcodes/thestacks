#!/usr/bin/env python3
"""Tiny HTTP mock server for probe-production tests.

    mock_server.py --port 8765 --mode healthy|fail-5xx|blackhole

healthy: everything succeeds (login returns a fake token; the presigned
upload flow answers init 201 → PUT 200 → commit 202).
fail-5xx: --fail-ratio of GET /api/catalogue return 500; auth/health 200.
blackhole: never respond (probe-timeout path). State is in-process;
each test spawns its own instance on its own port.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer


def make_handler(mode: str, fail_ratio: float):
    class Handler(BaseHTTPRequestHandler):
        catalogue_hits = 0

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
                # Deterministic failure schedule: with few samples in a short
                # test window, random draws can produce zero 4xx (or zero 5xx)
                # and flake the assertions that expect both to appear.
                Handler.catalogue_hits += 1
                period = max(2, round(1 / fail_ratio)) if fail_ratio else 0
                failing = period and Handler.catalogue_hits % period == 0
                if mode == "fail-5xx" and failing:
                    self._respond(500, b'{"error":"simulated"}')
                elif mode == "fail-4xx-and-5xx" and period and Handler.catalogue_hits % period < 2:
                    if Handler.catalogue_hits % period == 0:
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
            if self.path.startswith("/api/auth/register"):
                # The probe's first act is asserting the invite gate is ON: a
                # codeless registration must be refused. A healthy production
                # answers 403 invite_required, so the healthy mock must too —
                # without this route the mock's implicit 404 (or a 200) reads
                # as "gate off or broken" and every scenario dies at the gate.
                self._respond(403, b'{"error":"invite_required"}')
                return
            if self.path.startswith("/api/auth/login"):
                if mode == "auth-fail":
                    self._respond(401, b'{"error":"invalid"}')
                else:
                    self._respond(200, b'{"token":"fake-token"}')
                return
            if self.path.startswith("/api/upload/init"):
                # RELATIVE like the real server (Uploads.init_upload returns
                # "/api/upload/:id/data"): the probe must resolve it against
                # the base URL, and an unresolved relative URL fails curl —
                # the exact defect that read a healthy deploy as 47% available.
                image_id = "00000000-0000-0000-0000-000000000000"
                body = json.dumps(
                    {
                        "image_id": image_id,
                        "upload_url": f"/r2/{image_id}",
                        "expires_in": 900,
                    }
                ).encode()
                self._respond(201, body)
                return
            if self.path.startswith("/api/upload/") and self.path.endswith("/commit"):
                self._respond(202, b'{"status":"accepted"}')
                return
            # The retired single-POST /api/upload deliberately 404s, so a probe
            # regression back to the old endpoint fails these tests.
            self._respond(404)

        def do_PUT(self):
            if mode == "blackhole":
                time.sleep(60)
                return
            length = int(self.headers.get("Content-Length", "0") or "0")
            if length:
                self.rfile.read(length)
            if self.path.startswith("/r2/"):
                self._respond(200)
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
