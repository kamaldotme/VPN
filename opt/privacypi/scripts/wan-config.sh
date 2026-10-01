#!/usr/bin/env bash
# wan-config.sh — choose how the Pi reaches the internet: wired Ethernet or the
# built-in WiFi radio acting as a client/station to an upstream network.
#
# Usage:
#   wan-config.sh status              # JSON of current WAN state
#   wan-config.sh scan                # JSON list of nearby WiFi networks
#   wan-config.sh set-ethernet        # switch WAN to wired
#   wan-config.sh set-wifi <ssid> -   # switch WAN to WiFi; PSK read from STDIN
#
# Safety: switching to WiFi validates association + DHCP + reachability within a
# timeout and AUTO-ROLLS-BACK to ethernet on failure. The admin UI is reached
# over the AP/LAN side (independent of WAN), so a failed switch never locks the
# admin out — it only affects client internet, which rollback restores.
set -uo pipefail
source /opt/privacypi/scripts/lib/site.sh

SCRIPTS=/opt/privacypi/scripts
SYSNET_SRC=/opt/privacypi/system/etc/systemd/network/30-wlan0-wan.network
SYSNET_DST=/etc/systemd/network/30-wlan0-wan.network
WPA_CONF=/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
WPA_UNIT="wpa_supplicant@${WIFI_WAN_IFACE}.service"
VALIDATE_TIMEOUT=25
: "${WAN_WIFI_COUNTRY:=US}"

ACTION="${1:-status}"

die_json() { printf '{"ok":false,"error":%s}\n' "$(json_str "$1")"; exit 1; }
json_str() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

# --- atomically upsert KEY=VALUE in site.conf --------------------------------
set_conf_key() {
  local key="$1" val="$2" tmp
  tmp=$(mktemp)
  if grep -qE "^[#[:space:]]*${key}=" "$SITE_CONF" 2>/dev/null; then
    sed -E "s|^[#[:space:]]*${key}=.*|${key}=${val}|" "$SITE_CONF" > "$tmp"
  else
    cat "$SITE_CONF" > "$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
  fi
  install -m 644 -o root -g root "$tmp" "$SITE_CONF"
  rm -f "$tmp"
}

oper() { cat "/sys/class/net/$1/operstate" 2>/dev/null || echo "missing"; }

wifi_associated() {
  wpa_cli -i "$WIFI_WAN_IFACE" status 2>/dev/null | grep -q '^wpa_state=COMPLETED'
}

reapply_routing() {
  # Re-read the (now-updated) site.conf inside each script and rebuild NAT +
  # the table-100 client default for whatever routing mode is active.
  local mode
  mode=$(python3 -c 'import json,sys;print(json.load(open("/var/lib/privacypi/active-vpn")).get("mode","direct"))' 2>/dev/null || echo direct)
  bash "$SCRIPTS/routing-vlan.sh" >/dev/null 2>&1 || true
  bash "$SCRIPTS/route-mode.sh" "$mode" >/dev/null 2>&1 || true
}

case "$ACTION" in
  status)
    assoc=false; wifi_associated && assoc=true
    ip4=$(ip -4 addr show "$WAN_IFACE" 2>/dev/null | awk '/inet /{print $2; exit}')
    gw=$(ip -4 route show default dev "$WAN_IFACE" 2>/dev/null | awk '/default/{print $3; exit}')
    python3 - "$WAN_MODE" "$WAN_IFACE" "$(oper "$ETH_IFACE")" "$(oper "$WIFI_WAN_IFACE")" \
              "$WAN_WIFI_SSID" "$assoc" "$ip4" "$gw" <<'PY'
import json,sys
_,mode,iface,eth,wlan,ssid,assoc,ip4,gw = sys.argv
print(json.dumps({"ok":True,"wan_mode":mode,"wan_iface":iface,
  "eth_oper":eth,"wlan_oper":wlan,"wifi_ssid":ssid,
  "associated":assoc=="true","ip":ip4,"gw":gw}))
PY
    ;;

  scan)
    ip link set "$WIFI_WAN_IFACE" up 2>/dev/null || true
    raw=$(iw dev "$WIFI_WAN_IFACE" scan 2>/dev/null || true)
    printf '%s' "$raw" | python3 -c '
import sys,json,re
nets={}
ssid=sig=sec=None
def flush():
    if ssid:
        cur=nets.get(ssid)
        if cur is None or (sig is not None and sig>cur["signal"]):
            nets[ssid]={"ssid":ssid,"signal":sig if sig is not None else -100,"security":sec or "open"}
for line in sys.stdin:
    line=line.strip()
    if line.startswith("BSS "):
        flush(); ssid=None; sig=None; sec="open"
    elif line.startswith("signal:"):
        m=re.search(r"(-?\d+\.?\d*)",line); sig=float(m.group(1)) if m else None
    elif line.startswith("SSID:"):
        ssid=line[5:].strip()
    elif "WPA" in line or "RSN" in line:
        sec="wpa"
