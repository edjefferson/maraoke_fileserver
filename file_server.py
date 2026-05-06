#!/usr/bin/env python3
"""
Serves ./public on port 8001 with CORS for allowed origins.
No dependencies beyond the Python standard library.

Usage: python3 file_server.py
"""

import http.server
import os
import signal
import sys
from functools import partial

PORT = 8001
ALLOWED_ORIGINS = {
    "http://localhost:3000",
    "https://system.maraoke.com",
}


class CORSHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        origin = self.headers.get("Origin", "")
        if origin in ALLOWED_ORIGINS:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(200)
        self.end_headers()

    def log_message(self, fmt, *args):
        print(f"  {self.address_string()} {fmt % args}")


def main():
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "public")

    if not os.path.isdir(root):
        print(f"⚠️  Directory not found: {root}")
        sys.exit(1)

    handler = partial(CORSHandler, directory=root)

    with http.server.HTTPServer(("0.0.0.0", PORT), handler) as httpd:
        print(f"✅ Serving {root}")
        print(f"   CORS allowed for: {', '.join(sorted(ALLOWED_ORIGINS))}")
        print(f"🌐 http://localhost:{PORT}")
        print("   Ctrl+C to stop.\n")

        def shutdown(sig, frame):
            signal.signal(signal.SIGINT, signal.SIG_DFL)
            print("\n👋 Stopping...")
            httpd.shutdown()

        signal.signal(signal.SIGINT, shutdown)
        httpd.serve_forever()


if __name__ == "__main__":
    main()
