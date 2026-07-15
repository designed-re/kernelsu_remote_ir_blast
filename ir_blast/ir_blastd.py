#!/usr/bin/env python3
"""Remote IR Blaster HTTP daemon.

Runs an authenticated HTTP server. On a POST carrying raw IR timings
(pulse/space microseconds), it invokes the configured transmit backend
(transmit.sh) to emit the signal. All settings come from config.json and are
editable from the KernelSU WebUI.

Endpoint:  POST /ir   (also /transmit)
Body:      {"carrier": 38000, "repeat": 1, "timings": [9000,4500,560,560,...]}
           - carrier optional (defaults to ir.carrier in config)
           - repeat   optional (defaults to ir.repeat in config)
           - timings  required: raw pulse/space us, alternating, starts with pulse
Auth:      header <auth_header> must equal <auth_value> (both from config)
"""
import json
import logging
import os
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODDIR = os.environ.get("IRBLAST_MODDIR", "/data/adb/modules/ir_blast")
CONF = os.environ.get("IRBLAST_CONFIG", os.path.join(MODDIR, "ir_blast", "config.json"))
TRANSMIT = os.path.join(MODDIR, "ir_blast", "transmit.sh")
LOGFILE = os.path.join(MODDIR, "logs", "server.log")

_lock = threading.Lock()
_cfg_lock = threading.Lock()
_cfg_cache = {"mtime": 0, "data": None}


