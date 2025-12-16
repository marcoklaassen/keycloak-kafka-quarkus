#!/usr/bin/env python3
"""
Keycloak 500 Error Proxy (Reverse Proxy)
This proxy forwards requests to the real Keycloak instance, but returns 500 errors
for specific endpoints (like /token/introspect) to simulate the customer scenario.
"""

import http.server
import socketserver
import ssl
import sys
import os
import urllib.request
import urllib.parse
from urllib.parse import urlparse

# Store Keycloak URL as a module-level variable
_keycloak_url = None

class Keycloak500Handler(http.server.BaseHTTPRequestHandler):
    """HTTP handler that acts as reverse proxy, returning 500 for specific endpoints"""
    
    def log_message(self, format, *args):
        """Override to log requests"""
        print(f"[{self.address_string()}] {format % args}")
    
    def should_return_500(self, path):
        """Determine if this path should return 500 error"""
        # Always return 500 for token introspection endpoint (matches customer scenario)
        if '/token/introspect' in path:
            return True, 'introspect'
        
        # Optionally return 500 for token endpoint (for getting new tokens)
        # Set FAIL_TOKEN_ENDPOINT=true to enable this
        if os.getenv('FAIL_TOKEN_ENDPOINT', 'false').lower() == 'true':
            if '/token' in path and '/introspect' not in path:
                return True, 'token'
        
        # For all other endpoints, return 500 if FAIL_ALL is set
        if os.getenv('FAIL_ALL', 'false').lower() == 'true':
            return True, 'all'
        
        return False, None
    
    def forward_request(self):
        """Forward the request to the real Keycloak instance"""
        global _keycloak_url
        if not _keycloak_url:
            print("ERROR: Keycloak URL not configured")
            self.send_error(500, "Proxy misconfigured")
            return
        
        # Build the target URL (path includes query string if present)
        target_url = f"{_keycloak_url}{self.path}"
        
        print(f"Forwarding {self.command} {self.path} to {target_url}")
        
        try:
            # Read request body if present
            content_length = int(self.headers.get('Content-Length', 0))
            body = None
            if content_length > 0:
                body = self.rfile.read(content_length)
            
            # Create request
            req = urllib.request.Request(target_url, data=body, method=self.command)
            
            # Copy headers (except Host and Connection)
            # Content-Length and Content-Type will be set automatically by urllib if body is provided
            for header, value in self.headers.items():
                header_lower = header.lower()
                if header_lower not in ['host', 'connection', 'content-length']:
                    req.add_header(header, value)
            
            # Set Host header to match the target URL's hostname
            # Extract hostname from target URL
            parsed_url = urlparse(target_url)
            req.add_header('Host', parsed_url.netloc)
            
            # Set Content-Type if not already set and we have a body
            if body and not req.has_header('Content-Type'):
                req.add_header('Content-Type', 'application/x-www-form-urlencoded')
            
            # Disable SSL verification (since we're in-cluster and using self-signed certs)
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            # Use TLS 1.2 or higher
            ctx.minimum_version = ssl.TLSVersion.TLSv1_2
            
            # Make the request
            with urllib.request.urlopen(req, context=ctx, timeout=30) as response:
                # Copy response status
                self.send_response(response.getcode())
                
                # Copy response headers
                for header, value in response.headers.items():
                    if header.lower() not in ['connection', 'transfer-encoding']:
                        self.send_header(header, value)
                
                self.end_headers()
                
                # Copy response body
                response_body = response.read()
                self.wfile.write(response_body)
                
                print(f"Forwarded {self.command} {self.path} -> {response.getcode()}")
        
        except urllib.error.HTTPError as e:
            # Forward HTTP errors from Keycloak
            error_body = e.read()
            self.send_response(e.code)
            for header, value in e.headers.items():
                if header.lower() not in ['connection', 'transfer-encoding']:
                    self.send_header(header, value)
            self.end_headers()
            self.wfile.write(error_body)
            print(f"Forwarded {self.command} {self.path} -> {e.code} (error from Keycloak)")
        
        except Exception as e:
            import traceback
            print(f"ERROR forwarding request: {e}")
            print(f"Traceback: {traceback.format_exc()}")
            self.send_error(502, f"Bad Gateway: {str(e)}")
    
    def do_GET(self):
        """Handle GET requests"""
        should_fail, reason = self.should_return_500(self.path)
        if should_fail:
            self.send_error_response(reason)
        else:
            self.forward_request()
    
    def do_POST(self):
        """Handle POST requests - this is where token introspection happens"""
        should_fail, reason = self.should_return_500(self.path)
        if should_fail:
            self.send_error_response(reason)
        else:
            self.forward_request()
    
    def do_PUT(self):
        """Handle PUT requests"""
        should_fail, reason = self.should_return_500(self.path)
        if should_fail:
            self.send_error_response(reason)
        else:
            self.forward_request()
    
    def do_DELETE(self):
        """Handle DELETE requests"""
        should_fail, reason = self.should_return_500(self.path)
        if should_fail:
            self.send_error_response(reason)
        else:
            self.forward_request()
    
    def send_error_response(self, reason='unknown'):
        """Send a 500 Internal Server Error response matching Keycloak's format"""
        # Match the exact error format from customer logs
        if reason == 'introspect':
            error_body = b'{"error":"unknown_error","error_description":"For more on this error consult the server log."}'
        else:
            error_body = b'{"error":"internal_server_error","error_description":"Simulated Keycloak outage - returning 500 error"}'
        
        self.send_response(500)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(error_body)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(error_body)
        
        # Log the request
        print(f"Returned 500 for: {self.command} {self.path} (reason: {reason})")

def main():
    global _keycloak_url
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    
    # Get Keycloak URL from environment
    _keycloak_url = os.getenv('KEYCLOAK_URL', 'https://keycloak-qkk.apps.ocp4.klaassen.click')
    
    # Remove trailing slash
    _keycloak_url = _keycloak_url.rstrip('/')
    
    print(f"Keycloak 500 Proxy starting on HTTP port {port}")
    print(f"Forwarding requests to: {_keycloak_url}")
    print("Returning 500 for: /token/introspect endpoint")
    print("Other endpoints will be forwarded to Keycloak")
    
    with socketserver.TCPServer(("", port), Keycloak500Handler) as httpd:
        print(f"Proxy ready. Listening on port {port}")
        httpd.serve_forever()

if __name__ == "__main__":
    main()

