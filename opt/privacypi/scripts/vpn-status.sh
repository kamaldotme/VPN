#!/usr/bin/env bash
# vpn-status.sh — prints JSON status for Flask
set -uo pipefail
STATE_FILE=/var/lib/privacypi/active-vpn

MODE="direct"
if [[ -f "$STATE_FILE" ]]; then
  MODE="$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('mode','direct'))" 2>/dev/null || echo direct)"
fi

TUN_UP="false"
ip link show tun0 2>/dev/null | grep -q UP && TUN_UP="true"
WG_UP="false"
ip link show wg0 2>/dev/null | grep -q UP && WG_UP="true"

PUB_IP="$(timeout 3 curl -sS https://api.ipify.org 2>/dev/null || echo unknown)"

cat <<JSON
{
  "mode": "$MODE",
  "tun0_up": $TUN_UP,
  "wg0_up": $WG_UP,
  "public_ip": "$PUB_IP",
  "checked_at": "$(date -Iseconds)"
}
JSON
