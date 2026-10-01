#!/usr/bin/env bash
# NTP containment: redirect all LAN NTP queries to local chrony.
# Devices contacting pool.ntp.org leak their existence + an approximate
# wakeup pattern. By running chrony locally and trapping :123, every
# clock query stays on the Pi.
#
# Usage:
#   ntp-trap.sh enable   # install chrony if needed, configure, redirect
#   ntp-trap.sh disable
#   ntp-trap.sh status
set -euo pipefail
source /opt/privacypi/scripts/lib/site.sh
ACTION="${1:-status}"
CHAIN="PRIVACYPI_NTPTRAP"
LAN_NETS=("$LAN_NET" "$WG_NET")

ensure_chrony() {
  if ! command -v chronyd >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y chrony 2>&1 | tail -2
  fi
  # Configure chrony to serve LAN clients (still uses upstream NTP itself)
  cat > /etc/chrony/conf.d/privacypi.conf <<EOF
allow $LAN_NET
allow $WG_NET
local stratum 10
bindaddress $LAN_GW
EOF
  systemctl enable --now chrony 2>&1 | tail -2 || systemctl restart chrony
  sleep 1
  systemctl is-active chrony
}

redirect_rules() {
  iptables -t nat -N "$CHAIN" 2>/dev/null || true
  iptables -t nat -F "$CHAIN"
  for net in "${LAN_NETS[@]}"; do
    iptables -t nat -A "$CHAIN" -s "$net" -p udp --dport 123 \
      -j DNAT --to-destination "$LAN_GW:123"
  done
  iptables -t nat -A "$CHAIN" -j RETURN
  iptables -t nat -C PREROUTING -j "$CHAIN" 2>/dev/null \
    || iptables -t nat -I PREROUTING 1 -j "$CHAIN"
}

remove_rules() {
  iptables -t nat -D PREROUTING -j "$CHAIN" 2>/dev/null || true
  iptables -t nat -F "$CHAIN" 2>/dev/null || true
  iptables -t nat -X "$CHAIN" 2>/dev/null || true
}

case "$ACTION" in
  enable)
    ensure_chrony
    redirect_rules
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    echo '{"ok":true,"chrony":"active"}'
    ;;
  disable)
    remove_rules
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    echo '{"ok":true}'
    ;;
  status)
    ON="false"
    iptables -t nat -C PREROUTING -j "$CHAIN" 2>/dev/null && ON="true"
    CHR=$(systemctl is-active chrony 2>/dev/null || echo "inactive")
    echo "{\"trap\":$ON,\"chrony\":\"$CHR\"}"
    ;;
  *) echo '{"ok":false}'; exit 2 ;;
esac
