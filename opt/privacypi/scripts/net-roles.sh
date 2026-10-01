#!/usr/bin/env bash
# net-roles.sh — decide which network interface does which job, by capability
# (never by adapter model or MAC), then render the config that depends on it.
#
# Roles:
#   ETH_IFACE       wired uplink (may be unplugged)
#   AP_IFACE        radio that broadcasts the PrivacyPi WiFi
#   WIFI_WAN_IFACE  spare radio that can join an upstream WiFi (may be empty)
#
# Policy:
#   - The built-in radio is the access point whenever it supports AP mode: its
#     driver (brcmfmac) is the well-trodden AP path on a Pi. USB adapters'
#     AP modes are hit-and-miss — the Edimax EW-7811Un (rtl8192cu) froze a Pi 4
#     outright whenever its AP was restarted.
#   - Any other radio becomes the WiFi-WAN client (plain station mode works on
#     practically every adapter, AP-capable or not).
#   - Only if there is no AP-capable built-in radio does an external one take
#     the AP role.
#   - With a single radio there is no WiFi-WAN: internet must come by cable.
#   - ROLE_LOCK=1 in site.conf keeps the configured roles (config is still rendered).
#
# Runs at every boot before networkd/hostapd (privacypi-net-roles.service), so
# kernel interface names swapping between boots or a changed adapter are handled.
#
# Usage:
#   net-roles.sh apply     # detect, write site.conf, render configs (default)
#   net-roles.sh detect    # print the detected roles as KEY=VALUE, change nothing
set -uo pipefail

# Overridable for tests
: "${SYSFS:=/sys}"
: "${IW:=iw}"
: "${SITE_CONF:=/etc/privacypi/site.conf}"
: "${NETD_DIR:=/etc/systemd/network}"
: "${HOSTAPD_CONF:=/etc/hostapd/hostapd.conf}"
: "${WPA_DIR:=/etc/wpa_supplicant}"

ACTION="${1:-apply}"
log() { echo "net-roles: $*"; }

conf_get() { [[ -r "$SITE_CONF" ]] && awk -F= -v k="$1" '$1==k{sub(/[[:space:]]*#.*/,"",$2); gsub(/^[ \t"]+|[ \t"]+$/,"",$2); print $2; exit}' "$SITE_CONF"; }

conf_set() {
  local key="$1" val="$2" tmp
  tmp=$(mktemp)
  if grep -qE "^[#[:space:]]*${key}=" "$SITE_CONF" 2>/dev/null; then
    # Replace the first (possibly commented) occurrence, drop later duplicates.
    awk -v k="$key" -v v="$val" '
      $0 ~ "^[#[:space:]]*" k "=" { if (!done) { print k "=" v; done=1 } ; next }
      { print }' "$SITE_CONF" > "$tmp"
  else
    cat "$SITE_CONF" > "$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
  fi
  install -m 644 "$tmp" "$SITE_CONF"
  rm -f "$tmp"
}

# --- detection ---------------------------------------------------------------
is_wifi() { [[ -d "$SYSFS/class/net/$1/wireless" || -e "$SYSFS/class/net/$1/phy80211" ]]; }

iface_bus() {  # usb | sdio | pci | platform | unknown
  local sub
  sub=$(readlink -f "$SYSFS/class/net/$1/device/subsystem" 2>/dev/null) || true
  [[ -n "$sub" ]] && basename "$sub" || echo unknown
}

# Built-in Pi radios sit on SDIO (Pi 4/5) — everything else is an add-on adapter.
is_builtin() { case "$(iface_bus "$1")" in sdio|platform|mmc) return 0 ;; *) return 1 ;; esac; }

ap_capable() {
  local phy
  phy=$(cat "$SYSFS/class/net/$1/phy80211/name" 2>/dev/null) || return 1
  [[ -n "$phy" ]] || return 1
  "$IW" phy "$phy" info 2>/dev/null | awk '
    /Supported interface modes:/ { inblk=1; next }
    inblk && /^[[:space:]]+\* /  { if ($2 == "AP") ok=1; next }
    inblk                        { inblk=0 }
    END { exit !ok }'
}

