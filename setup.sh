#!/data/data/com.termux/files/usr/bin/sh
# Bootstrap the Termux IR hub dependencies.
set -e
echo ">> updating packages"
pkg update -y
echo ">> installing termux-api + python"
pkg install -y termux-api python
echo ">> installing python deps"
pip install -r requirements.txt
echo
echo "!! Make sure the Termux:API app is installed from F-Droid/Play (provides termux-infrared-transmit)."
echo "!! Test IR:   termux-infrared-transmit -f 38000 9000,4500,560,1690"
echo "!! Edit ir_codes.json (cp ir_codes.example.json ir_codes.json) with your arrays."
echo "!! Start:     ./run.sh"
