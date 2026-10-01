#!/usr/bin/env bash
# Simulated-hardware test for net-roles.sh (fake sysfs + fake iw). Run in a Linux container:
#   docker run --rm -v "$PWD":/repo:ro debian:trixie-slim bash -c \
#     "mkdir -p /opt/privacypi && cp -r /repo/opt/privacypi/scripts /opt/privacypi/ && bash /repo/tests/test-net-roles.sh"
S=/opt/privacypi/scripts/net-roles.sh
mk() { # name bus wifi(0/1) apcap(0/1)
  local n=$1 bus=$2 wifi=$3 ap=$4 d=$T/sys/class/net/$1
  mkdir -p $d $T/sys/bus/$bus $T/sys/devices/$n
  ln -s $T/sys/bus/$bus $T/sys/devices/$n/subsystem
  ln -s $T/sys/devices/$n $d/device
  echo 1 > $d/type
  if [[ $wifi == 1 ]]; then mkdir -p $d/wireless $d/phy80211; echo phy_$n > $d/phy80211/name; echo $ap > $T/iw_phy_$n; fi
}
setup() {
  T=$(mktemp -d); export SYSFS=$T/sys SITE_CONF=$T/site.conf NETD_DIR=$T/netd HOSTAPD_CONF=$T/hostapd.conf WPA_DIR=$T/wpa NET_ROLES_NO_RELOAD=1
  mkdir -p $T/sys/class/net/lo $T/netd $T/wpa $T/sys/class/net/br-vlan10
  echo 772 > $T/sys/class/net/lo/type; echo 1 > $T/sys/class/net/br-vlan10/type
  cp /repo/system/etc/privacypi/site.conf.example $SITE_CONF
  printf 'interface=wlan9\nbridge=x\nssid=PrivacyPi\n' > $HOSTAPD_CONF
  cat > $T/iw <<IW
#!/bin/bash
# iw phy <phy> info
ap=\$(cat $T/iw_\$2)
printf 'Wiphy %s\n\tSupported interface modes:\n\t\t * IBSS\n\t\t * managed\n' "\$2"
[[ \$ap == 1 ]] && printf '\t\t * AP\n\t\t * AP/VLAN\n'
printf '\t\t * monitor\n\tBand 1:\n\t\t * AP is not a mode line\n'
IW
  chmod +x $T/iw; export IW=$T/iw
}
show() { echo "  -> $(grep -E '^(WAN_MODE|ETH_IFACE|AP_IFACE|WIFI_WAN_IFACE|WAN_IFACE)=' $SITE_CONF | tr '\n' ' ') | hostapd:$(grep -E '^(interface|bridge)=' $HOSTAPD_CONF | tr '\n' ' ') | netd:$(ls $NETD_DIR | tr '\n' ' ')"; }
check() { local want="$1" got; got="$(grep -E '^AP_IFACE=' $SITE_CONF | cut -d= -f2)/$(grep -E '^WIFI_WAN_IFACE=' $SITE_CONF | cut -d= -f2 | sed 's/ *#.*//')/$(grep -E '^WAN_IFACE=' $SITE_CONF | cut -d= -f2)/$(grep -E '^WAN_MODE=' $SITE_CONF | cut -d= -f2)"; [[ "$got" == "$want" ]] && echo "  PASS ($got)" || { echo "  FAIL want=$want got=$got"; FAILS=$((FAILS+1)); }; }
FAILS=0

echo "A: Pi only (eth0 + built-in wlan0)"; setup; mk eth0 platform 0 0; mk wlan0 sdio 1 1; $S apply; show; check "wlan0//eth0/ethernet"
echo "B: + USB adapter with AP mode (built-in stays the AP)"; mk wlan1 usb 1 1; $S apply; show; check "wlan0/wlan1/eth0/ethernet"
echo "B2: idempotent re-run"; $S apply; check "wlan0/wlan1/eth0/ethernet"
echo "C: USB adapter WITHOUT AP mode"; setup; mk eth0 platform 0 0; mk wlan0 sdio 1 1; mk wlan1 usb 1 0; $S apply; show; check "wlan0/wlan1/eth0/ethernet"
echo "D: names swapped (wlan0=USB AP-capable, wlan1=built-in)"; setup; mk eth0 platform 0 0; mk wlan0 usb 1 1; mk wlan1 sdio 1 1; $S apply; show; check "wlan1/wlan0/eth0/ethernet"
echo "E: no WiFi radio, no ethernet"; setup; $S apply; show; check "//eth0/ethernet"
echo "F: WiFi-WAN active on the USB radio, then names swap -> conf follows"; setup; mk eth0 platform 0 0; mk wlan0 sdio 1 1; mk wlan1 usb 1 1; $S apply >/dev/null
  sed -i 's/^WAN_MODE=.*/WAN_MODE=wifi/' $SITE_CONF; echo psk > $WPA_DIR/wpa_supplicant-wlan1.conf; $S apply; check "wlan0/wlan1/wlan1/wifi"
  rm -rf $T/sys/class/net/wlan0 $T/sys/class/net/wlan1 $T/sys/devices/wlan0 $T/sys/devices/wlan1; mk wlan0 usb 1 1; mk wlan1 sdio 1 1; $S apply; show; check "wlan1/wlan0/wlan0/wifi"; ls $WPA_DIR
echo "G: WiFi-WAN active, USB adapter unplugged -> fall back to ethernet"; rm -rf $T/sys/class/net/wlan0; $S apply; show; check "wlan1//eth0/ethernet"
echo "G2: only an external AP-capable radio -> it takes the AP role"; setup; mk eth0 platform 0 0; mk wlan0 usb 1 1; $S apply; check "wlan0//eth0/ethernet"
echo "H: ROLE_LOCK=1 keeps roles"; setup; mk eth0 platform 0 0; mk wlan0 sdio 1 1; mk wlan1 usb 1 1; sed -i 's/^ROLE_LOCK=.*/ROLE_LOCK=1/; s/^AP_IFACE=.*/AP_IFACE=wlan0/; s/^WIFI_WAN_IFACE=.*/WIFI_WAN_IFACE=wlan1/' $SITE_CONF; $S apply; check "wlan0/wlan1/eth0/ethernet"
echo "detect:"; $S detect
echo "--- rendered lan.network:"; cat $NETD_DIR/20-privacypi-lan.network
echo "--- site.sh sources cleanly:"; bash -c "set -u; SITE_CONF=$SITE_CONF; source /opt/privacypi/scripts/lib/site.sh; echo AP=\$AP_IFACE WAN=\$WAN_IFACE WIFIWAN=[\$WIFI_WAN_IFACE] CC=\$WIFI_COUNTRY"
echo "FAILS=$FAILS"; exit $FAILS