detect() {
  local n name wifi=() eth=""
  for n in "$SYSFS"/class/net/*; do
    name=$(basename "$n")
    [[ "$name" == "lo" ]] && continue
    if is_wifi "$name"; then
      wifi+=("$name")
    elif [[ -e "$n/device" && "$(cat "$n/type" 2>/dev/null)" == "1" && "$name" =~ ^(eth|en) ]]; then
      [[ -z "$eth" ]] && eth="$name"
    fi
  done

  local ext_ap="" builtin_ap="" w
  for w in "${wifi[@]:-}"; do
    [[ -z "$w" ]] && continue
    if ap_capable "$w"; then
      if is_builtin "$w"; then [[ -z "$builtin_ap" ]] && builtin_ap="$w"
      else                     [[ -z "$ext_ap" ]]     && ext_ap="$w"; fi
    fi
  done

  local ap="" wan=""
  if   [[ -n "$builtin_ap" ]]; then ap="$builtin_ap"
  elif [[ -n "$ext_ap" ]];     then ap="$ext_ap"
  fi
  # WiFi-WAN = the first other radio.
  for w in "${wifi[@]:-}"; do
    [[ -z "$w" || "$w" == "$ap" ]] && continue
    [[ -z "$wan" ]] && wan="$w"
  done

  D_ETH="$eth"; D_AP="$ap"; D_WIFI_WAN="$wan"; D_WIFI_COUNT=0
  for w in "${wifi[@]:-}"; do [[ -n "$w" ]] && D_WIFI_COUNT=$((D_WIFI_COUNT+1)); done
}

# --- rendering ---------------------------------------------------------------
write_if_changed() {  # path mode  (content on stdin) -> returns 0 if file changed
  local path="$1" mode="$2" tmp
  tmp=$(mktemp); cat > "$tmp"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then rm -f "$tmp"; return 1; fi
  install -D -m "$mode" "$tmp" "$path"; rm -f "$tmp"; return 0
}

render_networkd() {
  local bridge="$1" gw="$2" net="$3" eth="$4" wan="$5" prefix changed=1
  prefix="${net#*/}"; [[ "$prefix" == "$net" ]] && prefix=24

  write_if_changed "$NETD_DIR/20-privacypi-lan.netdev" 644 <<EOF && changed=0
# Rendered by net-roles.sh — the bridge PrivacyPi WiFi clients land on.
[NetDev]
Name=$bridge
Kind=bridge

[Bridge]
STP=no
ForwardDelaySec=0
EOF
  write_if_changed "$NETD_DIR/20-privacypi-lan.network" 644 <<EOF && changed=0
# Rendered by net-roles.sh
[Match]
Name=$bridge

[Network]
Address=$gw/$prefix
ConfigureWithoutCarrier=yes
LinkLocalAddressing=no
IPv6AcceptRA=no

[Link]
RequiredForOnline=no
EOF
  if [[ -n "$eth" ]]; then
    write_if_changed "$NETD_DIR/20-privacypi-eth.network" 644 <<EOF && changed=0
# Rendered by net-roles.sh — wired uplink. Preferred WAN (lowest metric).
[Match]
Name=$eth

[Network]
DHCP=ipv4
IPv6AcceptRA=no

[DHCPv4]
RouteMetric=50
# PrivacyPi forces DNS to itself — never accept the upstream's DNS servers.
UseDNS=false
# Don't announce a hostname to the upstream network.
SendHostname=no

[Link]
RequiredForOnline=routable
EOF
  fi
  if [[ -n "$wan" ]]; then
    write_if_changed "$NETD_DIR/30-privacypi-wifi-wan.network" 644 <<EOF && changed=0
# Rendered by net-roles.sh — DHCP on the spare radio when it is the WAN uplink.
# Inert until wan-config.sh starts wpa_supplicant@$wan and the radio associates.
[Match]
Name=$wan

[Network]
DHCP=ipv4
IPv6AcceptRA=no

[DHCPv4]
RouteMetric=100
UseDNS=false
SendHostname=no

[Link]
RequiredForOnline=routable
EOF
  elif [[ -f "$NETD_DIR/30-privacypi-wifi-wan.network" ]]; then
    rm -f "$NETD_DIR/30-privacypi-wifi-wan.network"; changed=0
  fi
  rm -f "$NETD_DIR/30-wlan0-wan.network"   # pre-roles name
  return $changed
}

render_hostapd() {  # keep interface=/bridge= in step with the roles
  local ap="$1" bridge="$2"
  [[ -f "$HOSTAPD_CONF" && -n "$ap" ]] || return 1
  local cur_if cur_br
  cur_if=$(awk -F= '/^interface=/{print $2; exit}' "$HOSTAPD_CONF")
  cur_br=$(awk -F= '/^bridge=/{print $2; exit}' "$HOSTAPD_CONF")
  [[ "$cur_if" == "$ap" && "$cur_br" == "$bridge" ]] && return 1
  sed -i -e "s|^interface=.*|interface=$ap|" -e "s|^bridge=.*|bridge=$bridge|" "$HOSTAPD_CONF"
  grep -q '^bridge=' "$HOSTAPD_CONF" || echo "bridge=$bridge" >> "$HOSTAPD_CONF"
  return 0
}

# --- main --------------------------------------------------------------------
detect
# At boot the built-in radio can show up a few seconds after this runs (its
# firmware loads asynchronously). NET_ROLES_WAIT=<seconds> waits for a radio,
# then gives a second (USB) one a moment to appear too.
if [[ "${NET_ROLES_WAIT:-0}" -gt 0 && "$D_WIFI_COUNT" -eq 0 ]]; then
  for ((i = 0; i < NET_ROLES_WAIT * 2 && D_WIFI_COUNT == 0; i++)); do sleep 0.5; detect; done
  if (( D_WIFI_COUNT > 0 )); then sleep 2; detect; fi
