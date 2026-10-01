#!/usr/bin/env bash
# DNS containment — force ALL devices on the LAN through AdGuard, no matter
# what resolver they hardcode (8.8.8.8, 1.1.1.1, etc).
#
# This is the single biggest "device leaks DNS" fix. Without it, apps and
# IoT devices that hardcode public resolvers bypass our filter chain.
#
# Strategy:
#   1. iptables NAT redirect: any LAN-originated traffic to :53 (UDP/TCP)
#      and :853 (DoT) gets transparently redirected to 127.0.0.1:53
#      (AdGuard Home).
#   2. Block known DoH IPs at the FORWARD chain so apps hardcoding
#      Cloudflare/Google/Quad9 DoH endpoints can't bypass either.
#      They fall back to plain DNS, which we capture in step 1.
#
# Usage:
#   dns-trap.sh enable      # arm the trap
#   dns-trap.sh disable     # remove rules
#   dns-trap.sh status      # JSON state
set -euo pipefail
source /opt/privacypi/scripts/lib/site.sh
ACTION="${1:-status}"

# DoH provider IP blocks from site.conf (defaults to all major DoH endpoints).
read -ra DOH_IPS <<< "$DOH_BYPASS_IPS"
DOH_IPS+=("76.76.2.0/24")  # ControlD CIDR

LAN_NETS=("$LAN_NET" "$WG_NET")

CHAIN="PRIVACYPI_DNSTRAP"

ensure_chain() {
  iptables -t nat -N "$CHAIN" 2>/dev/null || true
  iptables -t nat -F "$CHAIN"
  # Hook into PREROUTING for LAN-originated DNS
  for net in "${LAN_NETS[@]}"; do
    # UDP & TCP :53 → AdGuard
    iptables -t nat -A "$CHAIN" -s "$net" -p udp --dport 53 \
      -j DNAT --to-destination "$LAN_GW:53"
    iptables -t nat -A "$CHAIN" -s "$net" -p tcp --dport 53 \
      -j DNAT --to-destination "$LAN_GW:53"
    # :853 (DoT) → AdGuard plain :53 (drops the DoT, falls back to UDP)
    iptables -t nat -A "$CHAIN" -s "$net" -p tcp --dport 853 \
      -j DNAT --to-destination "$LAN_GW:53"
  done
  iptables -t nat -A "$CHAIN" -j RETURN
  # Activate
  iptables -t nat -C PREROUTING -j "$CHAIN" 2>/dev/null \
    || iptables -t nat -I PREROUTING 1 -j "$CHAIN"
}

block_doh() {
  iptables -N PRIVACYPI_DOHBLOCK 2>/dev/null || true
  iptables -F PRIVACYPI_DOHBLOCK
  for ip in "${DOH_IPS[@]}"; do
    iptables -A PRIVACYPI_DOHBLOCK -d "$ip" -p tcp --dport 443 -j REJECT --reject-with tcp-reset
    iptables -A PRIVACYPI_DOHBLOCK -d "$ip" -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable
  done
  iptables -A PRIVACYPI_DOHBLOCK -j RETURN
  iptables -C FORWARD -j PRIVACYPI_DOHBLOCK 2>/dev/null \
    || iptables -I FORWARD 1 -j PRIVACYPI_DOHBLOCK
}

remove_rules() {
  iptables -t nat -D PREROUTING -j "$CHAIN" 2>/dev/null || true
  iptables -t nat -F "$CHAIN" 2>/dev/null || true
  iptables -t nat -X "$CHAIN" 2>/dev/null || true
  iptables -D FORWARD -j PRIVACYPI_DOHBLOCK 2>/dev/null || true
  iptables -F PRIVACYPI_DOHBLOCK 2>/dev/null || true
  iptables -X PRIVACYPI_DOHBLOCK 2>/dev/null || true
}

case "$ACTION" in
  enable)
    ensure_chain
    block_doh
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    echo '{"ok":true,"trap":"on","doh_blocked":'${#DOH_IPS[@]}'}'
    ;;
  disable)
    remove_rules
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    echo '{"ok":true,"trap":"off"}'
    ;;
  status)
    if iptables -t nat -C PREROUTING -j "$CHAIN" 2>/dev/null; then
      echo '{"trap":"on"}'
    else
      echo '{"trap":"off"}'
    fi
    ;;
  *) echo '{"ok":false}'; exit 2 ;;
esac
