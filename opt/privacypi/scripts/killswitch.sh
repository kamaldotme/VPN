#!/usr/bin/env bash
set -euo pipefail
source /opt/privacypi/scripts/lib/site.sh

ACTION="${1:-}"
VLAN="${2:-}"
# Target the given VLAN bridge if supplied, else the configured LAN bridge.
IFACE="${VLAN:+br-vlan${VLAN}}"
IFACE="${IFACE:-$LAN_BRIDGE}"
case "$ACTION" in
  arm)
    iptables -F FWD-${IFACE}
    iptables -A FWD-${IFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    echo "Kill switch ARMED on $IFACE"
    ;;
  disarm)
    iptables -F FWD-${IFACE}
    iptables -A FWD-${IFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -A FWD-${IFACE} -o "$WAN_IFACE" -j ACCEPT
    echo "Kill switch DISARMED on $IFACE"
    ;;
  *) echo "Usage: $0 arm|disarm [vlan]"; exit 2 ;;
esac
