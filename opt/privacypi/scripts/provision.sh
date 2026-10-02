#!/usr/bin/env bash
# provision.sh — per-device, one-time provisioning. Everything that must be
# UNIQUE to a device is generated here, never baked into the image:
# app secrets, the vault master key, the AdGuard admin password.
# Idempotent: existing files are kept. Run by boot-init.sh on first boot (image)
# and by install.sh (developer install).
set -uo pipefail
source /opt/privacypi/scripts/lib/site.sh

ETC=/etc/privacypi
PREFIX=/opt/privacypi
PY="$PREFIX/venv/bin/python"
log() { echo "provision: $*"; }

gen_secret() {  # path generator-command
  local path="$1" gen="$2"
  [[ -s "$path" ]] && return 0
  local tmp; tmp=$(mktemp)
  if eval "$gen" > "$tmp" && [[ -s "$tmp" ]]; then
    install -m 640 -o root -g privacypi "$tmp" "$path"
  else
    log "ERROR: could not generate $path"
  fi
  rm -f "$tmp"
}

install -d -m 750 -o root -g privacypi "$ETC"
install -d -m 750 -o privacypi -g privacypi /var/lib/privacypi /var/log/privacypi
install -d -m 755 /etc/iptables

gen_secret "$ETC/master.key"   "$PY -c 'from cryptography.fernet import Fernet; import sys; sys.stdout.buffer.write(Fernet.generate_key())'"
gen_secret "$ETC/alert.secret" "head -c 48 /dev/urandom | base64 | tr -d '\n'"
gen_secret "$ETC/secret.key"   "head -c 64 /dev/urandom | base64 | tr -d '\n'"
if [[ ! -s "$ETC/secret.env" ]]; then
  printf 'PRIVACYPI_SECRET_KEY=%s\n' "$(cat "$ETC/secret.key")" > "$ETC/secret.env"
  chmod 640 "$ETC/secret.env"; chown root:privacypi "$ETC/secret.env"
fi

# Out-of-box WiFi password for the setup network (public, documented in the
# README). The wizard replaces it.
if [[ ! -s "$ETC/wifi-psk.txt" ]]; then
  echo "privacypi" > "$ETC/wifi-psk.txt"
  chmod 640 "$ETC/wifi-psk.txt"; chown root:privacypi "$ETC/wifi-psk.txt"
fi

# VPN provider slots used by the dashboard
for p in nordvpn expressvpn mullvad protonvpn ivpn surfshark airvpn custom-ovpn custom-wg; do
  install -d -m 750 -o root -g privacypi "$ETC/vpn/$p" "$ETC/vpn/$p/servers"
done

# AdGuard Home: seed a config with a random admin password (hash only on disk
# in the yaml; the plaintext is kept root-readable for the dashboard/support).
AGH=/opt/AdGuardHome
if [[ -x "$AGH/AdGuardHome" && ! -s "$AGH/AdGuardHome.yaml" ]]; then
  pw=$(head -c 12 /dev/urandom | base64 | tr -d '/+=' | head -c 14)
  hash=$("$PY" -c 'import bcrypt,sys; print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(10)).decode())' "$pw" 2>/dev/null)
  if [[ -n "$hash" ]]; then
    sed -e "s|__LAN_GW__|$LAN_GW|g" -e "s|__ADMIN_HASH__|$hash|g" \
      "$PREFIX/system/opt/AdGuardHome/AdGuardHome.yaml.template" > "$AGH/AdGuardHome.yaml"
    chmod 600 "$AGH/AdGuardHome.yaml"
    printf 'admin\n%s\n' "$pw" > "$ETC/adguard.creds"
    chmod 640 "$ETC/adguard.creds"; chown root:privacypi "$ETC/adguard.creds"
    log "AdGuard Home seeded"
  else
    log "ERROR: could not hash the AdGuard password"
  fi
fi

# The dashboard's own features (live DNS view, insights, blocklist refresh)
# talk to AdGuard Home's API with "user:password" from this file.
if [[ -s "$ETC/adguard.creds" && ! -s "$ETC/adguard.cred" ]]; then
  printf 'admin:%s\n' "$(sed -n 2p "$ETC/adguard.creds")" > "$ETC/adguard.cred"
  chmod 640 "$ETC/adguard.cred"; chown root:privacypi "$ETC/adguard.cred"
fi

# Caddy front-end: HTTP + HTTPS on the LAN names (and HOST_IP when set).
if [[ -f "$PREFIX/system/etc/caddy/Caddyfile.template" ]]; then
  host_ip=$(awk -F'[= ]' '/^HOST_IP=/{print $2; exit}' "$SITE_CONF" 2>/dev/null)
  names="$HOST_MDNS, $LAN_GW${host_ip:+, $host_ip}"
  install -d /etc/caddy /var/log/caddy
  chown caddy:caddy /var/log/caddy 2>/dev/null || true
  sed -e "s|__SITE_NAMES__|$names|g" -e "s|__FLASK_PORT__|8443|g" \
    "$PREFIX/system/etc/caddy/Caddyfile.template" > /etc/caddy/Caddyfile
fi

# Default upstream DNS = encrypted (DoT); route-mode.sh switches it per mode.
if [[ ! -e /etc/unbound/unbound.conf.d/privacypi-forward.conf && -f "$PREFIX/system/etc/privacypi/unbound-forward-dot.conf" ]]; then
  install -m 644 "$PREFIX/system/etc/privacypi/unbound-forward-dot.conf" /etc/unbound/unbound.conf.d/privacypi-forward.conf
fi

/opt/privacypi/scripts/ap-config.sh render
touch "$ETC/.provisioned"
log "done"
