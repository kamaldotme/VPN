#!/usr/bin/env bash
# vpn-connect.sh — actually bring a VPN tunnel up or down and switch routing.
#
#   vpn-connect.sh up <provider> [server-file]   # connect (config type decides OpenVPN vs WireGuard)
#   vpn-connect.sh nord [country-id]             # NordVPN: fetch the recommended server, then connect
#   vpn-connect.sh nord-countries                # JSON list for the country picker
#   vpn-connect.sh down                          # stop any tunnel, back to Direct
#   vpn-connect.sh stop-tunnels                  # stop tunnels only (caller switches mode)
#   vpn-connect.sh restore                       # boot: re-establish whatever mode was active
#   vpn-connect.sh status                        # JSON
#
# Safety: while a VPN mode is active the firewall only forwards client traffic
# into the tunnel interface, so a dropped tunnel means no internet, never a leak.
# A failed connect attempt puts the previous mode back.
set -uo pipefail
source /opt/privacypi/scripts/lib/site.sh
SCRIPTS=/opt/privacypi/scripts
VPN_DIR=/etc/privacypi/vpn
STATE=/var/lib/privacypi/active-vpn
ACTIVE_OVPN="$VPN_DIR/active.ovpn"
ACTIVE_AUTH="$VPN_DIR/active.auth"
OVPN_UNIT=privacypi-openvpn.service
WG_UNIT=wg-quick@wg0.service
CONNECT_TIMEOUT=40
OVPN_ERR=""

json_str() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }
fail() { printf '{"ok":false,"error":%s}\n' "$(json_str "$1")"; exit 1; }
state_field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$STATE" "$1" 2>/dev/null; }
valid_provider() { [[ "$1" =~ ^[a-z0-9-]{1,32}$ && -d "$VPN_DIR/$1" ]]; }

stop_tunnels() {
  systemctl stop "$OVPN_UNIT" 2>/dev/null || true
  systemctl disable --now "$WG_UNIT" >/dev/null 2>&1 || true
}

# Uploaded configs run as root: strip every directive that can execute code,
# write files elsewhere, or override what we control (device, auth, logging).
sanitize_ovpn() {
  tr -d '\r' < "$1" | grep -viE '^[[:space:]]*(up|down|route-up|route-pre-down|ipchange|tls-verify|auth-user-pass-verify|client-connect|client-disconnect|learn-address|plugin|script-security|daemon|log|log-append|status|writepid|dev|dev-type|auth-user-pass|user|group|chroot|cd|management|setenv|iproute)([[:space:]]|$)'
}

ovpn_up() {  # provider server-file
  local p="$1" file="$2" src="$VPN_DIR/$1/servers/$2"
  [[ -f "$src" ]] || fail "No server file. Upload an .ovpn file for this provider first."
  [[ -s "$VPN_DIR/$p/auth.txt" ]] || grep -qiE '^[[:space:]]*<(cert|key)>' "$src" \
    || fail "Save the username and password for this provider first."
  local tmp; tmp=$(mktemp)
  sanitize_ovpn "$src" > "$tmp"
  grep -qiE '^[[:space:]]*remote[[:space:]]' "$tmp" || { rm -f "$tmp"; fail "That file does not look like an OpenVPN config (no 'remote' line)."; }
  install -m 600 -o root -g root "$tmp" "$ACTIVE_OVPN"; rm -f "$tmp"
  if [[ -s "$VPN_DIR/$p/auth.txt" ]]; then
    install -m 600 -o root -g root "$VPN_DIR/$p/auth.txt" "$ACTIVE_AUTH"
  else
    rm -f "$ACTIVE_AUTH"
  fi
  stop_tunnels
  systemctl reset-failed "$OVPN_UNIT" 2>/dev/null || true
  local t0; t0=$(date '+%Y-%m-%d %H:%M:%S')   # only this attempt's log lines count
  systemctl start "$OVPN_UNIT" || fail "OpenVPN could not start"
  local i
  for ((i=0; i<CONNECT_TIMEOUT; i++)); do
    if ip -4 addr show tun0 2>/dev/null | grep -q 'inet '; then return 0; fi
    systemctl is-active --quiet "$OVPN_UNIT" || sleep 1   # restarting after an error
    local recent; recent=$(journalctl -u "$OVPN_UNIT" -n 40 --no-pager -o cat --since "$t0" 2>/dev/null)
    if grep -q 'AUTH_FAILED' <<<"$recent"; then
      systemctl stop "$OVPN_UNIT"; return 2
    fi
    if grep -q 'Options error' <<<"$recent"; then
      OVPN_ERR=$(grep -m1 'Options error' <<<"$recent" | sed 's/^.*Options error: //' | cut -c1-200)
      systemctl stop "$OVPN_UNIT"; return 3
    fi
    sleep 1
  done
  systemctl stop "$OVPN_UNIT"
  return 1
}