fi

if [[ "$ACTION" == "detect" ]]; then
  printf 'ETH_IFACE=%s\nAP_IFACE=%s\nWIFI_WAN_IFACE=%s\nWIFI_RADIOS=%s\n' \
    "$D_ETH" "$D_AP" "$D_WIFI_WAN" "$D_WIFI_COUNT"
  exit 0
fi
[[ "$ACTION" == "apply" ]] || { echo "usage: net-roles.sh [apply|detect]" >&2; exit 2; }
[[ -f "$SITE_CONF" ]] || { log "$SITE_CONF missing — run install.sh first"; exit 1; }

OLD_ETH=$(conf_get ETH_IFACE); OLD_AP=$(conf_get AP_IFACE); OLD_WAN=$(conf_get WIFI_WAN_IFACE)
MODE=$(conf_get WAN_MODE); MODE=${MODE:-ethernet}
BRIDGE=$(conf_get LAN_BRIDGE); BRIDGE=${BRIDGE:-br-vlan10}
LAN_GW=$(conf_get LAN_GW);     LAN_GW=${LAN_GW:-10.10.10.1}
LAN_NET=$(conf_get LAN_NET);   LAN_NET=${LAN_NET:-10.10.10.0/24}

if [[ "$(conf_get ROLE_LOCK)" == "1" ]]; then
  log "ROLE_LOCK=1 — keeping configured roles"
  ETH="$OLD_ETH"; AP="$OLD_AP"; WAN="$OLD_WAN"
else
  ETH="${D_ETH:-${OLD_ETH:-eth0}}"   # no wired port seen: keep the name so a later plug-in works
  AP="$D_AP"; WAN="$D_WIFI_WAN"
  [[ -z "$AP" ]] && log "WARNING: no AP-capable WiFi radio found — the PrivacyPi WiFi cannot start"
fi

# WiFi-WAN was active but its radio moved or vanished
if [[ "$MODE" == "wifi" && "$WAN" != "$OLD_WAN" ]]; then
  [[ -n "$OLD_WAN" ]] && systemctl disable "wpa_supplicant@${OLD_WAN}.service" >/dev/null 2>&1
  if [[ -n "$WAN" && -f "$WPA_DIR/wpa_supplicant-${OLD_WAN}.conf" ]]; then
    mv -f "$WPA_DIR/wpa_supplicant-${OLD_WAN}.conf" "$WPA_DIR/wpa_supplicant-${WAN}.conf"
    systemctl enable "wpa_supplicant@${WAN}.service" >/dev/null 2>&1
    # "enable" alone does not add the unit to a boot that is already under way.
    systemctl start --no-block "wpa_supplicant@${WAN}.service" >/dev/null 2>&1
    log "WiFi-WAN radio renamed $OLD_WAN -> $WAN"
  else
    MODE=ethernet
    conf_set WAN_MODE ethernet; conf_set WAN_WIFI_SSID ""
    log "WiFi-WAN radio gone — falling back to ethernet WAN"
  fi
fi

if [[ "$ETH" != "$OLD_ETH" || "$AP" != "$OLD_AP" || "$WAN" != "$OLD_WAN" ]]; then
  conf_set ETH_IFACE "$ETH"; conf_set AP_IFACE "$AP"; conf_set WIFI_WAN_IFACE "$WAN"
  log "roles: eth=$ETH ap=${AP:-none} wifi-wan=${WAN:-none} (was eth=$OLD_ETH ap=$OLD_AP wifi-wan=$OLD_WAN)"
else
  log "roles unchanged: eth=$ETH ap=${AP:-none} wifi-wan=${WAN:-none}"
fi
# Effective uplink always follows WAN_MODE.
if [[ "$MODE" == "wifi" ]]; then WANT_WAN_IFACE="$WAN"; else WANT_WAN_IFACE="$ETH"; fi
[[ "$(conf_get WAN_IFACE)" == "$WANT_WAN_IFACE" ]] || conf_set WAN_IFACE "$WANT_WAN_IFACE"

command -v rfkill >/dev/null 2>&1 && rfkill unblock wifi 2>/dev/null

netd_changed=false; hostapd_changed=false
render_networkd "$BRIDGE" "$LAN_GW" "$LAN_NET" "$ETH" "$WAN" && netd_changed=true
render_hostapd "$AP" "$BRIDGE" && hostapd_changed=true

# When run on a live system (not early boot), nudge the daemons.
if [[ "${NET_ROLES_NO_RELOAD:-0}" != "1" ]]; then
  $netd_changed    && systemctl is-active --quiet systemd-networkd && networkctl reload 2>/dev/null
  $hostapd_changed && systemctl is-active --quiet hostapd && systemctl restart hostapd 2>/dev/null
fi
exit 0
