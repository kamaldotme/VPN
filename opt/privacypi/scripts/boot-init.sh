#!/usr/bin/env bash
# boot-init.sh — runs early on every boot (privacypi-init.service), after
# net-roles.sh and before the AP, DNS and dashboard start.
#   1. Applies privacypi-config.txt from the SD card's boot partition
#      (factory reset / developer SSH / dashboard-on-WAN) — the only way to
#      reach a headless device you are locked out of.
#   2. Provisions per-device secrets on first boot (or after a reset).
#   3. Renders the WiFi config for the radio chosen by net-roles.sh.
set -uo pipefail
SCRIPTS=/opt/privacypi/scripts
BOOT=/boot/firmware; [[ -d "$BOOT" ]] || BOOT=/boot
CFG="$BOOT/privacypi-config.txt"
log() { echo "boot-init: $*"; }

cfg_get() { [[ -r "$CFG" ]] && sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CFG" | tr -d '\r' | head -n1; }
cfg_done() {  # comment a one-shot option out so it does not repeat (and a password does not linger)
  sed -i "s|^[[:space:]]*$1[[:space:]]*=.*|# $1 applied $(date -Iseconds)|" "$CFG" 2>/dev/null || true
}

if [[ -r "$CFG" ]]; then
  case "$(cfg_get reset | tr 'A-Z' 'a-z')" in
    yes|true|1) log "factory reset requested via $CFG"; "$SCRIPTS/factory-reset.sh"; cfg_done reset ;;
  esac
fi

[[ -f /etc/privacypi/site.conf ]] || install -m 644 /opt/privacypi/system/etc/privacypi/site.conf.example /etc/privacypi/site.conf
# A reset rewrote site.conf — re-detect the radios before rendering anything.
NET_ROLES_NO_RELOAD=1 NET_ROLES_WAIT="${NET_ROLES_WAIT:-15}" "$SCRIPTS/net-roles.sh" apply || true

if [[ -r "$CFG" ]]; then
  source "$SCRIPTS/lib/site.sh"
  case "$(cfg_get admin_on_wan | tr 'A-Z' 'a-z')" in
    yes|true|1) site_conf_set ADMIN_ON_WAN 1 ;;
    no|false|0) site_conf_set ADMIN_ON_WAN 0 ;;
  esac
  # Developer access: ssh_password=<password> enables SSH for user "pi".
  pw=$(cfg_get ssh_password)
  if [[ -n "$pw" ]]; then
    if id pi >/dev/null 2>&1; then
      usermod -s /bin/bash pi 2>/dev/null
      usermod -aG sudo pi 2>/dev/null
      echo "pi:$pw" | chpasswd && log "SSH enabled for user pi"
      echo 'pi ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/010_pi-nopasswd; chmod 440 /etc/sudoers.d/010_pi-nopasswd
      rm -f /etc/ssh/sshd_config.d/rename_user.conf
      systemctl enable ssh.service >/dev/null 2>&1
      systemctl start --no-block ssh.service >/dev/null 2>&1
    fi
    cfg_done ssh_password
  fi
fi

# Home WiFi preset: wifi_ssid= / wifi_password= (optional wifi_country=XX) make
# the Pi join an upstream WiFi without the wizard — for devices with no cable.
if [[ -r "$CFG" ]]; then
  ssid=$(cfg_get wifi_ssid); wpw=$(cfg_get wifi_password); wcc=$(cfg_get wifi_country | tr 'a-z' 'A-Z')
  if [[ -n "$ssid" && ${#wpw} -ge 8 ]]; then
    source "$SCRIPTS/lib/site.sh"
    [[ "$wcc" =~ ^[A-Z]{2}$ ]] && { site_conf_set WIFI_COUNTRY "$wcc"; WIFI_COUNTRY="$wcc"; }
    if [[ -n "$WIFI_WAN_IFACE" ]]; then
      install -d -m 755 /etc/wpa_supplicant
      wconf="/etc/wpa_supplicant/wpa_supplicant-${WIFI_WAN_IFACE}.conf"
      {
        echo "ctrl_interface=/run/wpa_supplicant"
        echo "ctrl_interface_group=0"
        echo "update_config=1"
        echo "country=$WIFI_COUNTRY"
        echo ""
        wpa_passphrase "$ssid" "$wpw" | grep -vE '^\s*#psk='
      } > "$wconf" 2>/dev/null
      chmod 600 "$wconf"
      site_conf_set WAN_MODE wifi
      site_conf_set WAN_IFACE "$WIFI_WAN_IFACE"
      site_conf_set WAN_WIFI_SSID "\"$ssid\""
      NET_ROLES_NO_RELOAD=1 "$SCRIPTS/net-roles.sh" apply || true
      log "home WiFi preset applied on $WIFI_WAN_IFACE"
      cfg_done wifi_password
    else
      log "wifi_ssid is set but there is no spare WiFi radio — plug in a USB WiFi adapter"
    fi
  fi
fi
# WiFi-WAN: make sure the client is part of THIS boot (the unit may have been
# enabled after systemd planned the boot, or the radio's name may have changed).
wan_mode=$(sed -n 's/^WAN_MODE=//p' /etc/privacypi/site.conf | head -n1)
wan_if=$(sed -n 's/^WIFI_WAN_IFACE=\([A-Za-z0-9]*\).*/\1/p' /etc/privacypi/site.conf | head -n1)
if [[ "$wan_mode" == wifi* && -n "$wan_if" && -f "/etc/wpa_supplicant/wpa_supplicant-${wan_if}.conf" ]]; then
  systemctl enable "wpa_supplicant@${wan_if}.service" >/dev/null 2>&1
  systemctl start --no-block "wpa_supplicant@${wan_if}.service" >/dev/null 2>&1
fi

"$SCRIPTS/provision.sh" || log "provision reported errors"
exit 0
