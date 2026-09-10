#!/usr/bin/env python3
"""HTTP API that injects prompts into the Claude Code tmux session.

Authentication: every endpoint except /health and / requires
    Authorization: Bearer <INJECT_TOKEN>        (or ?token=<INJECT_TOKEN>)

Endpoints:
    PUT|POST /prompt[?submit=0][&force=1]
        body = the prompt as plain text, or JSON {"text": "...", "submit": true, "force": false}
        Pastes the text into Claude's input (bracketed paste, so newlines are kept) and
        presses Enter unless submit=0.
    POST /keys[?force=1]
        body = tmux key names separated by whitespace, e.g. "Escape", "C-c", "y Enter", "Down Enter"
    GET /screen[?lines=N]
        current pane contents as text/plain, plus N lines of scrollback
    GET /health
        {"ok": true, "session": <bool>}   (no auth)

Injection is refused with 409 while the pane's foreground program is not "claude"
(for example a shell prompt after claude exited); pass force=1 to inject anyway.

Configuration: environment first, then /etc/claude-container.conf.
    INJECT_TOKEN        required
    INJECT_BIND         default 0.0.0.0
    INJECT_PORT         default 8080
    TMUX_TARGET         default claude:claude.0
    INJECT_EXPECT_CMD   default claude   (empty string disables the check)
    INJECT_ENTER_DELAY  default 0.5      seconds between paste and Enter
    INJECT_MAX_BODY     default 1048576  bytes
"""
import fcntl
import hmac
import json
import os
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

CONF_FILE = "/etc/claude-container.conf"


def read_conf(path):
    conf = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                conf[key.strip()] = value.strip().strip("'\"")
    except OSError:
        pass
    return conf


CONF = read_conf(CONF_FILE)


def cfg(name, default):
    if name in os.environ:
        return os.environ[name]
    return CONF.get(name, default)


TOKEN = os.environ.get("INJECT_TOKEN", "")
BIND = cfg("INJECT_BIND", "0.0.0.0")
PORT = int(cfg("INJECT_PORT", "8080"))
TARGET = cfg("TMUX_TARGET", "claude:claude.0")
EXPECT = cfg("INJECT_EXPECT_CMD", "claude")
DELAY = float(cfg("INJECT_ENTER_DELAY", "0.5"))
MAX_BODY = int(cfg("INJECT_MAX_BODY", str(1 << 20)))
LOCK_FILE = cfg("INJECT_LOCK_FILE", "/tmp/claude-inject.lock")


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def tmux(*args, stdin=None):
    try:
        return subprocess.run(["tmux", *args], input=stdin, capture_output=True, timeout=15)
    except subprocess.TimeoutExpired:
        raise ApiError(504, "tmux %s timed out" % args[0]) from None


def tmux_ok(*args, stdin=None):
    result = tmux(*args, stdin=stdin)
    if result.returncode != 0:
        err = result.stderr.decode(errors="replace").strip()
        raise ApiError(500, "tmux %s failed: %s" % (args[0], err))
    return result


def pane_command():
    """Foreground program of the target pane, or None when the pane does not exist."""
    result = tmux("display-message", "-p", "-t", TARGET, "#{pane_current_command}")
    if result.returncode != 0:
        return None
    return result.stdout.decode(errors="replace").strip()


