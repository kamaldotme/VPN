#!/usr/bin/env bash
# PrivacyPi installer — one-command bootstrap on a fresh Ubuntu Server 24.04.
#
# Run as root on the Pi (NOT on your laptop):
#   curl -fsSL https://raw.githubusercontent.com/YOUR/privacypi/main/install.sh | sudo bash
#
# Or after cloning:
#   sudo bash install.sh
#
# Idempotent — re-run to re-apply config drift.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
INSTALL_PREFIX=/opt/privacypi
ETC_PRIVACYPI=/etc/privacypi
SITE_CONF="$ETC_PRIVACYPI/site.conf"
LOG_FILE=/var/log/privacypi-install.log

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }

log() { echo -e "\033[36m==>\033[0m $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "\033[33m!! $*\033[0m" | tee -a "$LOG_FILE"; }
die() { echo -e "\033[31m## $*\033[0m" | tee -a "$LOG_FILE"; exit 1; }

mkdir -p "$ETC_PRIVACYPI" /var/lib/privacypi /var/log/caddy
chmod 750 "$ETC_PRIVACYPI"

#-----------------------------------------------------------
log "1/12 Detecting interfaces"
#-----------------------------------------------------------
# Find a wired interface with an IPv4 — that's the WAN/LAN-uplink
WAN_IFACE=$(ip -4 -br addr show 2>/dev/null \
  | awk '$1 ~ /^(eth|en|enp|enx)/ && $2 == "UP"{print $1; exit}')
[[ -z "$WAN_IFACE" ]] && die "No wired interface with carrier found"

HOST_IP=$(ip -4 addr show "$WAN_IFACE" | awk '/inet /{print $2; exit}' | cut -d/ -f1)
[[ -z "$HOST_IP" ]] && die "No IPv4 address on $WAN_IFACE"

# Find the AP-capable wireless (must support hostapd; we assume any wlan*)
AP_IFACE=$(ip -br link show 2>/dev/null \
  | awk '$1 ~ /^wl/{print $1; exit}')
[[ -z "$AP_IFACE" ]] && warn "No wireless interface found — AP mode disabled"

log "    WAN: $WAN_IFACE ($HOST_IP)   AP: ${AP_IFACE:-none}"

#-----------------------------------------------------------
log "2/12 Writing $SITE_CONF"
#-----------------------------------------------------------
if [[ ! -s "$SITE_CONF" ]]; then
  cp "$REPO_ROOT/system/etc/privacypi/site.conf.example" "$SITE_CONF"
  # WAN defaults to ethernet on first boot; the wired iface we probed is ETH_IFACE.
  # The admin switches to WiFi-WAN later from the dashboard (wan-config.sh).
  sed -i "s|^WAN_MODE=.*|WAN_MODE=ethernet|"        "$SITE_CONF"
  sed -i "s|^ETH_IFACE=.*|ETH_IFACE=$WAN_IFACE|"    "$SITE_CONF"
  sed -i "s|^AP_IFACE=.*|AP_IFACE=${AP_IFACE:-wlan1}|" "$SITE_CONF"
  sed -i "s|^HOST_IP=.*|HOST_IP=$HOST_IP|"          "$SITE_CONF"
fi
chown root:root "$SITE_CONF"; chmod 644 "$SITE_CONF"

#-----------------------------------------------------------
log "3/12 Installing OS dependencies"
#-----------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  python3 python3-venv python3-pip \
  iptables ipset iproute2 iputils-ping \
  hostapd dnsmasq bridge-utils \
  wpasupplicant iw wireless-tools rfkill macchanger \
  unbound \
  tor obfs4proxy \
  wireguard-tools \
  openvpn \
  curl gnupg ca-certificates avahi-daemon avahi-utils \
  apt-transport-https debian-keyring debian-archive-keyring \
  chrony \
  build-essential autoconf automake libtool libunbound-dev pkg-config \
  >> "$LOG_FILE" 2>&1
log "    apt: done"

# Caddy from official repo
if ! command -v caddy >/dev/null 2>&1; then
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key 2>/dev/null \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  echo 'deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main' \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt-get install -y caddy >> "$LOG_FILE" 2>&1
fi

# snowflake-client (Tor pluggable transport)
apt-get install -y snowflake-client >> "$LOG_FILE" 2>&1 || warn "snowflake-client unavailable on this distro"

# CPU arch for fetching release binaries
DEB_ARCH=$(dpkg --print-architecture 2>/dev/null || echo arm64)
case "$DEB_ARCH" in
  arm64|aarch64) AGH_ARCH=arm64; XRAY_ARCH=arm64-v8a; T2S_ARCH=arm64; SS_ARCH=aarch64-unknown-linux-gnu ;;
  amd64|x86_64)  AGH_ARCH=amd64; XRAY_ARCH=64;        T2S_ARCH=amd64; SS_ARCH=x86_64-unknown-linux-gnu ;;
  *)             AGH_ARCH=arm64; XRAY_ARCH=arm64-v8a; T2S_ARCH=arm64; SS_ARCH=aarch64-unknown-linux-gnu ;;
