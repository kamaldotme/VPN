#!/usr/bin/env bash
# Run by OpenVPN/wg-quick before tunnel comes up.
set -euo pipefail
MAC_SPOOF="${MAC_SPOOF:-no}"
if [[ "$MAC_SPOOF" == "yes" ]] && command -v macchanger >/dev/null; then
  macchanger -r wlan0 2>&1 | tail -2 || true
fi
echo "vpn-pre-up done at $(date -Iseconds)" >> /var/log/privacypi/vpn-hooks.log
