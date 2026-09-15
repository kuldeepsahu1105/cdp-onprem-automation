#!/usr/bin/env python3

import json
import os
import secrets
import threading
import time
from http import cookies
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote


COOKIE_NAME = "portal_session"
SESSION_TTL_SECONDS = int(os.environ.get("PORTAL_SESSION_TTL_SECONDS", "28800"))
SESSIONS = {}
SESSIONS_LOCK = threading.Lock()


def read_session_token(cookie_header):
    jar = cookies.SimpleCookie()
    try:
        jar.load(cookie_header or "")
    except cookies.CookieError:
        return ""
    morsel = jar.get(COOKIE_NAME)
    return morsel.value if morsel else ""


def purge_expired_sessions(now):
    expired = [token for token, expires_at in SESSIONS.items() if expires_at <= now]
    for token in expired:
        SESSIONS.pop(token, None)


class PortalAuthHandler(BaseHTTPRequestHandler):
    server_version = "PortalAuth/1.0"

    def log_message(self, message, *args):
        print(
            "%s - - [%s] %s"
            % (self.client_address[0], self.log_date_time_string(), message % args),
            flush=True,
        )

    def send_result(self, status, payload=None, headers=None):
        body = json.dumps(payload or {}).encode("utf-8")
        self.send_response(status)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def valid_session(self):
        token = read_session_token(self.headers.get("Cookie"))
        if not token:
            return False
        now = time.time()
        with SESSIONS_LOCK:
            purge_expired_sessions(now)
            return SESSIONS.get(token, 0) > now

    def handle_check(self):
        if self.valid_session():
            self.send_result(200, {"authenticated": True})
            return

        if self.headers.get("X-Auth-Mode") == "redirect":
            requested_uri = self.headers.get("X-Forwarded-Uri", "/")
            if not requested_uri.startswith("/downloads/"):
                requested_uri = "/"
            location = "/login.html?next=" + quote(requested_uri, safe="/?=&")
            self.send_result(303, {"authenticated": False}, {"Location": location})
            return

        self.send_result(401, {"authenticated": False})

    def handle_login(self):
        user = self.headers.get("X-Portal-User", "").strip()
        if not user:
            self.send_result(403, {"authenticated": False})
            return

        token = secrets.token_urlsafe(32)
        with SESSIONS_LOCK:
            purge_expired_sessions(time.time())
            SESSIONS[token] = time.time() + SESSION_TTL_SECONDS
        cookie = (
            f"{COOKIE_NAME}={token}; Path=/; HttpOnly; SameSite=Strict; "
            f"Max-Age={SESSION_TTL_SECONDS}"
        )
        self.send_result(
            200,
            {"authenticated": True, "user": user},
            {"Set-Cookie": cookie},
        )

    def handle_logout(self):
        token = read_session_token(self.headers.get("Cookie"))
        if token:
            with SESSIONS_LOCK:
                SESSIONS.pop(token, None)
        expired_cookie = (
            f"{COOKIE_NAME}=; Path=/; HttpOnly; SameSite=Strict; "
            "Max-Age=0"
        )
        self.send_result(
            303,
            {"authenticated": False},
            {"Set-Cookie": expired_cookie, "Location": "/?logged_out=1"},
        )

    def do_GET(self):
        if self.path == "/health":
            self.send_result(200, {"status": "ok"})
        elif self.path == "/check":
            self.handle_check()
        elif self.path == "/logout":
            self.handle_logout()
        else:
            self.send_result(404, {"error": "not_found"})

    def do_POST(self):
        if self.path == "/login":
            self.handle_login()
        elif self.path == "/logout":
            self.handle_logout()
        else:
            self.send_result(404, {"error": "not_found"})


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), PortalAuthHandler).serve_forever()
