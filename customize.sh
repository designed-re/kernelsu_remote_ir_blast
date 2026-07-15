#!/system/bin/sh
# KernelSU/Magisk installer script
SKIPUNZIP=0
ui_print "- Installing Remote IR Blaster"
ui_print "- module dir: $MODPATH"

# perms
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/ir_blast/ctl.sh"       0 0 0755
set_perm "$MODPATH/ir_blast/transmit.sh" 0 0 0755
set_perm "$MODPATH/ir_blast/ir_blastd.py" 0 0 0755
set_perm "$MODPATH/service.sh"            0 0 0755
set_perm "$MODPATH/uninstall.sh"          0 0 0755
set_perm "$MODPATH/action.sh"             0 0 0755
set_perm_recursive "$MODPATH/webroot"    0 0 0755 0644

mkdir -p "$MODPATH/logs"

# keep existing user config across updates (config is shipped in the zip)
if [ -f "/data/adb/modules/ir_blast/ir_blast/config.json" ]; then
  ui_print "- preserving existing config.json"
  cp -f "/data/adb/modules/ir_blast/ir_blast/config.json" "$MODPATH/ir_blast/config.json"
fi
chmod 600 "$MODPATH/ir_blast/config.json" 2>/dev/null

# auto-detect python for default config if value is still placeholder
CFG="$MODPATH/ir_blast/config.json"
if grep -q 'change-me-please' "$CFG" 2>/dev/null; then
  ui_print "- WARNING: default auth token in use. Open the WebUI and change it!"
fi
# try to detect a python on device and write it into config if the placeholder fails
for p in /data/data/com.termux/files/usr/bin/python3 /system/bin/python3 /usr/bin/python3; do
  if [ -x "$p" ]; then
    if grep -q '/data/data/com.termux/files/usr/bin/python3' "$CFG"; then
      sed -i "s#/data/data/com.termux/files/usr/bin/python3#$p#" "$CFG"
    fi
    break
  fi
done

ui_print "- install done. Open the module page in KernelSU to configure."
