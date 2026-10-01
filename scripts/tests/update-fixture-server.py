#!/usr/bin/env python3
"""Loopback fixture for SoftwareUpdateUITests; serves an intentionally invalid update."""
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import time


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path in ("/health", "/appcast.xml"):
            signature = base64.b64encode(bytes(64)).decode()
            body = b"ready" if self.path == "/health" else f'''<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Test</title><item><title>Test update</title><sparkle:version>999999</sparkle:version><sparkle:shortVersionString>99.0.0</sparkle:shortVersionString><sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion><enclosure url="http://127.0.0.1:{self.server.server_port}/Update.zip" length="40960" type="application/octet-stream" sparkle:edSignature="{signature}"/></item></channel></rss>'''.encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/xml")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/Update.zip":
            self.send_response(200)
            self.send_header("Content-Length", "40960")
            self.end_headers()
            try:
                for _ in range(5):
                    time.sleep(0.7)
                    self.wfile.write(bytes(8192))
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            self.send_error(404)


if __name__ == "__main__":
    print("Serving the unsigned update fixture on http://127.0.0.1:18765", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 18765), Handler).serve_forever()
