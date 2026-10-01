#!/usr/bin/env bash
# wan-watch.sh — keeps client routing in step with the uplink.
# The client routing table (100) is written when a mode is applied; if the
# uplink appears or changes later (cable plugged in after boot, DHCP renewal
# with a new gateway, WiFi-WAN reconnect, VPN tunnel re-established) the table
# is stale and clients have no internet. This loop notices and re-applies the
# current mode. Cheap: two `ip` calls every few seconds.
set -uo pipefail
SCRIPTS=/opt/privacypi/scripts
STATE=/var/lib/privacypi/active-vpn
INTERVAL=5

state_field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$STATE" "$1" 2>/dev/null; }

# AdGuard Home downloads its blocklists when it starts; if the device had no
# internet at that moment (typical first boot) it would not retry for 24 h.
# Ask it to refresh as soon as the uplink works, until the lists are there.
last_refresh=0
refresh_blocklists() {
  local now; now=$(date +%s)
  (( now - last_refresh < 60 )) && return
  [[ -n "$(find /opt/AdGuardHome/data/filters -name '*.txt' -size +50k 2>/dev/null | head -n1)" ]] && return
  ip -4 route show default 2>/dev/null | grep -q . || return
  last_refresh=$now
  local pw; pw=$(sed -n 2p /etc/privacypi/adguard.creds 2>/dev/null); [[ -n "$pw" ]] || return
  curl -s -m 20 -o /dev/null -u "admin:$pw" -H 'Content-Type: application/json' \
    -d '{"whitelist":false}' http://127.0.0.1:3000/control/filtering/refresh 2>/dev/null \
    && echo "wan-watch: asked AdGuard Home to download its blocklists"
}

while sleep "$INTERVAL"; do
  refresh_blocklists
  [[ -f /etc/privacypi/setup-complete && -f "$STATE" ]] || continue
  mode=$(state_field mode)
  have=$(ip -4 route show table 100 default 2>/dev/null | head -n1)
  case "$mode" in
    direct|tor|proxy)
      wan=$(bash -c 'source /opt/privacypi/scripts/lib/site.sh; echo "$WAN_IFACE"')
      gw=$(ip -4 route show default dev "$wan" 2>/dev/null | awk '/default/{print $3; exit}')
      want=""; [[ -n "$gw" ]] && want="default via $gw dev $wan"
      ;;
    openvpn)   want=""; ip link show tun0 up >/dev/null 2>&1 && want="dev tun0" ;;
    wireguard) continue ;;   # wg-quick maintains its own policy routing
    *) continue ;;
  esac
  [[ -z "$want" ]] && continue
  if [[ "$have" != *"$want"* ]]; then
    echo "wan-watch: uplink changed (table 100: '${have:-none}', want '$want') — re-applying $mode"
    "$SCRIPTS/route-mode.sh" "$mode" "$(state_field provider)" "$(state_field server)" >/dev/null 2>&1 || true
  fi
done
