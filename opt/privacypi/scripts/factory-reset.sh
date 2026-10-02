#!/usr/bin/env bash
# factory-reset.sh — return the device to its out-of-box state: all settings,
# accounts, VPN credentials and WiFi names are wiped, the setup network
# (PrivacyPi-Setup) and the wizard come back on the next boot.
#
# Triggered from the dashboard (System → Factory reset) or, when locked out,
# by putting  reset=yes  in privacypi-config.txt on the SD card's boot partition.
set -uo pipefail
ETC=/etc/privacypi
PREFIX=/opt/privacypi

systemctl stop privacypi-flask privacypi-openvpn wg-quick@wg0 wg-quick@wg-srv AdGuardHome 2>/dev/null || true

rm -f /var/lib/privacypi/privacypi.db* /var/lib/privacypi/active-vpn
rm -rf /var/lib/privacypi/* /var/log/privacypi/* 2>/dev/null || true
rm -f "$ETC/setup-complete" "$ETC/.provisioned" "$ETC/wifi-psk.txt" "$ETC/adguard.creds" "$ETC/adguard.cred" \
      "$ETC/master.key" "$ETC/secret.key" "$ETC/secret.env" "$ETC/alert.secret" "$ETC/last-mode"
rm -rf "$ETC/vpn"
rm -f /opt/AdGuardHome/AdGuardHome.yaml
rm -rf /opt/AdGuardHome/data
rm -f /etc/wpa_supplicant/wpa_supplicant-*.conf /etc/wireguard/*.conf
rm -f /etc/unbound/unbound.conf.d/privacypi-forward.conf
for u in /etc/systemd/system/multi-user.target.wants/wpa_supplicant@*.service \
         /etc/systemd/system/multi-user.target.wants/wg-quick@*.service; do
  [[ -e "$u" ]] && rm -f "$u"
done
[[ -f "$PREFIX/system/etc/tor/torrc" ]] && install -m 644 "$PREFIX/system/etc/tor/torrc" /etc/tor/torrc
install -m 644 -o root -g root "$PREFIX/system/etc/privacypi/site.conf.example" "$ETC/site.conf"
echo "factory reset complete at $(date -Iseconds)"

if [[ "${1:-}" == "--reboot" ]]; then
  systemd-run --quiet --collect --on-active=3 systemctl reboot >/dev/null 2>&1 || (sleep 3; reboot) &
fi