wg_up() {  # provider server-file
  local src="$VPN_DIR/$1/servers/$2"
  [[ -f "$src" ]] || fail "No config file. Upload a WireGuard .conf for this provider first."
  grep -q '^\[Interface\]' "$src" && grep -q '^\[Peer\]' "$src" || fail "That file does not look like a WireGuard config."
  install -d -m 700 /etc/wireguard
  # Drop DNS= (we resolve through our own filtering DNS) and any hook commands.
  tr -d '\r' < "$src" | grep -viE '^[[:space:]]*(DNS|PreUp|PostUp|PreDown|PostDown|SaveConfig)[[:space:]]*=' > /etc/wireguard/wg0.conf
  chmod 600 /etc/wireguard/wg0.conf
  stop_tunnels
  systemctl enable --now "$WG_UNIT" >/dev/null 2>&1 || return 1
  local i
  for ((i=0; i<15; i++)); do
    [[ -n "$(wg show wg0 latest-handshakes 2>/dev/null | awk '$2>0')" ]] && return 0
    ping -c1 -W1 -I wg0 1.1.1.1 >/dev/null 2>&1 || true
    sleep 1
  done
  systemctl disable --now "$WG_UNIT" >/dev/null 2>&1
  return 1
}

connect() {  # provider server-file
  local p="$1" file="$2" prev_mode prev_p prev_s kind rc=0
  prev_mode=$(state_field mode); prev_p=$(state_field provider); prev_s=$(state_field server)
  case "$file" in
    *.conf) kind=wireguard; wg_up "$p" "$file" || rc=$? ;;
    *)      kind=openvpn;   ovpn_up "$p" "$file" || rc=$? ;;
  esac
  if (( rc != 0 )); then
    # Put the previous mode back so clients are not left without internet.
    case "$prev_mode" in
      openvpn|wireguard|"") "$SCRIPTS/route-mode.sh" direct >/dev/null 2>&1 || true ;;
      *) "$SCRIPTS/route-mode.sh" "$prev_mode" "$prev_p" "$prev_s" >/dev/null 2>&1 || true ;;
    esac
    (( rc == 2 )) && fail "The VPN provider rejected the username or password."
    (( rc == 3 )) && fail "This OpenVPN config file is not accepted: ${OVPN_ERR:-unknown option}"
    fail "Could not connect to the VPN server (timed out). Check the internet connection and the config."
  fi
  "$SCRIPTS/route-mode.sh" "$kind" "$p" "$file" >/dev/null 2>&1 || fail "tunnel is up but routing could not be switched"
  printf '{"ok":true,"mode":"%s","provider":"%s","server":%s}\n' "$kind" "$p" "$(json_str "$file")"
}

