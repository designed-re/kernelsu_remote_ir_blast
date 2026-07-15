#!/data/data/com.termux/files/usr/bin/sh
# Start the IR hub in the background with a wake-lock so it survives screen-off.
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
LOG="$HERE/logs/hub.log"
PIDFILE="$HERE/hub.pid"
mkdir -p "$HERE/logs"

# keep CPU awake while the server runs (release on stop)
command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "already running pid=$(cat "$PIDFILE")"; exit 0
fi
nohup python3 server.py >>"$LOG" 2>&1 < /dev/null &
echo $! > "$PIDFILE"
sleep 1
if kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "started pid=$(cat "$PIDFILE") log=$LOG"
else
  echo "failed to start - see $LOG"; exit 1
fi
