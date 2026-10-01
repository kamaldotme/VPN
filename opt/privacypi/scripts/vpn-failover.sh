#!/usr/bin/env bash
# Health-check active VPN. On failure, try next config. On exhaustion, arm killswitch + alert.
set -uo pipefail
STATE_FILE=/var/lib/privacypi/active-vpn
[[ ! -f "$STATE_FILE" ]] && exit 0
MODE=$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('mode','direct'))")

# Only relevant for openvpn / wireguard modes
[[ "$MODE" != "openvpn" && "$MODE" != "wireguard" ]] && exit 0

# Quick health: ping 1.1.1.1 through tunnel
TUN=tun0
[[ "$MODE" == "wireguard" ]] && TUN=wg0
ip link show "$TUN" up >/dev/null 2>&1 || {
    echo "{\"healthy\": false, \"reason\": \"$TUN not up\"}"
    /opt/privacypi/scripts/route-mode.sh killswitch
    # Killswitch script already fires its own alert via fire_alert()
    exit 1
}
ping -c 2 -W 3 -I "$TUN" 1.1.1.1 >/dev/null 2>&1 && {
    echo "{\"healthy\": true}"
    exit 0
}
echo "{\"healthy\": false, \"reason\": \"ping failed via $TUN\"}"
/opt/privacypi/scripts/route-mode.sh killswitch
exit 1