case "${1:-status}" in
  up)
    P="${2:-}"; FILE="${3:-}"
    valid_provider "$P" || fail "unknown provider"
    if [[ -z "$FILE" ]]; then
      if [[ -L "$VPN_DIR/$P/current.ovpn" ]]; then FILE=$(basename "$(readlink "$VPN_DIR/$P/current.ovpn")")
      else FILE=$(ls -t "$VPN_DIR/$P/servers" 2>/dev/null | grep -E '\.(ovpn|conf)$' | head -n1); fi
    fi
    [[ "$FILE" =~ ^[[:alnum:]._-]+$ ]] || fail "No server file. Upload a config file for this provider first."
    connect "$P" "$FILE"
    ;;

  nord)
    CID="${2:-}"
    [[ -z "$CID" || "$CID" =~ ^[0-9]{1,4}$ ]] || fail "bad country"
    [[ -s "$VPN_DIR/nordvpn/auth.txt" ]] || fail "Save your NordVPN service credentials first (Nord Account → NordVPN → Manual setup)."
    url='https://api.nordvpn.com/v1/servers/recommendations?filters[servers_technologies][identifier]=openvpn_udp&limit=1'
    [[ -n "$CID" ]] && url="$url&filters[country_id]=$CID"
    host=$(curl -fsS -g --max-time 15 "$url" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["hostname"])' 2>/dev/null)
    [[ "$host" =~ ^[a-z0-9-]+\.nordvpn\.com$ ]] || fail "Could not get a server from NordVPN. Is the internet connected?"
    f="$host.udp.ovpn"
    curl -fsS --max-time 20 -o "$VPN_DIR/nordvpn/servers/$f.tmp" "https://downloads.nordcdn.com/configs/files/ovpn_udp/servers/$f" 2>/dev/null \
      && grep -q '^remote ' "$VPN_DIR/nordvpn/servers/$f.tmp" \
      || { rm -f "$VPN_DIR/nordvpn/servers/$f.tmp"; fail "Could not download the NordVPN server config."; }
    mv -f "$VPN_DIR/nordvpn/servers/$f.tmp" "$VPN_DIR/nordvpn/servers/$f"
    connect nordvpn "$f"
    ;;

  nord-countries)
    curl -fsS --max-time 15 'https://api.nordvpn.com/v1/servers/countries' 2>/dev/null | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    print(json.dumps({"ok":True,"countries":[{"id":c["id"],"name":c["name"]} for c in d]}))
except Exception:
    print(json.dumps({"ok":False,"error":"could not reach NordVPN"}))'
    ;;

  down)
    stop_tunnels
    "$SCRIPTS/route-mode.sh" direct >/dev/null 2>&1 || true
    echo '{"ok":true,"mode":"direct"}'
    ;;

  stop-tunnels)
    stop_tunnels; echo '{"ok":true}'
    ;;

  restore)
    mode=$(state_field mode); mode=${mode:-direct}
    case "$mode" in
      openvpn)
        # Routing first: clients stay blocked (never leaked) until the tunnel is up;
        # wan-watch.sh completes the client route when tun0 appears.
        "$SCRIPTS/route-mode.sh" openvpn "$(state_field provider)" "$(state_field server)" || true
        [[ -s "$ACTIVE_OVPN" ]] && systemctl start --no-block "$OVPN_UNIT"
        ;;
      wireguard)
        "$SCRIPTS/route-mode.sh" wireguard "$(state_field provider)" "$(state_field server)" || true
        ;;
      *) "$SCRIPTS/route-mode.sh" "$mode" "$(state_field provider)" "$(state_field server)" ;;
    esac
    ;;

  status)
    tun=false; ip -4 addr show tun0 2>/dev/null | grep -q 'inet ' && tun=true
    wg=false;  ip link show wg0 >/dev/null 2>&1 && wg=true
    configured=$(for p in "$VPN_DIR"/*/; do
      n=$(basename "$p"); c=false; s=0
      [[ -s "$p/auth.txt" ]] && c=true
      s=$(ls "$p/servers" 2>/dev/null | grep -cE '\.(ovpn|conf)$')
      printf '"%s":{"credentials":%s,"servers":%s},' "$n" "$c" "$s"
    done)
    printf '{"ok":true,"mode":"%s","provider":"%s","server":%s,"tun0_up":%s,"wg0_up":%s,"providers":{%s}}\n' \
      "$(state_field mode)" "$(state_field provider)" "$(json_str "$(state_field server)")" "$tun" "$wg" "${configured%,}"
    ;;

  *) echo '{"ok":false,"error":"usage: up <provider> [file]|nord [country]|nord-countries|down|stop-tunnels|restore|status"}'; exit 2 ;;
esac