def load_config(force=False):
    with _cfg_lock:
        try:
            mt = os.path.getmtime(CONF)
        except OSError:
            mt = 0
        if not force and _cfg_cache["data"] is not None and mt == _cfg_cache["mtime"]:
            return _cfg_cache["data"]
        try:
            with open(CONF, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception as e:
            data = None
            logging.error("cannot load config %s: %s", CONF, e)
        _cfg_cache["mtime"] = mt
        _cfg_cache["data"] = data
        return data


def setup_logging():
    os.makedirs(os.path.dirname(LOGFILE), exist_ok=True)
    fmt = "%(asctime)s %(levelname)s %(message)s"
    try:
        logging.basicConfig(filename=LOGFILE, level=logging.INFO,
                             format=fmt, force=True)
    except Exception:
        logging.basicConfig(level=logging.INFO, format=fmt)
    # also echo to stderr for service.sh capture
    h = logging.StreamHandler(sys.stderr)
    h.setFormatter(logging.Formatter(fmt))
    logging.getLogger().addHandler(h)


class IrHandler(BaseHTTPRequestHandler):
    server_version = "RemoteIRBlast/1.0"
    protocol_version = "HTTP/1.1"

    # --- helpers ---------------------------------------------------------
    def _cfg(self, *path, default=None):
        c = load_config()
        if not isinstance(c, dict):
            return default
        v = c
        for k in path:
            if isinstance(v, dict) and k in v:
                v = v[k]
            else:
                return default
        return v

    def _send_json(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def _authenticated(self):
        hdr_name = self._cfg("server", "auth_header", default="X-IR-Token") or ""
        hdr_val = self._cfg("server", "auth_value", default="") or ""
        if not hdr_name or not hdr_val:
            logging.warning("auth not configured (header/value empty) - rejecting")
            return False
        # HTTP headers are case-insensitive
        provided = self.headers.get(hdr_name)
        if provided is None:
            provided = ""
        ok = provided == hdr_val
        if not ok:
            logging.warning("auth failed for %s (header=%s)", self.client_address[0], hdr_name)
        return ok

    def _read_body(self):
        maxb = int(self._cfg("daemon", "max_body_bytes", default=65536) or 65536)
        try:
            length = int(self.headers.get("Content-Length", "0") or 0)
        except ValueError:
            length = 0
        if length <= 0:
            return b"", "empty body"
        if length > maxb:
            return b"", "body too large (%d > %d)" % (length, maxb)
        return self.rfile.read(length), None

    # --- routes ----------------------------------------------------------
    def do_GET(self):
        if not self._authenticated():
            return self._send_json(401, {"ok": False, "error": "unauthorized"})
        if self.path in ("/health", "/health/", "/"):
            return self._send_json(200, {"ok": True, "service": "remote-ir-blast",
                                         "version": "1.0.0"})
        return self._send_json(404, {"ok": False, "error": "not found"})

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()

    def do_POST(self):
        if not self._authenticated():
            return self._send_json(401, {"ok": False, "error": "unauthorized"})
        path = self.path.split("?", 1)[0].rstrip("/")
        if path not in ("/ir", "/transmit"):
            return self._send_json(404, {"ok": False, "error": "not found"})
        body, err = self._read_body()
        if err:
            return self._send_json(400, {"ok": False, "error": err})
        try:
            payload = json.loads(body.decode("utf-8"))
        except Exception as e:
            return self._send_json(400, {"ok": False, "error": "invalid json: %s" % e})
        if not isinstance(payload, dict):
            return self._send_json(400, {"ok": False, "error": "payload must be an object"})

        timings = payload.get("timings")
        if not isinstance(timings, list) or not timings:
            return self._send_json(400, {"ok": False, "error": "timings required (non-empty array of us)"})
        try:
            timings = [int(round(float(x))) for x in timings]
        except (TypeError, ValueError):
            return self._send_json(400, {"ok": False, "error": "timings must be numeric"})
        if any(t <= 0 for t in timings):
            return self._send_json(400, {"ok": False, "error": "timings must be > 0"})
        if len(timings) % 2 != 0:
            return self._send_json(400, {"ok": False, "error": "timings count must be even (pulse/space pairs)"})

        carrier = int(payload.get("carrier") or self._cfg("ir", "carrier", default=38000) or 38000)
        repeat = int(payload.get("repeat") or self._cfg("ir", "repeat", default=1) or 1)
        if repeat < 1:
            repeat = 1
        timeout_ms = int(self._cfg("ir", "timeout_ms", default=5000) or 5000)

        rc, out, elapsed = self._transmit(carrier, repeat, timings, timeout_ms)
        logging.info("transmit carrier=%s repeat=%s n=%d rc=%s %dms %s",
                      carrier, repeat, len(timings), rc, elapsed, self.client_address[0])
        if rc == 0:
            return self._send_json(200, {"ok": True, "carrier": carrier,
                                         "repeat": repeat, "count": len(timings),
                                         "elapsed_ms": elapsed})
        return self._send_json(502, {"ok": False, "rc": rc, "error": "transmit failed",
                                     "output": out[-2000:]})

    def _transmit(self, carrier, repeat, timings, timeout_ms):
        fd, rawfile = tempfile.mkstemp(prefix="irtx_", suffix=".raw",
                                        dir="/tmp" if os.path.isdir("/tmp") else None)
        try:
            with os.fdopen(fd, "w") as f:
                f.write("\n".join(str(t) for t in timings) + "\n")
            cmd = ["sh", TRANSMIT, str(carrier), str(repeat), rawfile]
            env = dict(os.environ)
            env["IRBLAST_MODDIR"] = MODDIR
            t0 = time.monotonic()
            with _lock:  # serialize transmissions (single IR emitter)
                try:
                    p = subprocess.run(cmd, env=env, capture_output=True,
                                       text=True, timeout=timeout_ms / 1000.0)
                    rc, out = p.returncode, (p.stdout or "") + (p.stderr or "")
                except subprocess.TimeoutExpired:
                    return 124, "timeout", int((time.monotonic() - t0) * 1000)
            return rc, out, int((time.monotonic() - t0) * 1000)
        finally:
            try:
                os.unlink(rawfile)
            except OSError:
                pass

    def log_message(self, fmt, *args):
        logging.info("%s - " + fmt, self.client_address[0], *args)

    # silence default stderr access log noise (we log ourselves)


def main():
    setup_logging()
    cfg = load_config(force=True)
    if not isinstance(cfg, dict):
        logging.error("config invalid; cannot start")
        sys.exit(1)
    host = cfg.get("server", {}).get("host", "0.0.0.0") or "0.0.0.0"
    port = int(cfg.get("server", {}).get("port", 8424) or 8424)
    try:
        srv = ThreadingHTTPServer((host, port), IrHandler)
        srv.daemon_threads = True
    except OSError as e:
        logging.error("cannot bind %s:%s : %s", host, port, e)
        sys.exit(1)
    logging.info("Remote IR Blaster listening on %s:%s (backend=%s)",
                 host, port, cfg.get("ir", {}).get("backend"))
    print("Remote IR Blaster listening on %s:%s" % (host, port), file=sys.stderr)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.shutdown()
        logging.info("stopped")


if __name__ == "__main__":
    main()