class Locked:
    """flock shared with the 'inject' shell script, so injections never interleave."""

    def __enter__(self):
        self.fd = os.open(LOCK_FILE, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        os.close(self.fd)


def guard(force):
    cmd = pane_command()
    if cmd is None:
        raise ApiError(503, "tmux target %r not found; is the session running?" % TARGET)
    if EXPECT and cmd != EXPECT and not force:
        raise ApiError(409, "pane is running %r, not %r; pass force=1 to inject anyway" % (cmd, EXPECT))


def inject_text(text, submit=True, force=False):
    text = text.rstrip("\r\n")
    if not text:
        raise ApiError(400, "empty prompt")
    with Locked():
        guard(force)
        tmux_ok("load-buffer", "-b", "inject", "-", stdin=text.encode("utf-8"))
        tmux_ok("paste-buffer", "-p", "-d", "-b", "inject", "-t", TARGET)
        if submit:
            time.sleep(DELAY)
            tmux_ok("send-keys", "-t", TARGET, "Enter")
    return {"ok": True, "chars": len(text), "lines": text.count("\n") + 1, "submitted": submit}


def send_keys(keys, force=False):
    if not keys:
        raise ApiError(400, "no keys given")
    with Locked():
        guard(force)
        tmux_ok("send-keys", "-t", TARGET, *keys)
    return {"ok": True, "keys": keys}


def screen(lines):
    args = ["capture-pane", "-p", "-t", TARGET]
    if lines > 0:
        args += ["-S", "-%d" % lines]
    result = tmux(*args)
    if result.returncode != 0:
        raise ApiError(503, "tmux target %r not found; is the session running?" % TARGET)
    return result.stdout.decode(errors="replace")


def truthy(value):
    return str(value).strip().lower() in ("1", "true", "yes", "on")


class Handler(BaseHTTPRequestHandler):
    server_version = "claude-inject/1.0"
    sys_version = ""

    def log_message(self, fmt, *args):
        sys.stderr.write("[inject-server] %s %s\n" % (self.address_string(), fmt % args))
        sys.stderr.flush()

    def reply(self, status, payload, ctype="application/json", headers=()):
        if isinstance(payload, (dict, list)):
            body = (json.dumps(payload) + "\n").encode("utf-8")
        elif isinstance(payload, str):
            body = payload.encode("utf-8")
        else:
            body = payload
        self.send_response(status)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def read_body(self):
        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            raise ApiError(411, "chunked transfer encoding not supported; send Content-Length")
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            raise ApiError(400, "invalid Content-Length") from None
        if length > MAX_BODY:
            raise ApiError(413, "body larger than %d bytes" % MAX_BODY)
        return self.rfile.read(length).decode("utf-8", errors="replace")

    def authorized(self, query):
        if not TOKEN:
            return False
        supplied = ""
        header = self.headers.get("Authorization", "")
        if header.lower().startswith("bearer "):
            supplied = header[7:].strip()
        elif query.get("token"):
            supplied = query["token"][0]
        return hmac.compare_digest(supplied.encode("utf-8"), TOKEN.encode("utf-8"))

    def handle_request(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        path = url.path.rstrip("/") or "/"
        method = self.command
        try:
            if path == "/health" and method == "GET":
                return self.reply(200, {"ok": True, "session": pane_command() is not None})
            if path == "/" and method == "GET":
                return self.reply(200, __doc__, "text/plain")
            if not self.authorized(query):
                return self.reply(401, {"ok": False, "error": "missing or invalid bearer token"},
                                  headers=[("WWW-Authenticate", 'Bearer realm="claude-inject"')])
            force = truthy(query.get("force", ["0"])[0])
            if path == "/prompt" and method in ("PUT", "POST"):
                body = self.read_body()
                submit = truthy(query.get("submit", ["1"])[0])
                ctype = self.headers.get("Content-Type", "").split(";")[0].strip().lower()
                if ctype == "application/json":
                    try:
                        data = json.loads(body or "{}")
                    except ValueError as exc:
                        raise ApiError(400, "invalid JSON: %s" % exc) from None
                    if not isinstance(data, dict):
                        raise ApiError(400, "JSON body must be an object")
                    text = data.get("text", data.get("prompt", ""))
                    if not isinstance(text, str):
                        raise ApiError(400, "'text' must be a string")
                    submit = bool(data.get("submit", submit))
                    force = bool(data.get("force", force))
                else:
                    text = body
                return self.reply(200, inject_text(text, submit=submit, force=force))
            if path == "/keys" and method == "POST":
                return self.reply(200, send_keys(self.read_body().split(), force=force))
            if path == "/screen" and method == "GET":
                try:
                    lines = int(query.get("lines", ["0"])[0])
                except ValueError:
                    raise ApiError(400, "lines must be an integer") from None
                return self.reply(200, screen(lines), "text/plain")
            raise ApiError(404, "unknown endpoint %s %s" % (method, path))
        except ApiError as exc:
            self.reply(exc.status, {"ok": False, "error": exc.message})
        except Exception as exc:  # pylint: disable=broad-except
            self.log_message("internal error: %r", exc)
            self.reply(500, {"ok": False, "error": "internal error: %s" % exc})

    do_GET = do_POST = do_PUT = handle_request


def main():
    if not TOKEN:
        sys.exit("inject-server: INJECT_TOKEN is empty, refusing to start")
    server = ThreadingHTTPServer((BIND, PORT), Handler)
    server.daemon_threads = True
    sys.stderr.write("[inject-server] listening on %s:%d, target %s, expect %r, enter delay %.2fs\n"
                     % (BIND, PORT, TARGET, EXPECT, DELAY))
    sys.stderr.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