esac

#-----------------------------------------------------------
log "3b/12 AdGuard Home (filtering DNS on :53 → Unbound)"
#-----------------------------------------------------------
if [[ ! -x /opt/AdGuardHome/AdGuardHome ]]; then
  AGH_VER=v0.107.52
  tmp=$(mktemp -d)
  if curl -fsSL "https://github.com/AdguardTeam/AdGuardHome/releases/download/${AGH_VER}/AdGuardHome_linux_${AGH_ARCH}.tar.gz" -o "$tmp/agh.tgz" >>"$LOG_FILE" 2>&1; then
    tar -xzf "$tmp/agh.tgz" -C /opt/      # extracts /opt/AdGuardHome/AdGuardHome
    chmod 755 /opt/AdGuardHome/AdGuardHome 2>/dev/null || true
  else
    warn "AdGuard Home download failed — ad-blocking DNS not installed (re-run installer to retry)"
  fi
  rm -rf "$tmp"
fi
# Seed a working config once (admin pw generated; DNS forwards to Unbound)
if [[ -x /opt/AdGuardHome/AdGuardHome && ! -s /opt/AdGuardHome/AdGuardHome.yaml ]]; then
  AGH_PW=$(head -c 12 /dev/urandom | base64 | tr -d '/+=' | head -c 14)
  AGH_HASH=$(caddy hash-password --plaintext "$AGH_PW" 2>/dev/null || true)
  LAN_GW_V=$(awk -F= '/^LAN_GW=/{print $2; exit}' "$SITE_CONF"); LAN_GW_V=${LAN_GW_V:-10.10.10.1}
  if [[ -n "$AGH_HASH" ]]; then
    sed -e "s|__LAN_GW__|$LAN_GW_V|g" -e "s|__ADMIN_HASH__|$AGH_HASH|g" \
      "$REPO_ROOT/system/opt/AdGuardHome/AdGuardHome.yaml.template" > /opt/AdGuardHome/AdGuardHome.yaml
    printf 'admin\n%s\n' "$AGH_PW" > "$ETC_PRIVACYPI/adguard.creds"
    chmod 640 "$ETC_PRIVACYPI/adguard.creds"; chown root:privacypi "$ETC_PRIVACYPI/adguard.creds"
    log "    AdGuard admin pw: sudo cat $ETC_PRIVACYPI/adguard.creds"
  else
    warn "could not hash AdGuard admin password — finish AdGuard setup at http://<pi>:3000"
  fi
fi
if [[ -x /opt/AdGuardHome/AdGuardHome ]]; then
  cat > /etc/systemd/system/AdGuardHome.service <<'UNIT'
[Unit]
Description=AdGuard Home
After=network-online.target unbound.service
Wants=network-online.target
[Service]
ExecStart=/opt/AdGuardHome/AdGuardHome --no-check-update --work-dir /opt/AdGuardHome --config /opt/AdGuardHome/AdGuardHome.yaml
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
fi

