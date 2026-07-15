#!/system/bin/sh
# ctl.sh <start|stop|restart|status|test|set-config|python>
set -u
MODDIR=${IRBLAST_MODDIR:-/data/adb/modules/ir_blast}
DAEMONDIR="$MODDIR/ir_blast"
CFG="$DAEMONDIR/config.json"
PYD="$DAEMONDIR/ir_blastd.py"
TX="$DAEMONDIR/transmit.sh"
PIDFILE="$MODDIR/ir_blastd.pid"
LOG="$MODDIR/logs/server.log"

mkdir -p "$MODDIR/logs"
log() { echo "[$(date '+%F %T')] ctl: $*" >>"$LOG"; }

find_python() {
  # 1) config value 2) termux 3) PATH python3 4) system python
  if command -v python3 >/dev/null 2>&1; then echo python3; return; fi
  c=$(sed -n 's/.*"python"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CFG" 2>/dev/null | head -n1)
  if [ -n "$c" ] && [ -x "$c" ]; then echo "$c"; return; fi
  for p in /data/data/com.termux/files/usr/bin/python3 \
           /system/bin/python3 /system/xbin/python3 \
           /system/bin/python /usr/bin/python3; do
    [ -x "$p" ] && { echo "$p"; return; }
  done
  return 1
}

is_running() {
  [ -f "$PIDFILE" ] || return 1
  pid=$(cat "$PIDFILE" 2>/dev/null)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

start() {
  if is_running; then echo "already running pid=$(cat "$PIDFILE")"; return 0; fi
  PY=$(find_python) || { echo "python3 not found. Set daemon.python in config (e.g. Termux)." >&2; return 1; }
  [ -x "$PYD" ] || chmod +x "$PYD" 2>/dev/null
  SETSID=""
  command -v setsid >/dev/null 2>&1 && SETSID=setsid
  IRBLAST_MODDIR="$MODDIR" IRBLAST_CONFIG="$CFG" \
    $SETSID nohup "$PY" "$PYD" >>"$LOG" 2>&1 < /dev/null &
  echo $! > "$PIDFILE"
  sleep 1
  if is_running; then log "started pid=$(cat "$PIDFILE") py=$PY"; echo "started pid=$(cat "$PIDFILE") (py=$PY)"; return 0; fi
  echo "failed to start - see $LOG" >&2; return 1
}

stop() {
  if ! is_running; then rm -f "$PIDFILE"; echo "not running"; return 0; fi
  pid=$(cat "$PIDFILE")
  kill "$pid" 2>/dev/null; sleep 1
  kill -9 "$pid" 2>/dev/null
  rm -f "$PIDFILE"
  log "stopped pid=$pid"; echo "stopped"
}

status() {
  if is_running; then
    echo "running pid=$(cat "$PIDFILE")"
    # show listening port if ss/netstat available
    port=$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$CFG" | head -n1)
    echo "configured port: ${port:-?}"
  else
    echo "stopped"
  fi
}

test_tx() {
  # sample NEC-style power toggle: 9000,4500,560,1680,... header + a short body
  carrier=$(sed -n 's/.*"carrier"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$CFG" | head -n1)
  [ -z "$carrier" ] && carrier=38000
  TMP=$(mktemp 2>/dev/null || echo /tmp/irtest.$$)
  printf '9000\n4500\n560\n560\n560\n560\n560\n1680\n560\n560\n560\n1680\n560\n560\n560\n1680\n560\n39000\n' > "$TMP"
  echo "running backend test (carrier=$carrier)..."
  sh "$TX" "$carrier" 1 "$TMP"
  rc=$?
  rm -f "$TMP"
  echo "backend returned rc=$rc"
  return $rc
}

set_config() {
  # read new JSON from stdin, validate, atomic write
  PY=$(find_python) || { echo "python3 not found" >&2; return 1; }
  tmp=$(mktemp 2>/dev/null || echo /tmp/cfg.$$)
  cat > "$tmp"
  "$PY" -c "import json,sys
try:
    json.load(open('$tmp'))
except Exception as e:
    print('invalid json: '+str(e), file=sys.stderr); sys.exit(1)
" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$CFG"
  chmod 600 "$CFG" 2>/dev/null
  log "config updated"
  echo "config saved"
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  restart) stop; start ;;
  status) status ;;
  test) test_tx ;;
  set-config) set_config ;;
  python) find_python ;;
  ""|-h|--help)
    cat <<USAGE
Usage: ctl.sh <start|stop|restart|status|test|set-config|python>
  set-config reads JSON from stdin (e.g.  ctl.sh set-config < config.json)
USAGE
    ;;
  *) echo "unknown command: $1" >&2; exit 2 ;;
esac
