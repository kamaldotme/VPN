#!/usr/bin/env bash
set -euo pipefail
source /opt/privacypi/scripts/lib/site.sh

GW="$(ip -4 route show default | awk '/default/{print $3; exit}')"
# No uplink yet (first boot before the wizard, or cable unplugged): not an error —
# the AP and admin UI must still come up. Re-run once the WAN is connected.
[[ -z "$GW" ]] && { echo "no default gateway yet — LAN routing deferred"; exit 0; }

# Single LAN bridge for the AP clients. Policy-route its subnet out the WAN.
table=100
ip route flush table $table 2>/dev/null || true
ip route add "$LAN_NET" dev "$LAN_BRIDGE" src "$LAN_GW" table $table
ip route add default via "$GW" dev "$WAN_IFACE" table $table
ip rule del from "$LAN_NET" table $table 2>/dev/null || true
ip rule add from "$LAN_NET" table $table
echo "Per-LAN routing applied (table $table via $WAN_IFACE)."
