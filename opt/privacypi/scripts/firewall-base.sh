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

# --- INPUT: what may reach the Pi itself ---------------------------------------
# The upstream network (home LAN, hotel WiFi, VPN tunnel) is untrusted: from
# there only replies, ping and the WireGuard travel-server port get in. The
# dashboard, DNS, AdGuard and Tor ports are reachable from the PrivacyPi WiFi
# only (ADMIN_ON_WAN=1 in site.conf opens the dashboard upstream too).
iptables -N PP-INPUT
iptables -A INPUT -j PP-INPUT
iptables -A PP-INPUT -i lo -j ACCEPT
iptables -A PP-INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -A PP-INPUT -i "$LAN_BRIDGE" -j ACCEPT
iptables -A PP-INPUT -i wg-srv -j ACCEPT
iptables -A PP-INPUT -p icmp -j ACCEPT
iptables -A PP-INPUT -p udp --dport 68 -j ACCEPT
iptables -A PP-INPUT -p udp --dport "$WG_PORT" -j ACCEPT
iptables -A PP-INPUT -p tcp --dport 22 -j ACCEPT          # sshd is off unless enabled for development
if [[ "$ADMIN_ON_WAN" == "1" ]]; then
  iptables -A PP-INPUT -p tcp -m multiport --dports 80,443 -j ACCEPT
fi
iptables -A PP-INPUT -j DROP

if ip6tables -L INPUT -n >/dev/null 2>&1; then
  ip6tables -F INPUT
  ip6tables -A INPUT -i lo -j ACCEPT
  ip6tables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  ip6tables -A INPUT -i "$LAN_BRIDGE" -j ACCEPT
  ip6tables -A INPUT -p ipv6-icmp -j ACCEPT
  ip6tables -A INPUT -j DROP
fi

# LAN forward chain (one bridge for the AP clients)
iface="$LAN_BRIDGE"
iptables -N FWD-$iface 2>/dev/null || iptables -F FWD-$iface
iptables -A FORWARD -i $iface -j FWD-$iface
iptables -A FWD-$iface -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -A FWD-$iface -o "$WAN_IFACE" -j ACCEPT
# Replies to connections we allowed out — whichever interface they return on
# (the uplink in Direct mode, tun0/wg0 in VPN and proxy modes).
iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

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