#-----------------------------------------------------------
log "3c/12 Proxy/tunnel binaries (shadowsocks, xray, tun2socks)"
#-----------------------------------------------------------
# Best-effort — these power the optional "proxy" routing mode. Failures only warn.
fetch_bin() {  # name test-cmd download-url extract-glob
  local name="$1" url="$2" glob="$3"
  command -v "$name" >/dev/null 2>&1 && return 0
  local tmp; tmp=$(mktemp -d)
  if curl -fsSL "$url" -o "$tmp/dl" >>"$LOG_FILE" 2>&1; then
    case "$url" in
      *.tar.xz)  tar -xJf "$tmp/dl" -C "$tmp" >>"$LOG_FILE" 2>&1 || true ;;
      *.tar.gz)  tar -xzf "$tmp/dl" -C "$tmp" >>"$LOG_FILE" 2>&1 || true ;;
      *.zip)     unzip -o "$tmp/dl" -d "$tmp" >>"$LOG_FILE" 2>&1 || true ;;
    esac
    local found; found=$(find "$tmp" -type f -name "$glob" | head -1)
    if [[ -n "$found" ]]; then install -m755 "$found" "/usr/local/bin/$name"; else warn "$name: binary not found in archive"; fi
  else
    warn "$name: download failed (proxy mode will be unavailable until installed)"
  fi
  rm -rf "$tmp"
}
apt-get install -y unzip xz-utils >> "$LOG_FILE" 2>&1 || true
fetch_bin sslocal "https://github.com/shadowsocks/shadowsocks-rust/releases/download/v1.23.5/shadowsocks-v1.23.5.${SS_ARCH}.tar.xz" "sslocal"
fetch_bin xray "https://github.com/XTLS/Xray-core/releases/download/v25.3.6/Xray-linux-${XRAY_ARCH}.zip" "xray"
fetch_bin tun2socks "https://github.com/xjasonlyu/tun2socks/releases/download/v2.5.2/tun2socks-linux-${T2S_ARCH}.zip" "tun2socks*"

#-----------------------------------------------------------
log "4/12 Creating system user 'privacypi'"
#-----------------------------------------------------------
if ! id privacypi >/dev/null 2>&1; then
  useradd --system --create-home --home-dir "$INSTALL_PREFIX" --shell /bin/bash privacypi
fi

#-----------------------------------------------------------
log "5/12 Copying tree to $INSTALL_PREFIX"
#-----------------------------------------------------------
mkdir -p "$INSTALL_PREFIX"/{app,scripts,system}
rsync -a --delete "$REPO_ROOT/app/" "$INSTALL_PREFIX/app/"
rsync -a --delete "$REPO_ROOT/opt/privacypi/scripts/" "$INSTALL_PREFIX/scripts/"
rsync -a --delete "$REPO_ROOT/system/" "$INSTALL_PREFIX/system/"
chown -R privacypi:privacypi "$INSTALL_PREFIX/app"
chmod 755 "$INSTALL_PREFIX/scripts"
find "$INSTALL_PREFIX/scripts" -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod 755 {} \;

#-----------------------------------------------------------
log "6/12 Python venv + Flask deps"
#-----------------------------------------------------------
if [[ ! -x "$INSTALL_PREFIX/venv/bin/python" ]]; then
  python3 -m venv "$INSTALL_PREFIX/venv"
fi
"$INSTALL_PREFIX/venv/bin/pip" install --upgrade pip wheel >> "$LOG_FILE" 2>&1
"$INSTALL_PREFIX/venv/bin/pip" install -r "$INSTALL_PREFIX/app/requirements.txt" >> "$LOG_FILE" 2>&1

#-----------------------------------------------------------
log "7/12 Generating secrets (one-time)"
#-----------------------------------------------------------
gen_secret() {
  local path="$1" mode="$2" gen_cmd="$3"
  if [[ ! -s "$path" ]]; then
    eval "$gen_cmd" > "$path"
    chmod "$mode" "$path"
    chown root:privacypi "$path"
  fi
}
gen_secret "$ETC_PRIVACYPI/master.key" 640 \
  "$INSTALL_PREFIX/venv/bin/python -c 'from cryptography.fernet import Fernet; import sys; sys.stdout.buffer.write(Fernet.generate_key())'"
gen_secret "$ETC_PRIVACYPI/alert.secret" 640 \
  "head -c 48 /dev/urandom | base64 | tr -d '\n'"
gen_secret "$ETC_PRIVACYPI/secret.key" 640 \
  "head -c 64 /dev/urandom | base64 | tr -d '\n'"
