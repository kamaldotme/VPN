#!/usr/bin/env bash
# set-time.sh <unix-epoch> — set the clock from the browser running the wizard.
# A Pi 4 has no battery clock: a freshly flashed card boots with the image's
# build date. With a wrong clock, DNSSEC and TLS validation fail, which blocks
# DNS, which blocks NTP — a deadlock. The phone running the wizard knows the
# time, so it tells us. Ignored once NTP is synchronised or if the value is
# implausible.
set -uo pipefail
EPOCH="${1:-}"
[[ "$EPOCH" =~ ^[0-9]{10}$ ]] || { echo '{"ok":false,"error":"bad epoch"}'; exit 2; }
NOW=$(date +%s)
FLOOR=$(stat -c %Y /opt/privacypi/VERSION 2>/dev/null || echo 1700000000)   # never before the build
if chronyc -n tracking 2>/dev/null | grep -q 'Leap status *: Normal'; then
  echo '{"ok":true,"changed":false,"reason":"ntp synchronised"}'; exit 0
fi
DELTA=$(( EPOCH - NOW )); [[ $DELTA -lt 0 ]] && DELTA=$(( -DELTA ))
if (( EPOCH < FLOOR - 86400 || EPOCH > FLOOR + 20*365*86400 )); then
  echo '{"ok":false,"error":"implausible time"}'; exit 1
fi
if (( DELTA < 90 )); then echo '{"ok":true,"changed":false}'; exit 0; fi
date -u -s "@$EPOCH" >/dev/null 2>&1 || { echo '{"ok":false,"error":"could not set clock"}'; exit 1; }
chronyc makestep >/dev/null 2>&1 || true
echo "{\"ok\":true,\"changed\":true,\"delta\":$DELTA}"
