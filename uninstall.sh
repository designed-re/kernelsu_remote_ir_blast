#!/system/bin/sh
# Clean up the running daemon and config/logs on module removal.
MODDIR=/data/adb/modules/ir_blast
sh "$MODDIR/ir_blast/ctl.sh" stop >/dev/null 2>&1
rm -rf "$MODDIR/logs" "$MODDIR/ir_blastd.pid"
