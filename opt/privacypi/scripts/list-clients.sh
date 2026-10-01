#!/usr/bin/env bash
# Print JSON list of clients on PrivacyPi (DHCP leases + ARP + bandwidth).
# No args. Outputs one JSON object.
set -uo pipefail

LEASES=/var/lib/misc/dnsmasq.leases
[[ -f /var/lib/dhcp/dhcpd.leases ]] && LEASES=/var/lib/dhcp/dhcpd.leases

OUI_DB="/var/lib/privacypi/oui.txt"
# Helper: lookup vendor by MAC OUI prefix
lookup_vendor() {
  local mac="$1"
  local prefix="${mac:0:8}"
  local prefix_upper="${prefix^^}"
  if [[ -f "$OUI_DB" ]]; then
    grep -i "^${prefix_upper//:/}" "$OUI_DB" 2>/dev/null | head -1 | awk -F'\t' '{print $3}' | sed 's/"//g'
  fi
}

# Get device-route assignments (per-MAC iptables ipset)
declare -A ROUTE_OVERRIDE
if ipset list privacypi-tor 2>/dev/null | grep -E "^([0-9A-Fa-f]{2}:){5}" >/dev/null; then
  while read -r m; do ROUTE_OVERRIDE["$m"]="tor"; done < <(ipset list privacypi-tor 2>/dev/null | grep -E "^([0-9A-Fa-f]{2}:){5}")
fi
if ipset list privacypi-direct 2>/dev/null | grep -E "^([0-9A-Fa-f]{2}:){5}" >/dev/null; then
  while read -r m; do ROUTE_OVERRIDE["$m"]="direct"; done < <(ipset list privacypi-direct 2>/dev/null | grep -E "^([0-9A-Fa-f]{2}:){5}")
fi

# Build list from DHCP leases (most authoritative)
echo "{"
echo "  \"timestamp\": \"$(date -Iseconds)\","
echo "  \"clients\": ["

first=1
if [[ -f "$LEASES" ]]; then
  while read -r expire mac ip name client_id; do
    [[ -z "$mac" ]] && continue
    expire_iso=$(date -Iseconds -d "@$expire" 2>/dev/null || echo "")
    vendor=$(lookup_vendor "$mac")
    override="${ROUTE_OVERRIDE[$mac]:-none}"
    # Liveness via ARP
    last_seen=""
    arp_state=$(ip neigh show "$ip" 2>/dev/null | awk '{print $NF}')
    [[ -z "$arp_state" ]] && arp_state="UNKNOWN"
    # Render JSON
    [[ $first -eq 0 ]] && echo ","
    first=0
    cat <<JSON
    {
      "mac": "${mac,,}",
      "ip": "$ip",
      "name": "${name:-unknown}",
      "vendor": "${vendor:-unknown}",
      "lease_expires": "$expire_iso",
      "arp_state": "$arp_state",
      "route_override": "$override"
    }
JSON
  done < "$LEASES"
fi

echo "  ]"
echo "}"
