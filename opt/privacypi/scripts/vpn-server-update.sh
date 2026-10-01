#!/usr/bin/env bash
# Best-effort VPN provider server list refresh. Skips providers with no creds.
set -uo pipefail
LOG=/var/log/privacypi/vpn-update.log
mkdir -p "$(dirname "$LOG")"
echo "==> Server list refresh at $(date -Iseconds)" >> "$LOG"

# Mullvad: public servers JSON
if [[ -f /etc/privacypi/vpn/mullvad/auth.txt ]]; then
  curl -sS --max-time 30 -o /etc/privacypi/vpn/mullvad/servers/list.json \
    https://api.mullvad.net/www/relays/all/ 2>>"$LOG" && \
    echo "  ✓ mullvad" >> "$LOG"
fi

# ProtonVPN: requires API key, skipped here
# NordVPN: server list endpoint
if [[ -f /etc/privacypi/vpn/nordvpn/auth.txt ]]; then
  curl -sS --max-time 30 -o /etc/privacypi/vpn/nordvpn/servers/list.json \
    'https://api.nordvpn.com/v1/servers?limit=10000' 2>>"$LOG" && \
    echo "  ✓ nordvpn" >> "$LOG"
fi

# (Other providers: TBD as Flask integrates them)
echo "Done." >> "$LOG"
