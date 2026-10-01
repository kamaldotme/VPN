#!/usr/bin/env bash
# USB-tether failover: switch egress from eth0 → usb0 (or vice versa).
# Triggered automatically by network-watcher when eth0 carrier drops, OR
# manually from the UI ("Use phone for internet").
#
# Usage:
#   tether-wan.sh status       # JSON: {wan, candidates, eth0_up, usb0_up}
#   tether-wan.sh switch <if>  # set <if> as default route + masquerade
set -euo pipefail
source /opt/privacypi/scripts/lib/site.sh
ACTION="${1:-status}"
TARGET="${2:-}"

list_candidates() {
  for ifc in "$ETH_IFACE" usb0 wwan0 enx*; do
    [[ -d /sys/class/net/$ifc ]] || continue
    [[ "$(cat /sys/class/net/$ifc/operstate 2>/dev/null)" == "up" ]] || continue
    echo "$ifc"
  done | head -20
}

current_wan() {
  ip -4 route show default | awk '/default/{print $5; exit}'
}

case "$ACTION" in
  status)
    CUR=$(current_wan || echo "")
    CANDS=$(list_candidates | paste -sd, -)
    ETH=$([[ -d /sys/class/net/$ETH_IFACE ]] && cat /sys/class/net/$ETH_IFACE/operstate 2>/dev/null || echo "missing")
    USB=$([[ -d /sys/class/net/usb0 ]] && cat /sys/class/net/usb0/operstate 2>/dev/null || echo "missing")
    echo "{\"ok\":true,\"wan\":\"$CUR\",\"candidates\":\"$CANDS\",\"wired\":\"$ETH\",\"usb0\":\"$USB\"}"
    ;;
  switch)
    [[ -z "$TARGET" ]] && { echo '{"ok":false,"error":"target required"}'; exit 1; }
    [[ -d /sys/class/net/$TARGET ]] || { echo "{\"ok\":false,\"error\":\"no such interface\"}"; exit 1; }
    # Find gateway via DHCP lease or ip route
    GW=$(ip -4 route show dev "$TARGET" | awk '/default/{print $3; exit}')
    if [[ -z "$GW" ]]; then
      # Try dhcp
      dhclient -1 -nw "$TARGET" 2>/dev/null || true
      sleep 3
      GW=$(ip -4 route show dev "$TARGET" | awk '/default/{print $3; exit}')
    fi
    [[ -z "$GW" ]] && { echo "{\"ok\":false,\"error\":\"no gateway on $TARGET\"}"; exit 1; }
    # Replace default route
    ip route del default 2>/dev/null || true
    ip route add default via "$GW" dev "$TARGET"
    # Update masquerade rule (route-mode reads OUT_IF dynamically)
    iptables -t nat -F POSTROUTING 2>/dev/null || true
    iptables -t nat -A POSTROUTING -o "$TARGET" -j MASQUERADE
    echo "{\"ok\":true,\"wan\":\"$TARGET\",\"gw\":\"$GW\"}"
    ;;
  *) echo '{"ok":false,"error":"unknown action"}'; exit 2 ;;
esac
