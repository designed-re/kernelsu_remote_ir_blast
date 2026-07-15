#!/system/bin/sh
# Action button in KernelSU app: show status and restart the daemon.
MODDIR=${0%/*}
sh "$MODDIR/ir_blast/ctl.sh" status
echo "restarting..."
sh "$MODDIR/ir_blast/ctl.sh" restart
sh "$MODDIR/ir_blast/ctl.sh" status
