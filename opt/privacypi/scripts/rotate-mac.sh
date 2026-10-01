#!/usr/bin/env bash
# Randomize a radio's MAC. Logs the change.
# Safety: when the built-in radio is acting as the WiFi WAN uplink
# (WAN_MODE=wifi), rotating its MAC would drop the upstream association and
# kill internet for every connected client — so we skip it in that case.
set -uo pipefail
source /opt/privacypi/scripts/lib/site.sh 2>/dev/null || true
IFACE="${1:-${WIFI_WAN_IFACE:-wlan0}}"
LOG=/var/log/privacypi/mac-rotate.log
mkdir -p "$(dirname "$LOG")"

if [[ "${WAN_MODE:-ethernet}" == "wifi" && "$IFACE" == "${WIFI_WAN_IFACE:-wlan0}" ]]; then
  echo "$(date -Iseconds) skipped MAC rotation on $IFACE (active WiFi WAN)" >> "$LOG"
  exit 0
fi

ip link set "$IFACE" down 2>/dev/null || true
macchanger -r "$IFACE" 2>&1 | tail -2 >> "$LOG"
ip link set "$IFACE" up 2>/dev/null || true
echo "$(date -Iseconds) rotated MAC on $IFACE" >> "$LOG"
