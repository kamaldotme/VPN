#!/usr/bin/env bash
# Per-MAC traffic accounting.
# Maintains an iptables chain that counts bytes per MAC on the LAN bridges.
# Polled by Flask to render a per-device traffic chart.
#
# Usage:
#   mac-traffic.sh init               # one-time chain setup
#   mac-traffic.sh add <mac>          # add accounting rules for MAC
#   mac-traffic.sh stats              # JSON list: [{mac, in_bytes, out_bytes}, ...]
#   mac-traffic.sh refresh            # discover MACs from arp + add rules
set -euo pipefail
ACTION="${1:-stats}"
CHAIN_IN="PRIVACYPI_MAC_IN"
CHAIN_OUT="PRIVACYPI_MAC_OUT"
LAN_BRIDGES=("br-vlan10")  # add others as needed

init_chain() {
  for c in "$CHAIN_IN" "$CHAIN_OUT"; do
    iptables -N "$c" 2>/dev/null || true
    iptables -F "$c"
  done
  # Hook into FORWARD: incoming-from-LAN, outgoing-to-LAN
  for br in "${LAN_BRIDGES[@]}"; do
    iptables -C FORWARD -i "$br" -j "$CHAIN_IN" 2>/dev/null \
      || iptables -A FORWARD -i "$br" -j "$CHAIN_IN"
    iptables -C FORWARD -o "$br" -j "$CHAIN_OUT" 2>/dev/null \
      || iptables -A FORWARD -o "$br" -j "$CHAIN_OUT"
  done
  # Always RETURN at end
  iptables -A "$CHAIN_IN" -j RETURN
  iptables -A "$CHAIN_OUT" -j RETURN
}

add_mac() {
  MAC="${1,,}"
  [[ "$MAC" =~ ^[0-9a-f:]{17}$ ]] || { echo "bad mac"; return 1; }
  # Insert above RETURN
  iptables -C "$CHAIN_IN"  -m mac --mac-source "$MAC" -j RETURN 2>/dev/null \
    || iptables -I "$CHAIN_IN"  1 -m mac --mac-source "$MAC" -j RETURN
  # Out direction: we tag by destination MAC via the "physdev" module if br
  # is a real bridge; simpler — count by source IP via ARP table mapping.
  # For now we count IN only (most useful: device upload).
}

discover() {
  init_chain
  # Read arp neighbours from each bridge
  for br in "${LAN_BRIDGES[@]}"; do
    ip neigh show dev "$br" 2>/dev/null | awk '/REACHABLE|STALE/{print tolower($5)}' \
      | grep -E '^[0-9a-f:]{17}$' | sort -u | while read -r mac; do
        add_mac "$mac" || true
      done
  done
}

stats() {
  # Emit JSON list with per-rule pkt+byte counters from CHAIN_IN
  iptables -L "$CHAIN_IN" -nvx 2>/dev/null | awk '
    BEGIN { print "["; first=1 }
    /MAC [0-9a-f:]{17}/ {
      pkts=$1; bytes=$2
      for(i=1;i<=NF;i++) if($i=="MAC"){mac=$(i+1); break}
      if(!first) print ","
      printf "  {\"mac\":\"%s\",\"pkts\":%s,\"bytes\":%s}", mac, pkts, bytes
      first=0
    }
    END { print "\n]" }
  '
}

case "$ACTION" in
  init)    init_chain; echo '{"ok":true}' ;;
  add)     init_chain; add_mac "${2:-}" && echo '{"ok":true}' || echo '{"ok":false}' ;;
  refresh) discover; echo '{"ok":true}' ;;
  stats)   stats ;;
  *) echo '{"ok":false}'; exit 2 ;;
esac
