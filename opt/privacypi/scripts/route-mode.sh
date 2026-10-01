#!/usr/bin/env bash
# route-mode.sh — atomic routing switcher for PrivacyPi.
# Modes: direct | openvpn | wireguard | tor | proxy | killswitch
set -euo pipefail
source /opt/privacypi/scripts/lib/site.sh

FWD_CHAIN="FWD-${LAN_BRIDGE}"

# Fire internal alert on killswitch (best-effort, never blocks)
fire_alert() {
  local trigger="$1" message="$2"
  local secret_file=/etc/privacypi/alert.secret
  [[ -f "$secret_file" ]] || return 0
  local secret; secret=$(cat "$secret_file" 2>/dev/null)
  [[ -z "$secret" ]] && return 0
  curl -sk --max-time 3 -X POST -H "X-Internal-Secret: $secret" \
    -d "message=$message" -d "level=warn" \
    "https://${FLASK_INTERNAL}/api/alert/internal/$trigger" >/dev/null 2>&1 || true
}


MODE="${1:-}"
PROVIDER="${2:-}"
SERVER="${3:-}"
STATE_FILE=/var/lib/privacypi/active-vpn
LOG=/var/log/privacypi/mode.log
NOW=$(date -Iseconds)

usage() {
  echo "Usage: $0 {direct|openvpn|wireguard|tor|proxy|killswitch} [provider] [server]" >&2
  exit 2
}
[[ -z "$MODE" ]] && usage

# Reset chains atomically — drop existing first
iptables -F "$FWD_CHAIN"
iptables -t nat -F POSTROUTING
iptables -t nat -F PREROUTING

# Always keep DNS forced to Pi (re-add after flush)
iptables -t nat -A PREROUTING -i "$LAN_BRIDGE" -p udp ! -d "$LAN_GW" --dport 53 -j DNAT --to-destination "$LAN_GW"
iptables -t nat -A PREROUTING -i "$LAN_BRIDGE" -p tcp ! -d "$LAN_GW" --dport 53 -j DNAT --to-destination "$LAN_GW"

# Always allow conntrack reverse traffic
iptables -A "$FWD_CHAIN" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

OUT_IF=""
case "$MODE" in
  direct)
    OUT_IF="$WAN_IFACE"
    iptables -A "$FWD_CHAIN" -o "$WAN_IFACE" -j ACCEPT
    iptables -t nat -A POSTROUTING -o "$WAN_IFACE" -j MASQUERADE
    ;;
  openvpn)
    OUT_IF="tun0"
    iptables -A "$FWD_CHAIN" -o tun0 -j ACCEPT
    iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
    ;;
  wireguard)
    OUT_IF="wg0"
    iptables -A "$FWD_CHAIN" -o wg0 -j ACCEPT
    iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE
    ;;
  tor)
    # Redirect all TCP from clients to Tor's TransPort
    OUT_IF="tor"
    # ...except traffic to the Pi itself: the dashboard must stay reachable.
    iptables -t nat -A PREROUTING -i "$LAN_BRIDGE" -p tcp --syn ! -d "$LAN_GW" -j REDIRECT --to-ports "$TOR_TRANS_PORT"
    # All client DNS resolves through Tor — inserted first so it wins over the
    # generic "force DNS to the Pi" rule above (which would resolve outside Tor).
    iptables -t nat -I PREROUTING 1 -i "$LAN_BRIDGE" -p udp --dport 53 -j REDIRECT --to-ports "$TOR_DNS_PORT"
    # Accept local Tor connections
    iptables -A "$FWD_CHAIN" -d 127.0.0.1 -j ACCEPT
    iptables -A "$FWD_CHAIN" -j REJECT --reject-with icmp-net-unreachable
    iptables -t nat -A POSTROUTING -o "$WAN_IFACE" -j MASQUERADE  # Tor's outbound goes via the WAN
    ;;
  proxy)
    OUT_IF="tun0"  # tun2socks creates tun0 from SOCKS proxies (Plan 6)
    iptables -A "$FWD_CHAIN" -o tun0 -j ACCEPT
    iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
    ;;
  killswitch)
    OUT_IF=""
    # No allow rules — kill switch
    fire_alert "mode.killswitch" "PrivacyPi kill switch armed at $NOW (mode was: $(cat /var/lib/privacypi/active-vpn 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("mode","?"))' 2>/dev/null || echo unknown))"
    ;;
  *)
    usage ;;