flush()
out=sorted([n for n in nets.values() if n["ssid"]],key=lambda n:-n["signal"])
print(json.dumps({"ok":True,"networks":out}))
' || die_json "scan failed"
    ;;

  set-ethernet)
    systemctl disable --now "$WPA_UNIT" 2>/dev/null || true
    ip addr flush dev "$WIFI_WAN_IFACE" 2>/dev/null || true
    ip link set "$WIFI_WAN_IFACE" down 2>/dev/null || true
    set_conf_key WAN_MODE ethernet
    set_conf_key WAN_IFACE "$ETH_IFACE"
    set_conf_key WAN_WIFI_SSID ""
    networkctl reload 2>/dev/null || true
    reapply_routing
    printf '{"ok":true,"wan_mode":"ethernet","wan_iface":"%s"}\n' "$ETH_IFACE"
    ;;

  set-wifi)
    SSID="${2:-}"
    [[ -z "$SSID" ]] && die_json "ssid required"
    PSK=$(cat)                       # read passphrase from stdin (never argv)
    [[ ${#PSK} -ge 8 && ${#PSK} -le 63 ]] || die_json "psk must be 8-63 chars"

    # Snapshot for rollback
    PREV_MODE="$WAN_MODE"; PREV_IFACE="$WAN_IFACE"; PREV_SSID="$WAN_WIFI_SSID"

    rollback() {
      systemctl disable --now "$WPA_UNIT" 2>/dev/null || true
      ip addr flush dev "$WIFI_WAN_IFACE" 2>/dev/null || true
      ip link set "$WIFI_WAN_IFACE" down 2>/dev/null || true
      set_conf_key WAN_MODE "$PREV_MODE"
      set_conf_key WAN_IFACE "$PREV_IFACE"
      set_conf_key WAN_WIFI_SSID "$PREV_SSID"
      networkctl reload 2>/dev/null || true
      reapply_routing
    }

    # Ensure the networkd DHCP profile for wlan0 is present
    [[ -f "$SYSNET_DST" ]] || { [[ -f "$SYSNET_SRC" ]] && install -m 644 "$SYSNET_SRC" "$SYSNET_DST"; }

    # Write supplicant config with a HASHED psk (never plaintext on disk)
    install -d -m 755 /etc/wpa_supplicant
    tmp=$(mktemp)
    {
      echo "ctrl_interface=/run/wpa_supplicant"
      echo "ctrl_interface_group=0"
      echo "update_config=1"
      echo "country=$WAN_WIFI_COUNTRY"
      echo ""
      wpa_passphrase "$SSID" "$PSK" | grep -vE '^\s*#psk='
    } > "$tmp" 2>/dev/null
    if ! grep -q '^[[:space:]]*psk=' "$tmp"; then rm -f "$tmp"; die_json "failed to hash psk"; fi
    install -m 600 -o root -g root "$tmp" "$WPA_CONF"; rm -f "$tmp"

    # Bring the station up
    ip link set "$WIFI_WAN_IFACE" up 2>/dev/null || true
    systemctl enable --now "$WPA_UNIT" >/dev/null 2>&1 || { rollback; die_json "wpa_supplicant failed to start"; }
    networkctl reload 2>/dev/null || true

    # Validate: association -> DHCP IPv4 -> reachability, within the timeout
    ok=false
    for _ in $(seq 1 "$VALIDATE_TIMEOUT"); do
      if wifi_associated; then
        ip4=$(ip -4 addr show "$WIFI_WAN_IFACE" 2>/dev/null | awk '/inet /{print $2; exit}')
        if [[ -n "$ip4" ]]; then
          if ping -I "$WIFI_WAN_IFACE" -c1 -W2 1.1.1.1 >/dev/null 2>&1; then ok=true; break; fi
        fi
      fi
      sleep 1
    done

    if [[ "$ok" != true ]]; then
      rollback
      die_json "WiFi failed to connect (association/DHCP/reachability) — rolled back to ethernet"
    fi

    # Persist success
    set_conf_key WAN_MODE wifi
    set_conf_key WAN_IFACE "$WIFI_WAN_IFACE"
    set_conf_key WAN_WIFI_SSID "$SSID"
    reapply_routing
    ip4=$(ip -4 addr show "$WIFI_WAN_IFACE" 2>/dev/null | awk '/inet /{print $2; exit}')
    printf '{"ok":true,"wan_mode":"wifi","wan_iface":"%s","ssid":%s,"ip":"%s"}\n' \
      "$WIFI_WAN_IFACE" "$(json_str "$SSID")" "$ip4"
    ;;

  *)
    echo '{"ok":false,"error":"usage: status|scan|set-ethernet|set-wifi <ssid> -"}'; exit 2 ;;
esac
