#!/usr/bin/env python3
"""Termux smart-home IR hub.

A tiny Flask webhook server that fires IR signals on an Android device via the
Termux:API `termux-infrared-transmit` command. IR codes (raw pulse/space timing
arrays extracted from your remote) live in ir_codes.json.

Quick start:
  pkg install termux-api python
  pip install flask
  cp ir_codes.example.json ir_codes.json   # then paste your arrays
  python server.py

Endpoints:
  GET|POST  /ac/<command>          fire a named code from ir_codes.json
  GET       /ac                     list available commands
  POST      /ir                      fire ad-hoc raw timings {carrier,pattern}
  POST      /reload                  reload ir_codes.json (auth required if set)
  GET       /health                  liveness check

Auth (optional): set config.json auth_token (non-empty). Then every request must
carry it via header `Authorization: Bearer <token>`, `X-Token: <token>`, or
`?token=<token>`.
"""
import json
import os
import subprocess
import threading
import time

from flask import Flask, jsonify, request

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(HERE, "config.json")
CODES_PATH = os.path.join(HERE, "ir_codes.json")
CODES_EXAMPLE_PATH = os.path.join(HERE, "ir_codes.example.json")

app = Flask(__name__)
_lock = threading.Lock()
_cfg = None
_codes = None
_codes_mtime = 0


def load_config():
    global _cfg
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            _cfg = json.load(f)
    except Exception as e:
        print("WARNING: cannot load config.json (%s); using defaults" % e)
        _cfg = {}
    return _cfg


def load_codes(force=False):
    """Load ir_codes.json, falling back to ir_codes.example.json. Auto-reloads on mtime change."""
    global _codes, _codes_mtime
    path = CODES_PATH if os.path.exists(CODES_PATH) else CODES_EXAMPLE_PATH
    try:
        mt = os.path.getmtime(path)
    except OSError:
        mt = 0
    if not force and _codes is not None and mt == _codes_mtime:
        return _codes
    try:
        with open(path, "r", encoding="utf-8") as f:
            _codes = json.load(f)
        _codes_mtime = mt
        if path == CODES_EXAMPLE_PATH:
            print("NOTE: ir_codes.json not found; using ir_codes.example.json. "
                  "Copy it and paste your extracted arrays.")
    except Exception as e:
        print("ERROR: cannot load %s: %s" % (path, e))
        _codes = {}
    return _codes


def cfg(*path, default=None):
    c = _cfg or {}
    v = c
    for k in path:
        if isinstance(v, dict) and k in v:
            v = v[k]
        else:
            return default
    return v


def authenticated():
    token = cfg("auth_token", default="") or ""
    if not token:
        return True  # auth disabled
    provided = (
        request.headers.get("X-Token")
        or (request.headers.get("Authorization", "").removeprefix("Bearer ").strip()
            if request.headers.get("Authorization", "").startswith("Bearer ") else "")
        or request.args.get("token", "")
        or ""
    )
    return provided == token


def resolve_code(name):
    """Return (carrier, pattern_str) for a command name, or (None, None)."""
    codes = load_codes()
    if name not in codes:
        return None, None
    val = codes[name]
    default_carrier = int(cfg("default_carrier", default=38000) or 38000)
    if isinstance(val, dict):
        carrier = int(val.get("carrier", default_carrier) or default_carrier)
        pattern = val.get("pattern") or val.get("timings") or ""
    elif isinstance(val, list):
        carrier = default_carrier
        pattern = ",".join(str(int(round(float(x)))) for x in val)
    else:
        carrier = default_carrier
        pattern = str(val)
    pattern = ",".join(p.strip() for p in str(pattern).split(",") if p.strip())
    return carrier, pattern


def fire_ir(carrier, pattern):
    """Run termux-infrared-transmit -f <carrier> <pattern>. Returns (rc, output)."""
    cmd_path = cfg("ir_command", default="termux-infrared-transmit") or "termux-infrared-transmit"
    timeout = int(cfg("transmit_timeout", default=8) or 8)
    if not pattern:
        return 1, "empty pattern"
    cmd = [cmd_path, "-f", str(int(carrier)), pattern]
    with _lock:
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
            out = (p.stdout or "") + (p.stderr or "")
            return p.returncode, out
        except FileNotFoundError:
            return 127, ("command not found: %s. Install Termux:API + `pkg install termux-api`" % cmd_path)
        except subprocess.TimeoutExpired:
            return 124, "transmit timed out"


@app.before_request
def _gate():
    if request.path == "/health":
        return
    if not authenticated():
        return jsonify({"ok": False, "error": "unauthorized"}), 401


@app.route("/health")
def health():
    return jsonify({"ok": True, "service": "termux-ir-hub",
                     "codes": len({k: v for k, v in load_codes().items() if not k.startswith("_")})})


@app.route("/ac")
@app.route("/ac/")
def list_codes():
    codes = load_codes()
    names = [k for k in codes.keys() if not k.startswith("_")]
    return jsonify({"ok": True, "commands": sorted(names)})


@app.route("/ac/<command>", methods=["GET", "POST"])
def fire_command(command):
    carrier, pattern = resolve_code(command)
    if pattern is None:
        return jsonify({"ok": False, "error": "unknown command: %s" % command}), 404
    t0 = time.monotonic()
    rc, out = fire_ir(carrier, pattern)
    elapsed = int((time.monotonic() - t0) * 1000)
    status = 200 if rc == 0 else 502
    return jsonify({"ok": rc == 0, "command": command, "carrier": carrier,
                    "rc": rc, "elapsed_ms": elapsed, "output": out[-500:]}), status


@app.route("/ir", methods=["POST"])
def fire_raw():
    try:
        payload = request.get_json(force=True, silent=True) or {}
    except Exception:
        payload = {}
    raw_carrier = payload.get("carrier")
    try:
        if raw_carrier in (None, ""):
            carrier = int(cfg("default_carrier", default=38000) or 38000)
        else:
            carrier = int(raw_carrier)
    except (TypeError, ValueError):
        return jsonify({"ok": False, "error": "bad carrier"}), 400
    pat = payload.get("pattern") or payload.get("timings")
    if isinstance(pat, list):
        try:
            pattern = ",".join(str(int(round(float(x)))) for x in pat)
        except (TypeError, ValueError):
            return jsonify({"ok": False, "error": "bad timings"}), 400
    else:
        pattern = ",".join(p.strip() for p in str(pat or "").split(",") if p.strip()) if pat else ""
    if not pattern:
        return jsonify({"ok": False, "error": "pattern/timings required"}), 400
    rc, out = fire_ir(carrier, pattern)
    return jsonify({"ok": rc == 0, "carrier": carrier, "rc": rc, "output": out[-500:]}), (200 if rc == 0 else 502)


@app.route("/reload", methods=["POST"])
def reload_codes():
    load_codes(force=True)
    return jsonify({"ok": True, "codes": len({k: v for k, v in load_codes().items() if not k.startswith("_")})})


def main():
    load_config()
    load_codes(force=True)
    host = cfg("host", default="0.0.0.0") or "0.0.0.0"
    port = int(cfg("port", default=5000) or 5000)
    token = cfg("auth_token", default="") or ""
    print("Termux IR Hub starting on %s:%s (auth=%s, codes=%d)"
          % (host, port, "ON" if token else "OFF", len(load_codes())))
    app.run(host=host, port=port, threaded=True)


if __name__ == "__main__":
    main()
