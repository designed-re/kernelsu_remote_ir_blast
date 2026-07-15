#!/data/data/com.termux/files/usr/bin/sh
HERE="$(cd "$(dirname "$0")" && pwd)"
PIDFILE="$HERE/hub.pid"
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  kill "$(cat "$PIDFILE")"; sleep 1; kill -9 "$(cat "$PIDFILE")" 2>/dev/null
  echo "stopped pid=$(cat "$PIDFILE")"
else
  echo "not running"
fi
rm -f "$PIDFILE"
command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock
