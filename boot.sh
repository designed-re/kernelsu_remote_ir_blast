#!/data/data/com.termux/files/usr/bin/sh
# Termux:Boot autostart. Copy/symlink this to ~/.termux/boot/ir-hub.sh so the
# hub starts automatically after device boot (requires the Termux:Boot app).
#   mkdir -p ~/.termux/boot
#   cp boot.sh ~/.termux/boot/ir-hub.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
# give the device a moment to settle, then launch
sleep 10
cd "$HERE" && ./run.sh
