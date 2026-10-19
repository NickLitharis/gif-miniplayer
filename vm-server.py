#!/usr/bin/env python3
"""Serves the GifMiniPlayer bundle to the vmnet8 guest and receives results.

Binds only the vmnet8 host address (192.168.103.1), so only the VM can reach it --
same confinement as the Aegis harness on port 8000.

  GET  /<file>            -> served from serve/
  POST /upload?name=foo   -> body saved to uploads/foo
"""
import os
import time
import urllib.parse
import http.server

SERVE = "/home/marocos/win11-vm/serve"
UPLOADS = "/home/marocos/win11-vm/uploads"
BIND = ("192.168.103.1", 8001)

os.makedirs(UPLOADS, exist_ok=True)


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=SERVE, **kwargs)

    def log_message(self, fmt, *args):
        print(f"{time.strftime('%H:%M:%S')} {self.address_string()} {fmt % args}", flush=True)

    def do_POST(self):  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/upload":
            self.send_error(404, "unknown endpoint")
            return
        query = urllib.parse.parse_qs(parsed.query)
        name = os.path.basename((query.get("name") or ["upload.bin"])[0])
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        path = os.path.join(UPLOADS, name)
        with open(path, "wb") as fh:
            fh.write(body)
        print(f"UPLOAD -> {path} ({len(body)} bytes)", flush=True)
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"ok")


if __name__ == "__main__":
    http.server.ThreadingHTTPServer.allow_reuse_address = True
    with http.server.ThreadingHTTPServer(BIND, Handler) as httpd:
        print(f"serving {SERVE} on {BIND[0]}:{BIND[1]}", flush=True)
        httpd.serve_forever()