echo "PRIVACYPI_SECRET_KEY=$(cat $ETC_PRIVACYPI/secret.key)" > "$ETC_PRIVACYPI/secret.env"
chmod 640 "$ETC_PRIVACYPI/secret.env"; chown root:privacypi "$ETC_PRIVACYPI/secret.env"

#-----------------------------------------------------------
log "8/12 Random WiFi passphrase + hostapd"
#-----------------------------------------------------------
if [[ -n "$AP_IFACE" ]]; then
  HOSTAPD_CONF=/etc/hostapd/hostapd.conf
  if [[ ! -f "$HOSTAPD_CONF" ]] || grep -q "^wpa_passphrase=privacypi$" "$HOSTAPD_CONF" 2>/dev/null; then
    WIFI_PSK=$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 14)
    cat > "$HOSTAPD_CONF" <<EOF
interface=$AP_IFACE
bridge=$LAN_BRIDGE
ssid=PrivacyPi
hw_mode=g
channel=7
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK SAE
wpa_pairwise=CCMP
rsn_pairwise=CCMP
wpa_passphrase=$WIFI_PSK
ap_isolate=1
sae_require_mfp=1
EOF
    chmod 600 "$HOSTAPD_CONF"
    echo "$WIFI_PSK" > "$ETC_PRIVACYPI/wifi-psk.txt"
    chmod 640 "$ETC_PRIVACYPI/wifi-psk.txt"
    chown root:privacypi "$ETC_PRIVACYPI/wifi-psk.txt"
    log "    Generated WiFi passphrase. Read it later via: sudo cat $ETC_PRIVACYPI/wifi-psk.txt"
  fi
fi

