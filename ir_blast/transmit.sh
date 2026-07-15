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
IR_SPI_DEV=$(getval ir.ir_spi_device); [ -z "$IR_SPI_DEV" ] && IR_SPI_DEV=/dev/ir_spi
IR_SPI_MODE=$(getval ir.ir_spi_mode); [ -z "$IR_SPI_MODE" ] && IR_SPI_MODE=auto
IR_SPI_CARRIER_SYSFS=$(getval ir.ir_spi_carrier_sysfs)

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

pybin() { command -v python3 >/dev/null 2>&1 && echo python3 || echo python3; }
# pack raw timings as little-endian u32 array
pack_u32() { # pack_u32 <rawfile> <mode: us|cycles> <carrier>
  python3 - "$1" "$2" "$3" <<'PACK_EOF'
import sys,struct
raw=open(sys.argv[1]).read().split()
mode=sys.argv[2]; carrier=int(sys.argv[3]) or 38000
out=bytearray()
for x in raw:
    us=int(round(float(x)))
    v=round(us*carrier/1000000.0) if mode=='cycles' else us
    out+=struct.pack('<I', max(0,v)&0xffffffff)
sys.stdout.buffer.write(bytes(out))
PACK_EOF
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
  ir_spi|ir-spi)
    DEV="$IR_SPI_DEV"
    if [ ! -w "$DEV" ]; then
      echo "ir_spi device not writable: $DEV" >&2; log "ir_spi missing $DEV"; exit 6
    fi
    # optional carrier via sysfs (some drivers expose a 'carrier' node)
    if [ -n "$IR_SPI_CARRIER_SYSFS" ] && [ -w "$IR_SPI_CARRIER_SYSFS" ]; then
      echo "$CARRIER" > "$IR_SPI_CARRIER_SYSFS" 2>/dev/null || true
    fi
    spi_send_once() { # $1 = sub-mode
      m="$1"
      case "$m" in
        ir-ctl)
          TMP="$(mktemp 2>/dev/null || echo /tmp/irspi.$$)"
          build_irctl_file "$TMP"
          "$IRCTL" -d "$DEV" --carrier="$CARRIER" --send="$TMP"
          rc=$?; rm -f "$TMP"; return $rc ;;
        write-text|text)
          cat "$RAWFILE" > "$DEV" ;;
        write-text-space|text-space)
          tr '\n' ' ' < "$RAWFILE" > "$DEV" ;;
        write-bin-u32|bin-u32|binary)
          pack_u32 "$RAWFILE" us "$CARRIER" > "$DEV" ;;
        write-bin-u32-cycles|bin-u32-cycles|binary-cycles)
          pack_u32 "$RAWFILE" cycles "$CARRIER" > "$DEV" ;;
        *)
          echo "unknown ir_spi mode: $m" >&2; return 2 ;;
      esac
    }
    if [ "$IR_SPI_MODE" = "auto" ]; then
      found=""
      for m in ir-ctl write-text write-bin-u32; do
        if spi_send_once "$m" 2>/dev/null; then found="$m"; break; fi
      done
      if [ -z "$found" ]; then
        echo "ir_spi auto: no sub-mode worked. Run 'ctl.sh probe' and set ir.ir_spi_mode." >&2
        log "ir_spi auto failed"; exit 7
      fi
      i=2
      while [ "$i" -le "$REPEAT" ]; do spi_send_once "$found" 2>/dev/null || true; i=$((i+1)); done
      log "ir_spi auto used '$found' carrier=$CARRIER n=$(wc -l <"$RAWFILE")"
      echo "ir_spi: ok (mode=$found)"; exit 0
    else
      rc=0; i=1
      while [ "$i" -le "$REPEAT" ]; do
        spi_send_once "$IR_SPI_MODE" || rc=$?
        i=$((i+1))
      done
      log "ir_spi mode=$IR_SPI_MODE dev=$DEV rc=$rc"
      exit $rc
    fi
    ;;
  command|*)
    if [ -z "$CMD" ]; then echo "ir.command is empty" >&2; exit 5; fi
    run_repeat "$CMD"
    exit $?
    ;;
esac
