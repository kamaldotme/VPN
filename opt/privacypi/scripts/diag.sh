#!/usr/bin/env bash
# diag.sh — write a plain-text health report to the SD card's boot partition
# (privacypi-status.txt). On a headless device this is how you find out what
# went wrong: power off, put the card in a computer, open the file.
# Contains no passwords or keys.
set -uo pipefail
source /opt/privacypi/scripts/lib/site.sh 2>/dev/null || true
BOOT=/boot/firmware; [[ -d "$BOOT" ]] || BOOT=/boot
OUT="$BOOT/privacypi-status.txt"
TMP=$(mktemp)
sec() { printf '\n===== %s =====\n' "$1"; }
{
  echo "PrivacyPi status report"
  echo "generated: $(date -Iseconds)   uptime: $(cut -d. -f1 /proc/uptime)s"
  echo "version:   $(cat /opt/privacypi/VERSION 2>/dev/null || echo unknown)"
  echo "model:     $(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo unknown)"
  echo "kernel:    $(uname -r)"
  echo "setup:     $([[ -f /etc/privacypi/setup-complete ]] && echo complete || echo PENDING — join WiFi \"${AP_SSID:-PrivacyPi-Setup}\")"
  sec "roles (site.conf)"
  grep -E '^(WAN_MODE|WAN_IFACE|ETH_IFACE|AP_IFACE|WIFI_WAN_IFACE|WIFI_COUNTRY|AP_CHANNEL|AP_SSID|ROLE_LOCK|ADMIN_ON_WAN)=' /etc/privacypi/site.conf 2>/dev/null
  sec "services"
  for s in privacypi-net-roles privacypi-init systemd-networkd hostapd dnsmasq unbound AdGuardHome tor@default \
           privacypi-firewall privacypi-vpn-up privacypi-setup-mode privacypi-setup-dns caddy privacypi-flask \
           privacypi-wan-watch privacypi-openvpn chrony ssh NetworkManager wpa_supplicant; do
    printf '%-26s %-10s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null)" "$(systemctl is-enabled "$s" 2>/dev/null)"
  done
  sec "failed units"; systemctl --failed --no-legend --plain 2>/dev/null
  sec "interfaces"; ip -br addr 2>/dev/null
  sec "routes"; ip -4 route 2>/dev/null; echo "-- table 100"; ip -4 route show table 100 2>/dev/null
  sec "wifi devices"; iw dev 2>/dev/null
  sec "wifi radios (bus / AP support)"
  for d in /sys/class/net/*/phy80211; do
    [[ -e "$d" ]] || continue
    i=$(basename "$(dirname "$d")"); phy=$(cat "$d/name")
    bus=$(basename "$(readlink -f "/sys/class/net/$i/device/subsystem" 2>/dev/null)" 2>/dev/null)
    drv=$(basename "$(readlink -f "/sys/class/net/$i/device/driver" 2>/dev/null)" 2>/dev/null)
    ap=no; iw phy "$phy" info 2>/dev/null | grep -qE '^\s+\* AP$' && ap=yes
    echo "$i phy=$phy bus=$bus driver=$drv ap_mode=$ap"
  done
  sec "rfkill"; rfkill list 2>/dev/null
  sec "usb"; lsusb 2>/dev/null
  sec "hostapd.conf (password hidden)"; sed 's/^wpa_passphrase=.*/wpa_passphrase=<hidden>/' /etc/hostapd/hostapd.conf 2>/dev/null
  sec "listening"; ss -lntup 2>/dev/null | awk '{print $1, $5, $7}' | column -t 2>/dev/null
  sec "time"; date -u; chronyc -n tracking 2>/dev/null | grep -E 'Leap status|System time|Reference ID'
  sec "firewall (filter)"; iptables -S 2>/dev/null | head -60
  sec "firewall (nat)"; iptables -t nat -S 2>/dev/null | head -40
  for u in privacypi-net-roles privacypi-init hostapd dnsmasq AdGuardHome unbound caddy privacypi-flask privacypi-firewall privacypi-vpn-up privacypi-openvpn; do
    sec "journal: $u (last 15)"; journalctl -b -u "$u" --no-pager -n 15 -o cat 2>/dev/null
  done
  sec "journal: errors this boot (last 40)"; journalctl -b -p err --no-pager -n 40 -o short-monotonic 2>/dev/null
} > "$TMP" 2>&1
# Never leak secrets even if a log line contains one.
sed -i -E 's/(passphrase|password|psk|secret|PrivateKey)([=: ]+)[^ ]+/\1\2<hidden>/Ig' "$TMP"
if cp "$TMP" "$OUT" 2>/dev/null; then sync; echo "wrote $OUT"; else cp "$TMP" /var/log/privacypi/status.txt 2>/dev/null; echo "boot partition not writable — wrote /var/log/privacypi/status.txt"; fi
rm -f "$TMP"
