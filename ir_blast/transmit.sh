#!/system/bin/sh
# transmit.sh <carrier_hz> <repeat> <rawfile>
# rawfile: one pulse/space duration (microseconds) per line, alternating
#   pulse(ON), space(OFF), pulse, space, ... starting with a pulse.
# Backend is selected from ir_blast/config.json ("ir.backend").
set -u
MODDIR=${IRBLAST_MODDIR:-/data/adb/modules/ir_blast}
CFG="$MODDIR/ir_blast/config.json"

log() { echo "transmit: $*" >>"$MODDIR/logs/transmit.log" 2>&1; }

if [ "$#" -lt 3 ]; then
  echo "usage: transmit.sh <carrier_hz> <repeat> <rawfile>" >&2
  exit 2
fi
CARRIER="$1"
REPEAT="${2:-1}"
RAWFILE="$3"
[ -f "$RAWFILE" ] || { echo "rawfile not found: $RAWFILE" >&2; exit 2; }
case "$CARRIER" in ''|*[!0-9]*) echo "bad carrier: $CARRIER" >&2; exit 2;; esac
case "$REPEAT" in ''|*[!0-9]*) REPEAT=1;; esac
[ "$REPEAT" -lt 1 ] && REPEAT=1

# JSON value extraction with a tiny python helper if available, else sed fallback
getval() { # getval <section.key>  (top-level dotted path)
  if command -v python3 >/dev/null 2>&1 || [ -x "$MODDIR/ir_blast/.py" ]; then
    PY="$(command -v python3 || echo "$MODDIR/ir_blast/.py")"
    "$PY" - "$CFG" "$1" <<'PYEOF'
import json,sys
cfg=json.load(open(sys.argv[1]))
p=sys.argv[2].split('.')
v=cfg
for k in p: v=v.get(k,'') if isinstance(v,dict) else ''
print(v if not isinstance(v,bool) else ('true' if v else 'false'))
PYEOF
  else
    # sed fallback: returns first match, crude but works for flat sections
    k=$(echo "$1" | sed 's/.*\.//')
    sed -n "s/^[[:space:]]*\"$k\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",]*\).*/\1/p" "$CFG" | head -n1
  fi
}

BACKEND=$(getval ir.backend)
IRCTL=$(getval ir.irctl_path); [ -z "$IRCTL" ] && IRCTL=ir-ctl
LIRC_DEV=$(getval ir.lirc_device); [ -z "$LIRC_DEV" ] && LIRC_DEV=/dev/lirc0
GPIO=$(getval ir.gpio); [ -z "$GPIO" ] && GPIO=17
ACTIVE_HIGH=$(getval ir.active_high); [ "$ACTIVE_HIGH" = "false" ] && ACTIVE_HIGH=0 || ACTIVE_HIGH=1
CMD=$(getval ir.command)

# Build env for the command backend
export IR_CARRIER="$CARRIER"
export IR_REPEAT="$REPEAT"
export IR_RAWFILE="$RAWFILE"
export IR_CARRIER_HZ="$CARRIER"
export IR_TIMINGS=$(tr '\n' ' ' < "$RAWFILE" | sed 's/  */ /g; s/^ //; s/ $//')
export IR_TIMINGS_CSV=$(echo "$IR_TIMINGS" | tr ' ' ',')

usleep_fn() { # sleep N microseconds
  if command -v usleep >/dev/null 2>&1; then usleep "$1"
  elif command -v python3 >/dev/null 2>&1; then python3 -c "import time;time.sleep($1/1000000.0)"
  else sleep "$(awk -v u="$1" 'BEGIN{printf "%.6f",u/1000000}')"; fi
}

# Build ir-ctl raw send file (carrier line + pulse/space lines)
build_irctl_file() {
  OF="$1"
  { echo "carrier $CARRIER"; awk 'NR%2==1{print "pulse "$0} NR%2==0{print "space "$0}' "$RAWFILE"; } > "$OF"
}

run_repeat() { # run_repeat <shell-cmd-string>
  rc=0
  i=1
  while [ "$i" -le "$REPEAT" ]; do
    sh -c "$1" || rc=$?
    i=$((i+1))
  done
  return $rc
}

case "$BACKEND" in
  irctl|ir-ctl|lirc)
    TMP="$(mktemp 2>/dev/null || echo /tmp/irsend.$$)"
    build_irctl_file "$TMP"
    if ! command -v "$IRCTL" >/dev/null 2>&1; then
      echo "ir-ctl not found ($IRCTL). Install v4l-utils or set ir.irctl_path." >&2; log "ir-ctl missing"; exit 3
    fi
    run_repeat "$IRCTL -d $LIRC_DEV --carrier=$CARRIER --send=$TMP"
    rc=$?
    rm -f "$TMP"
    exit $rc
    ;;
  gpio)
    G=/sys/class/gpio/gpio$GPIO
    [ -d "$G" ] || { echo "gpio $GPIO not exported ($G missing)" >&2; exit 4; }
    [ -w "$G/value" ] || { echo "gpio $GPIO value not writable" >&2; exit 4; }
    echo out > "$G/direction" 2>/dev/null
    rc=0
    i=1
    while [ "$i" -le "$REPEAT" ]; do
      idx=0
      while IFS= read -r us; do
        [ -z "$us" ] && continue
        if [ $((idx % 2)) -eq 0 ]; then echo $ACTIVE_HIGH; else echo $((1-ACTIVE_HIGH)); fi > "$G/value"
        usleep_fn "$us"
        idx=$((idx+1))
      done < "$RAWFILE"
      echo $((1-ACTIVE_HIGH)) > "$G/value"
      i=$((i+1))
    done
    exit $rc
    ;;
  command|*)
    if [ -z "$CMD" ]; then echo "ir.command is empty" >&2; exit 5; fi
    run_repeat "$CMD"
    exit $?
    ;;
esac
