#!/usr/bin/env bash
# setup-mode.sh — out-of-box behaviour until the wizard is finished.
# While in setup mode the (publicly known) setup WiFi gives access to the
# setup page ONLY: no internet is forwarded, every web request lands on the
# wizard (so phones pop it up as a "sign in to network" page), and all DNS
# answers point at the Pi.
#
# Usage:
#   setup-mode.sh on      # apply rules + start the captive DNS (boot, when setup is pending)
#   setup-mode.sh rules   # (re)apply only the firewall rules (called by route-mode.sh)
#   setup-mode.sh dns     # run the captive DNS in the foreground (privacypi-setup-dns.service)
#   setup-mode.sh off     # leave setup mode
#   setup-mode.sh status
set -uo pipefail
source /opt/privacypi/scripts/lib/site.sh
CAPTIVE_DNS_PORT=5354
FWD_CHAIN="FWD-${LAN_BRIDGE}"

rules() {
  # No internet through the setup network
  iptables -F "$FWD_CHAIN" 2>/dev/null || true
  iptables -A "$FWD_CHAIN" -j REJECT --reject-with icmp-net-unreachable 2>/dev/null || true
  # Everything web -> the wizard; all DNS -> captive resolver
  iptables -t nat -I PREROUTING 1 -i "$LAN_BRIDGE" -p udp --dport 53 -j REDIRECT --to-ports "$CAPTIVE_DNS_PORT"
  iptables -t nat -I PREROUTING 1 -i "$LAN_BRIDGE" -p tcp --dport 53 -j REDIRECT --to-ports "$CAPTIVE_DNS_PORT"
  iptables -t nat -I PREROUTING 1 -i "$LAN_BRIDGE" -p tcp --dport 80 -j REDIRECT --to-ports 80
}

case "${1:-status}" in
  on)
    setup_done && { echo "setup already complete"; exit 0; }
    rules
    systemctl start privacypi-setup-dns.service 2>/dev/null || true
    echo "setup mode on"
    ;;
  rules)
    setup_done || rules
    ;;
  dns)
    exec dnsmasq --keep-in-foreground --conf-file=/dev/null --port="$CAPTIVE_DNS_PORT" \
      --no-resolv --no-hosts --address="/#/$LAN_GW" --local-ttl=0 \
      --interface="$LAN_BRIDGE" --bind-dynamic --pid-file=/run/privacypi-setup-dns.pid
    ;;
  off)
    systemctl stop privacypi-setup-dns.service 2>/dev/null || true
    echo "setup mode off"
    ;;
  status)
    if setup_done; then echo '{"setup_mode":false}'; else echo '{"setup_mode":true}'; fi
    ;;
  *) echo "usage: setup-mode.sh on|rules|dns|off|status" >&2; exit 2 ;;
esac
