"""Tiny "internal staging dashboard" used to demonstrate Tailscale Serve.

It contains NO authentication code. Tailscale Serve terminates TLS and, for
requests from user-owned devices, injects identity headers:

    Tailscale-User-Login, Tailscale-User-Name, Tailscale-User-Profile-Pic

Serve strips any client-supplied copies of these headers, and this app binds to
127.0.0.1 inside the sidecar's network namespace, so the headers can be trusted:
there is no path to the app that bypasses Serve.

Requests from tagged nodes (e.g. a CI runner) carry no user identity; the app
reports those callers as "tagged-device".

Endpoints:
    /          HTML page showing who you are
    /whoami    JSON identity (used by scripts/validate.sh)
    /healthz   liveness probe
"""

import html
import json
import os
import socket
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIND_ADDR = os.environ.get("BIND_ADDR", "127.0.0.1")
PORT = int(os.environ.get("PORT", "8080"))
APP_ENV = os.environ.get("APP_ENV", "staging")
HOSTNAME = socket.gethostname()
STARTED = datetime.now(timezone.utc).isoformat(timespec="seconds")


def identity(headers):
    login = headers.get("Tailscale-User-Login")
    return {
        "login": login or "tagged-device",
        "name": headers.get("Tailscale-User-Name") or "",
        "profile_pic": headers.get("Tailscale-User-Profile-Pic") or "",
        "authenticated_user": bool(login),
    }


PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>NorthLoop Staging</title>
<style>
 body{{font:16px/1.5 system-ui,sans-serif;margin:0;background:#0f1115;color:#e8e8ea}}
 main{{max-width:640px;margin:8vh auto;padding:0 16px}}
 .card{{background:#181b22;border:1px solid #2a2f3a;border-radius:12px;padding:24px}}
 h1{{font-size:20px;margin:0 0 4px}} .muted{{color:#9aa0ab}}
 img{{width:56px;height:56px;border-radius:50%;float:right}}
 dl{{display:grid;grid-template-columns:max-content 1fr;gap:6px 16px;margin:20px 0 0}}
 dt{{color:#9aa0ab}} dd{{margin:0;font-family:ui-monospace,monospace}}
 .ok{{color:#5fd38d}}
</style></head><body><main><div class="card">
 {pic}
 <h1>Hello, {name}</h1>
 <div class="muted">You reached a private service with <b>zero open ports</b>.</div>
 <dl>
  <dt>Identity</dt><dd>{login}</dd>
  <dt>Authenticated by</dt><dd>Tailscale (no app login code)</dd>
  <dt>Environment</dt><dd>{env}</dd>
  <dt>Served from</dt><dd>{host}</dd>
  <dt>Server time</dt><dd>{now}</dd>
  <dt>Status</dt><dd class="ok">healthy</dd>
 </dl>
</div></main></body></html>"""


class Handler(BaseHTTPRequestHandler):
    server_version = "northloop-staging/1.0"

    def _send(self, code, body, ctype):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        who = identity(self.headers)
        now = datetime.now(timezone.utc).isoformat(timespec="seconds")
        # Match on the last path segment so this works whether or not Serve
        # strips its mount point (e.g. /whoami or /whoami/whoami both work).
        route = self.path.split("?", 1)[0].rstrip("/").rsplit("/", 1)[-1]

        if route == "healthz":
            self._send(200, "ok\n", "text/plain")
        elif route == "whoami":
            payload = dict(who, env=APP_ENV, served_from=HOSTNAME, time=now, started=STARTED)
            self._send(200, json.dumps(payload, indent=2) + "\n", "application/json")
        elif route in ("me", ""):
            pic = f'<img src="{html.escape(who["profile_pic"])}" alt="">' if who["profile_pic"] else ""
            self._send(200, PAGE.format(
                pic=pic,
                name=html.escape(who["name"] or who["login"]),
                login=html.escape(who["login"]),
                env=html.escape(APP_ENV),
                host=html.escape(HOSTNAME),
                now=now,
            ), "text/html; charset=utf-8")
        else:
            self._send(404, "not found\n", "text/plain")

    # Structured access log: one JSON line per request, including the caller's identity.
    def log_message(self, fmt, *args):
        print(json.dumps({
            "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "path": self.path,
            "user": self.headers.get("Tailscale-User-Login") or "tagged-device",
            "msg": fmt % args,
        }), flush=True)


if __name__ == "__main__":
    print(json.dumps({"event": "start", "bind": f"{BIND_ADDR}:{PORT}", "env": APP_ENV}), flush=True)
    ThreadingHTTPServer((BIND_ADDR, PORT), Handler).serve_forever()
