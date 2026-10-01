#!/usr/bin/env bash
# ap-config.sh — the PrivacyPi WiFi network (name, password, country, channel).
# hostapd.conf is always rendered from site.conf + /etc/privacypi/wifi-psk.txt;
# nothing else edits it.
#
# Usage:
#   ap-config.sh render [--restart]        # (re)write hostapd.conf
#   ap-config.sh set <ssid> - [--restart|--defer]   # new name; password on STDIN
#   ap-config.sh country <CC> [--restart]  # ISO 3166 alpha-2 regulatory domain
#   ap-config.sh status                    # JSON
#
# --defer restarts hostapd a few seconds later, so the HTTP response that
# triggered the change still reaches the browser before the WiFi drops.
set -uo pipefail
source /opt/privacypi/scripts/lib/site.sh

HOSTAPD_CONF=/etc/hostapd/hostapd.conf
PSK_FILE=/etc/privacypi/wifi-psk.txt
DEFAULT_SSID="PrivacyPi-Setup"
DEFAULT_PSK="privacypi"
ACTION="${1:-status}"

json_str() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }
fail() { printf '{"ok":false,"error":%s}\n' "$(json_str "$1")"; exit 1; }

restart_ap() {
  case "${1:-}" in
    --restart) systemctl restart hostapd >/dev/null 2>&1 || true ;;
    --defer)   systemd-run --quiet --collect --on-active=4 systemctl restart hostapd >/dev/null 2>&1 \
                 || (sleep 4; systemctl restart hostapd) >/dev/null 2>&1 & ;;
  esac
}

render() {
  local psk ssid phy ht="" mfp=false sae=false
  psk=$(head -n1 "$PSK_FILE" 2>/dev/null); [[ ${#psk} -ge 8 ]] || psk="$DEFAULT_PSK"
  ssid="${AP_SSID:-$DEFAULT_SSID}"
  phy=$(cat "/sys/class/net/${AP_IFACE:-none}/phy80211/name" 2>/dev/null || true)
  if [[ -n "$phy" ]]; then
    local info; info=$(iw phy "$phy" info 2>/dev/null || true)
    grep -q "HT20" <<<"$info" && ht=1
    grep -qw "SAE" <<<"$info" && sae=true
    grep -q "MFP"  <<<"$info" && mfp=true
  fi
  install -d /etc/hostapd
  local tmp; tmp=$(mktemp)
  {
    echo "# Rendered by ap-config.sh — do not edit; change settings in the dashboard."
    echo "interface=${AP_IFACE:-wlan0}"
    echo "bridge=$LAN_BRIDGE"
    echo "driver=nl80211"
    echo "ssid=$ssid"
    echo "utf8_ssid=1"
    echo "country_code=$WIFI_COUNTRY"
    echo "hw_mode=g"
    echo "channel=$AP_CHANNEL"
    [[ -n "$ht" ]] && echo "ieee80211n=1"
    echo "wmm_enabled=1"
    echo "auth_algs=1"
    echo "wpa=2"
    echo "rsn_pairwise=CCMP"
    # Baseline WPA2 so every adapter can bring the network up. WPA3 transition
    # mode + management-frame protection only when asked for and supported.
    if [[ "$AP_HARDEN" == "1" && "$sae" == true && "$mfp" == true ]]; then
      echo "wpa_key_mgmt=WPA-PSK SAE"
      echo "ieee80211w=1"
      echo "sae_require_mfp=1"
    else
      echo "wpa_key_mgmt=WPA-PSK"
      [[ "$AP_HARDEN" == "1" && "$mfp" == true ]] && echo "ieee80211w=1"
    fi
    echo "wpa_passphrase=$psk"
    echo "ap_isolate=1"
  } > "$tmp"
  install -m 600 -o root -g root "$tmp" "$HOSTAPD_CONF"; rm -f "$tmp"
}

case "$ACTION" in
  render)
    render; restart_ap "${2:-}"
    ;;

  set)
    SSID="${2:-}"; FLAG="${4:-}"
    [[ "$SSID" =~ ^[A-Za-z0-9\ _.-]{1,32}$ && "$SSID" != " "* && "$SSID" != *" " ]] \
      || fail "WiFi name: 1-32 characters — letters, numbers, spaces, dot, dash or underscore"
    IFS= read -r PSK || true
    [[ ${#PSK} -ge 8 && ${#PSK} -le 63 ]] || fail "WiFi password must be 8-63 characters"
    LC_ALL=C grep -q '^[ -~]*$' <<<"$PSK" || fail "WiFi password: plain letters, numbers and symbols only"
    tmp=$(mktemp); printf '%s\n' "$PSK" > "$tmp"
    install -m 640 -o root -g privacypi "$tmp" "$PSK_FILE"; rm -f "$tmp"
    site_conf_set AP_SSID "\"$SSID\""
    AP_SSID="$SSID"
    render; restart_ap "$FLAG"
    printf '{"ok":true,"ssid":%s}\n' "$(json_str "$SSID")"
    ;;

  country)
    CC="${2:-}"
    [[ "$CC" =~ ^[A-Z]{2}$ ]] || fail "country must be a 2-letter code"
    site_conf_set WIFI_COUNTRY "$CC"; WIFI_COUNTRY="$CC"
    iw reg set "$CC" 2>/dev/null || true
    # Persist for the kernel the same way raspi-config does.
    for c in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
      if [[ -w "$c" ]]; then
        sed -i -e 's/\s*cfg80211.ieee80211_regdom=\S*//' -e "s/\(.*\)/\1 cfg80211.ieee80211_regdom=$CC/" "$c" 2>/dev/null || true
        break
      fi
    done
    render; restart_ap "${3:-}"
    printf '{"ok":true,"country":"%s"}\n' "$CC"
    ;;

  status)
    psk=$(head -n1 "$PSK_FILE" 2>/dev/null || true)
    is_default=false
    [[ "${AP_SSID:-$DEFAULT_SSID}" == "$DEFAULT_SSID" || -z "$psk" || "$psk" == "$DEFAULT_PSK" ]] && is_default=true
    ap_state=$(systemctl is-active hostapd 2>/dev/null | head -n1); ap_state=${ap_state:-unknown}
    printf '{"ok":true,"ssid":%s,"iface":"%s","channel":"%s","country":"%s","setup_default":%s,"hostapd":"%s"}\n' \
      "$(json_str "${AP_SSID:-$DEFAULT_SSID}")" "${AP_IFACE:-}" "$AP_CHANNEL" "$WIFI_COUNTRY" "$is_default" "$ap_state"
    ;;

  *) echo '{"ok":false,"error":"usage: render|set <ssid> -|country <CC>|status"}'; exit 2 ;;
esac
