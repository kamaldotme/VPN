#!/usr/bin/env bash
set -euo pipefail
source /opt/privacypi/scripts/lib/site.sh

iptables -P INPUT ACCEPT
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT
iptables -F
iptables -t nat -F
iptables -t mangle -F
iptables -X
iptables -t nat -X 2>/dev/null || true

# LAN forward chain (one bridge for the AP clients)
iface="$LAN_BRIDGE"
iptables -N FWD-$iface 2>/dev/null || iptables -F FWD-$iface
iptables -A FORWARD -i $iface -j FWD-$iface
iptables -A FWD-$iface -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -A FWD-$iface -o "$WAN_IFACE" -j ACCEPT
iptables -A FORWARD -i "$WAN_IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# NAT
iptables -t nat -A POSTROUTING -o "$WAN_IFACE" -j MASQUERADE

# DNS forced to Pi (DNAT redirect)
iptables -t nat -A PREROUTING -i "$LAN_BRIDGE" -p udp ! -d "$LAN_GW" --dport 53 -j DNAT --to-destination "$LAN_GW"
iptables -t nat -A PREROUTING -i "$LAN_BRIDGE" -p tcp ! -d "$LAN_GW" --dport 53 -j DNAT --to-destination "$LAN_GW"

# Leak prevention
for port in 3478 3479 5349 5350; do
  iptables -A FORWARD -p udp --dport $port -j DROP
  iptables -A FORWARD -p tcp --dport $port -j DROP
done
iptables -A FORWARD -p udp --dport 1900 -j DROP
iptables -A FORWARD -p udp --dport 137:139 -j DROP
iptables -A FORWARD -p tcp --dport 137:139 -j DROP
iptables -A FORWARD -p udp --dport 5355 -j DROP

mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4
ip6tables -P FORWARD DROP 2>/dev/null || true
ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true

echo "Base firewall applied."
