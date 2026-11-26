import subprocess
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class HelloWorldHandler(BaseHTTPRequestHandler):
    server_version = "HelloWorld"
    sys_version = ""
    # masking server and system version information for security purposes

    def do_GET(self):
        # Route requests to / (hello-world output) or /healthz (health probe)
        if self.path == "/healthz":
            body = b"ok\n"
        elif self.path == "/":
            # The /hello binary is extracted from library/hello-world in the Dockerfile.
            # This wrapper executes it on-demand and returns its output over HTTP,
            # satisfying both the requirement to use the official image and
            # the requirement to expose a publicly accessible HTTP endpoint.
            hello_binary = "/hello"
            if os.path.exists(hello_binary):
                try:
                    result = subprocess.run([hello_binary], capture_output=True, timeout=5)
                    body = result.stdout
                except Exception as e:
                    self.send_error(500)
                    return
            else:
                # For local testing on Windows/Mac where /hello doesn't exist
                body = b"Hello from hello-world!\n"
        else:
            self.send_error(404)
            return

        content_type = "text/plain; charset=utf-8"
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), HelloWorldHandler).serve_forever()