#-----------------------------------------------------------
log "8b/12 Network base config (netplan, networkd, dnsmasq, unbound)"
#-----------------------------------------------------------
# Apply the mirrored /etc network configs. netplan brings up the LAN bridge +
# ETH WAN; the networkd drop-in handles DHCP on the WiFi-WAN radio when the
# admin later switches WAN_MODE=wifi. We `generate` (validate) but do NOT
# `apply` automatically — the operator reboots once at the end.
SYS="$INSTALL_PREFIX/system/etc"
install -d /etc/systemd/network
[[ -f "$SYS/netplan/50-privacypi.yaml" ]] && install -m 600 "$SYS/netplan/50-privacypi.yaml" /etc/netplan/50-privacypi.yaml
for f in "$SYS"/systemd/network/*.network; do
  [[ -e "$f" ]] && install -m 644 "$f" /etc/systemd/network/
done
if [[ -d "$SYS/dnsmasq.d" ]]; then
  install -d /etc/dnsmasq.d
  install -m 644 "$SYS"/dnsmasq.d/*.conf /etc/dnsmasq.d/ 2>/dev/null || true
fi
if [[ -d "$SYS/unbound" ]]; then
  cp -r "$SYS/unbound/." /etc/unbound/ 2>/dev/null || true
fi
[[ -f "$SYS/sysctl.d/99-privacypi.conf" ]] && install -m 644 "$SYS/sysctl.d/99-privacypi.conf" /etc/sysctl.d/99-privacypi.conf
sysctl --system >> "$LOG_FILE" 2>&1 || true
netplan generate >> "$LOG_FILE" 2>&1 || warn "netplan generate reported issues — review $LOG_FILE"

#-----------------------------------------------------------
log "9/12 Caddy from template"
#-----------------------------------------------------------
mkdir -p /etc/caddy
HOST_MDNS=$(awk -F= '/^HOST_MDNS=/{print $2; exit}' "$SITE_CONF")
HOST_MDNS=${HOST_MDNS:-privacypi.local}
sed -e "s|__HOST_MDNS__|$HOST_MDNS|g" \
    -e "s|__HOST_IP__|$HOST_IP|g" \
    -e "s|__FLASK_PORT__|8443|g" \
    "$INSTALL_PREFIX/system/etc/caddy/Caddyfile.template" > /etc/caddy/Caddyfile

#-----------------------------------------------------------
log "10/12 systemd units + sudoers"
#-----------------------------------------------------------
install -m 644 "$INSTALL_PREFIX/system/etc/systemd/system/"*.service /etc/systemd/system/ 2>/dev/null || true
install -m 644 "$INSTALL_PREFIX/system/etc/systemd/system/"*.timer   /etc/systemd/system/ 2>/dev/null || true

# Flask service drop-in for HTTP loopback (Caddy fronts TLS)
mkdir -p /etc/systemd/system/privacypi-flask.service.d
cat > /etc/systemd/system/privacypi-flask.service.d/10-http-loopback.conf <<'EOF'
[Service]
Environment=PRIVACYPI_COOKIE_SECURE=1
EnvironmentFile=-/etc/privacypi/secret.env
ExecStart=
ExecStart=/opt/privacypi/venv/bin/gunicorn --bind 127.0.0.1:8443 --forwarded-allow-ips=127.0.0.1 --workers 2 --threads 4 wsgi:app
EOF

# Flask main unit if missing
if [[ ! -f /etc/systemd/system/privacypi-flask.service ]]; then
  cat > /etc/systemd/system/privacypi-flask.service <<EOF
[Unit]
Description=PrivacyPi Flask dashboard
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_PREFIX/app
User=privacypi
Group=privacypi
EnvironmentFile=-/etc/privacypi/secret.env
ExecStart=$INSTALL_PREFIX/venv/bin/gunicorn --bind 127.0.0.1:8443 --workers 2 --threads 4 wsgi:app
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
fi

# Sudoers — install the file from the repo, fix ownership, validate
install -m 440 -o root -g root "$INSTALL_PREFIX/system/etc/sudoers.d/privacypi" /etc/sudoers.d/privacypi
visudo -cf /etc/sudoers.d/privacypi >/dev/null

systemctl daemon-reload

# Free port 53 — systemd-resolved must not own it (AdGuard does). Point the
# Pi's own resolver at loopback.
if systemctl is-enabled systemd-resolved >/dev/null 2>&1; then
  systemctl disable --now systemd-resolved >> "$LOG_FILE" 2>&1 || true
fi
rm -f /etc/resolv.conf 2>/dev/null || true
printf 'nameserver 127.0.0.1\noptions edns0\n' > /etc/resolv.conf

# hostapd ships masked on Ubuntu Server — unmask before enabling the AP.
systemctl unmask hostapd >> "$LOG_FILE" 2>&1 || true

# Enable the whole stack. AP + DHCP + recursive DNS + filtering + firewall +
# routing (Direct mode on boot) + TLS + UI.
for svc in unbound dnsmasq hostapd AdGuardHome tor \
           privacypi-firewall privacypi-vpn-up \
           avahi-daemon caddy privacypi-flask; do
  systemctl enable --now "$svc" >> "$LOG_FILE" 2>&1 \
    || warn "service $svc did not start cleanly — check: systemctl status $svc"
done

#-----------------------------------------------------------
log "11/12 First-boot DB migration"
#-----------------------------------------------------------
sudo -u privacypi "$INSTALL_PREFIX/venv/bin/python" - <<PY
import sys
sys.path.insert(0, '$INSTALL_PREFIX/app')
from privacypi_app import create_app
from privacypi_app.extensions import db
app = create_app()
with app.app_context():
    db.create_all()
PY

#-----------------------------------------------------------
log "12/12 Done"
#-----------------------------------------------------------
cat <<EOF

  ┌─────────────────────────────────────────────────────────┐
  │                                                         │
  │   ✓ PrivacyPi installed                                 │
  │                                                         │
  │   Open a browser → https://$HOST_IP/setup
  │                  → https://privacypi.local/setup        │
  │                                                         │
  │   You'll be prompted to:                                │
  │     1. Set the admin password                           │
  │     2. Scan the TOTP QR with your authenticator app     │
  │     3. Save the 24-word recovery seed                   │
  │     4. Pick a privacy preset                            │
  │     5. Install the root cert (System → Trust device)    │
  │                                                         │
  │   WiFi:  SSID=PrivacyPi                                 │
  │   PSK:   sudo cat /etc/privacypi/wifi-psk.txt           │
  │                                                         │
  │   >>> REBOOT NOW to bring up the AP + routing:          │
  │       sudo reboot                                       │
  │                                                         │
  └─────────────────────────────────────────────────────────┘

EOF
