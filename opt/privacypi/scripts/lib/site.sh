# Sourced by every privileged script that needs site config.
# Loads /etc/privacypi/site.conf with sensible defaults if missing.
# This is the single source of truth for host-specific facts (interfaces,
# subnets, ports). Nothing under opt/privacypi/scripts/ should hardcode them.
SITE_CONF=${SITE_CONF:-/etc/privacypi/site.conf}
[[ -r "$SITE_CONF" ]] && source "$SITE_CONF"

# --- WAN (uplink to the internet) -------------------------------------------
# WAN_MODE selects how the Pi reaches the internet:
#   ethernet -> ETH_IFACE (wired)
#   wifi     -> WIFI_WAN_IFACE (built-in radio as a station/client)
: "${WAN_MODE:=ethernet}"
: "${ETH_IFACE:=eth0}"
: "${WIFI_WAN_IFACE:=wlan0}"
# WAN_IFACE is the *effective* uplink interface. An explicit value in
# site.conf wins; otherwise it is derived from WAN_MODE.
if [[ -z "${WAN_IFACE:-}" ]]; then
  if [[ "$WAN_MODE" == "wifi" ]]; then WAN_IFACE="$WIFI_WAN_IFACE"; else WAN_IFACE="$ETH_IFACE"; fi
fi
: "${WAN_WIFI_SSID:=}"   # upstream SSID when WAN_MODE=wifi (non-secret; PSK lives in wpa_supplicant)

# --- LAN (the AP that client devices join) ----------------------------------
: "${AP_IFACE:=wlan1}"
: "${LAN_BRIDGE:=br-vlan10}"
: "${LAN_NET:=10.10.10.0/24}"
: "${LAN_GW:=10.10.10.1}"

# --- WireGuard travel server ------------------------------------------------
: "${WG_NET:=10.20.0.0/24}"
: "${WG_GW:=10.20.0.1}"
: "${WG_PORT:=51820}"

# --- Identity / reachability ------------------------------------------------
: "${HOST_MDNS:=privacypi.local}"
: "${HOST_IP:=$(ip -4 addr show "$WAN_IFACE" 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)}"
# Loopback address of the Flask app behind Caddy (internal alert callbacks etc).
: "${FLASK_INTERNAL:=127.0.0.1:8443}"

# --- Tor --------------------------------------------------------------------
: "${TOR_TRANS_PORT:=9040}"
: "${TOR_DNS_PORT:=5353}"
: "${TOR_CONTROL_PORT:=9051}"
: "${TOR_SOCKS_PORT:=9050}"

# --- DNS leak control -------------------------------------------------------
: "${DOH_BYPASS_IPS:=1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 9.9.9.9 149.112.112.112 208.67.222.222 208.67.220.220 94.140.14.14 94.140.15.15}"

export WAN_MODE ETH_IFACE WIFI_WAN_IFACE WAN_IFACE WAN_WIFI_SSID \
       AP_IFACE LAN_BRIDGE LAN_NET LAN_GW WG_NET WG_GW WG_PORT \
       HOST_MDNS HOST_IP FLASK_INTERNAL \
       TOR_TRANS_PORT TOR_DNS_PORT TOR_CONTROL_PORT TOR_SOCKS_PORT DOH_BYPASS_IPS