esac

# Restore base iptables that should always exist (leak prevention)
for port in 3478 3479 5349 5350; do
  iptables -A FORWARD -p udp --dport $port -j DROP 2>/dev/null || true
  iptables -A FORWARD -p tcp --dport $port -j DROP 2>/dev/null || true
done
iptables -A FORWARD -p udp --dport 1900 -j DROP 2>/dev/null || true
iptables -A FORWARD -p udp --dport 137:139 -j DROP 2>/dev/null || true
iptables -A FORWARD -p tcp --dport 137:139 -j DROP 2>/dev/null || true
iptables -A FORWARD -p udp --dport 5355 -j DROP 2>/dev/null || true

# Update routing table 100 (client egress) — a single default guarantees
# exactly one egress regardless of what the main table prefers.
GW=""
case "$MODE" in
  direct)    GW="$(ip -4 route show default dev "$WAN_IFACE" | awk '/default/{print $3; exit}')" ;;
  openvpn)
    if ip link show tun0 up >/dev/null 2>&1; then
      # OpenVPN often uses 0.0.0.0/1 override instead of default; pick the gateway
      # from any route on tun0
      GW="$(ip -4 route show 0.0.0.0/1 dev tun0 2>/dev/null | awk '/via/{print $3; exit}')"
      [[ -z "$GW" ]] && GW="$(ip -4 route show default dev tun0 2>/dev/null | awk '/default/{print $3; exit}')"
      [[ -z "$GW" ]] && GW="$(ip -4 addr show tun0 | awk '/inet /{split($2,a,"/"); print a[1]; exit}')"
    fi ;;
  wireguard) ip link show wg0  up >/dev/null 2>&1 && GW="$(ip -4 route show default dev wg0  | awk '/default/{print $3; exit}')" ;;
  tor|proxy) GW="$(ip -4 route show default dev "$WAN_IFACE" | awk '/default/{print $3; exit}')" ;;
esac

ip route flush table 100 2>/dev/null || true
ip route add "$LAN_NET" dev "$LAN_BRIDGE" src "$LAN_GW" table 100
if [[ -n "$GW" && "$MODE" != "killswitch" ]]; then
  case "$MODE" in
    tor|proxy) ip route add default via "$GW" dev "$WAN_IFACE" table 100 ;;
    *)         ip route add default via "$GW" dev "$OUT_IF" table 100 ;;
  esac
fi

# Upstream DNS for the Pi's resolver. Encrypted (DNS-over-TLS) whenever queries
# leave over the plain uplink; inside a VPN tunnel plain :53 is used because
# some providers (NordVPN) block port 853 and the tunnel already encrypts it.
FWD_SRC=/opt/privacypi/system/etc/privacypi
FWD_DST=/etc/unbound/unbound.conf.d/privacypi-forward.conf
case "$MODE" in
  openvpn|wireguard) FWD_WANT="$FWD_SRC/unbound-forward-plain.conf" ;;
  *)                 FWD_WANT="$FWD_SRC/unbound-forward-dot.conf" ;;
esac
if [[ -f "$FWD_WANT" ]] && ! cmp -s "$FWD_WANT" "$FWD_DST" 2>/dev/null; then
  install -m 644 "$FWD_WANT" "$FWD_DST" 2>/dev/null \
    && { systemctl restart unbound 2>/dev/null || true; }   # restart, not reload: a reload does not
                                                            # load the TLS certificate bundle (verified in tests/e2e.sh)
fi

# Until the setup wizard is finished the setup network must stay captive.
/opt/privacypi/scripts/setup-mode.sh rules 2>/dev/null || true

# Persist state
mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$LOG")"
printf '{"mode":"%s","provider":"%s","server":"%s","since":"%s","out_iface":"%s"}\n' \
  "$MODE" "$PROVIDER" "$SERVER" "$NOW" "$OUT_IF" > "$STATE_FILE"
chmod 644 "$STATE_FILE"

echo "[$NOW] mode=$MODE provider=$PROVIDER server=$SERVER out_if=$OUT_IF" >> "$LOG"

# Persist iptables
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4

echo "Routing mode: $MODE${OUT_IF:+ via $OUT_IF}"
