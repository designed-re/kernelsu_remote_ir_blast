#!/system/bin/sh
# Late-start service: launch the IR blaster HTTP daemon after boot.
MODDIR=${0%/*}
CTL="$MODDIR/ir_blast/ctl.sh"
# wait a few seconds for boot/network to settle
(sleep 8; sh "$CTL" start >/dev/null 2>&1) &
