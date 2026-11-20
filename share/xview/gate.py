#!/data/data/com.novainc.agt/files/usr/bin/python3
# gate.py: the one public door to XFCE viewing.
#
# cloudflared routes x-agt.novamail.store to this server on
# 127.0.0.1:18787 (loopback only; nothing else on the phone can be
# reached through it). The ONLY thing that exists here is a live
# session token:
#
#   GET /<token>            -> redirect to the viewer page
#   GET /<token>/<asset>    -> the noVNC viewer assets
#   GET /<token>/websockify (Upgrade) -> raw splice to that
#                              session's websockify on loopback
#
# Everything else is 404, including / itself: no index, no list,
# no hint of which tokens exist. A token is live only while its
# session record exists AND the session process is alive, so a
# closed (or crashed) session's link is dead even if a stale
# record somehow remains. View-only is enforced at the source:
# x11vnc runs with -viewonly, so input frames are refused by the
# VNC server itself no matter what a client sends.
import json
import os
import select
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

ADDON = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
STATE = os.path.join(ADDON, "state")
SESSIONS = os.path.join(STATE, "sessions")
WEB = os.path.join(ADDON, "share", "xview", "web")
PORT = 18787

MIME = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript",
    ".mjs": "text/javascript",
    ".css": "text/css",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
    ".woff": "font/woff",
    ".woff2": "font/woff2",
    ".json": "application/json",
    ".txt": "text/plain; charset=utf-8",
}


def load_session(token):
    if not token or "/" in token or "\\" in token or token.startswith("."):
        return None
    try:
        with open(os.path.join(SESSIONS, token + ".json")) as f:
            rec = json.load(f)
    except Exception:
        return None
    try:
        os.kill(int(rec["pid"]), 0)
    except Exception:
        return None
    return rec


class Gate(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def not_found(self):
        body = b"not found\n"
        self.send_response(404)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        parts = [p for p in parsed.path.split("/") if p != ""]
        if not parts:
            return self.not_found()
        token = parts[0]
        rec = load_session(token)
        if rec is None:
            return self.not_found()
        rest = parts[1:]
        if not rest:
            loc = "/%s/vnc.html?path=%s%%2Fwebsockify&view_only=true&resize=scale" % (token, token)
            self.send_response(302)
            self.send_header("Location", loc)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if rest == ["websockify"] and self.headers.get("Upgrade", "").lower() == "websocket":
            return self.splice(rec)
        return self.serve_asset(rest)

    def serve_asset(self, rest):
        rel = os.path.normpath(os.path.join(*rest)) if rest else ""
        if rel.startswith("..") or os.path.isabs(rel):
            return self.not_found()
        path = os.path.join(WEB, rel)
        if not os.path.isfile(path):
            return self.not_found()
        ext = os.path.splitext(path)[1].lower()
        with open(path, "rb") as f:
            body = f.read()
        self.send_response(200)
        self.send_header("Content-Type", MIME.get(ext, "application/octet-stream"))
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def splice(self, rec):
        backend = socket.create_connection(("127.0.0.1", int(rec["wsPort"])), timeout=10)
        # Replay the upgrade request to websockify with its expected
        # path, preserving the client's headers (Sec-WebSocket-Key,
        # subprotocol 'binary', and so on).
        lines = ["GET /websockify HTTP/1.1"]
        for k, v in self.headers.items():
            if k.lower() == "host":
                lines.append("Host: 127.0.0.1:%d" % int(rec["wsPort"]))
            else:
                lines.append("%s: %s" % (k, v))
        backend.sendall(("\r\n".join(lines) + "\r\n\r\n").encode("latin-1"))
        client = self.connection
        self.close_connection = True
        sockets = [client, backend]
        try:
            while True:
                # No timeout: the splice must live as long as the
                # viewer is open. A 60s select timeout here closed
                # every idle viewing connection at 60s (proven live
                # 2026-11-20: phone-local websocket hold closed at
                # 60.3s with zero traffic and at 60.2s with RFB
                # traffic; websockify has no such timer).
                readable, _, _ = select.select(sockets, [], [])
                if not readable:
                    continue
                for s in readable:
                    data = s.recv(65536)
                    if not data:
                        return
                    (backend if s is client else client).sendall(data)
        except Exception:
            pass
        finally:
            try:
                backend.close()
            except Exception:
                pass


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Gate)
    print("xview gate listening on 127.0.0.1:%d" % PORT, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
