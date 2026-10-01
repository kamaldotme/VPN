#!/usr/bin/env bash
# PrivacyPi installer.
#
# Two ways this runs:
#   1. Image build (PRIVACYPI_IMAGE_BUILD=1, inside a chroot — see build-image.sh):
#      installs everything, generates NO secrets and starts nothing. The device
#      provisions itself on first boot (opt/privacypi/scripts/boot-init.sh).
#   2. Developer install on a running Raspberry Pi OS Lite (64-bit):
#        sudo bash install.sh && sudo reboot
#
# Either way the device comes up broadcasting the setup WiFi "PrivacyPi-Setup"
# (password: privacypi) and serves the setup wizard at http://10.10.10.1.
# Idempotent — re-run to re-apply config drift.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
INSTALL_PREFIX=/opt/privacypi
ETC_PRIVACYPI=/etc/privacypi
SITE_CONF="$ETC_PRIVACYPI/site.conf"
LOG_FILE=/var/log/privacypi-install.log
IMAGE_BUILD="${PRIVACYPI_IMAGE_BUILD:-0}"
PP_VERSION="$(cat "$REPO_ROOT/VERSION" 2>/dev/null || echo dev)"

# Pinned third-party releases (bump deliberately, then re-test)
AGH_VER=v0.107.79
SS_VER=v1.25.0
XRAY_VER=v26.3.27
T2S_VER=v2.7.0

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }

log()  { echo -e "\033[36m==>\033[0m $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "\033[33m!! $*\033[0m" | tee -a "$LOG_FILE"; }
die()  { echo -e "\033[31m## $*\033[0m" | tee -a "$LOG_FILE"; exit 1; }
sc_q() { systemctl "$@" >> "$LOG_FILE" 2>&1 || true; }

#-----------------------------------------------------------
log "1/9 Platform"
#-----------------------------------------------------------
command -v apt-get >/dev/null 2>&1 || die "This installer needs a Debian-based OS (Raspberry Pi OS / Debian)"
. /etc/os-release 2>/dev/null || true
log "    OS: ${PRETTY_NAME:-unknown}   arch: $(dpkg --print-architecture 2>/dev/null)   image-build: $IMAGE_BUILD   version: $PP_VERSION"

#-----------------------------------------------------------
log "2/9 User, directories, site.conf"
#-----------------------------------------------------------
if ! id privacypi >/dev/null 2>&1; then
  useradd --system --create-home --home-dir "$INSTALL_PREFIX" --shell /bin/bash privacypi
fi
install -d -m 750 -o root -g privacypi "$ETC_PRIVACYPI"
# The Flask app (user privacypi) owns its state + log dirs.
install -d -m 750 -o privacypi -g privacypi /var/lib/privacypi /var/log/privacypi
install -d -m 755 /etc/iptables /var/log/caddy
if [[ ! -s "$SITE_CONF" ]]; then
  install -m 644 "$REPO_ROOT/system/etc/privacypi/site.conf.example" "$SITE_CONF"
fi
chown root:root "$SITE_CONF"; chmod 644 "$SITE_CONF"

#-----------------------------------------------------------
log "3/9 Packages"
#-----------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  python3 python3-venv python3-pip \
  iptables ipset iproute2 iputils-ping conntrack \
  hostapd dnsmasq bridge-utils \
  wpasupplicant iw rfkill \
  unbound dns-root-data \
  tor \
  wireguard-tools \
  openvpn \
  curl gnupg ca-certificates avahi-daemon avahi-utils \
  rsync sudo unzip xz-utils sqlite3 openssl \
  chrony \
  >> "$LOG_FILE" 2>&1 || die "apt install failed — see $LOG_FILE"
# Nice-to-have packages whose names/availability vary between releases.
for pkg in obfs4proxy snowflake-client macchanger vnstat usbutils socat bind9-host \
           netcat-openbsd speedtest-cli torsocks bsdextrautils; do
  apt-get install -y --no-install-recommends "$pkg" >> "$LOG_FILE" 2>&1 || warn "optional package $pkg unavailable"
done

# Caddy from its official repo
if ! command -v caddy >/dev/null 2>&1; then
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key 2>/dev/null \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  echo 'deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main' \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt-get install -y caddy >> "$LOG_FILE" 2>&1 || die "caddy install failed — see $LOG_FILE"
fi
log "    apt: done"

DEB_ARCH=$(dpkg --print-architecture 2>/dev/null || echo arm64)
case "$DEB_ARCH" in
  amd64|x86_64) AGH_ARCH=amd64; XRAY_ARCH=64;        T2S_ARCH=amd64; SS_ARCH=x86_64-unknown-linux-gnu ;;
  *)            AGH_ARCH=arm64; XRAY_ARCH=arm64-v8a; T2S_ARCH=arm64; SS_ARCH=aarch64-unknown-linux-gnu ;;
esac

#-----------------------------------------------------------
log "4/9 AdGuard Home $AGH_VER + proxy binaries"
#-----------------------------------------------------------
if [[ ! -x /opt/AdGuardHome/AdGuardHome ]]; then
  tmp=$(mktemp -d)
  if curl -fsSL "https://github.com/AdguardTeam/AdGuardHome/releases/download/${AGH_VER}/AdGuardHome_linux_${AGH_ARCH}.tar.gz" -o "$tmp/agh.tgz" >>"$LOG_FILE" 2>&1; then
    tar -xzf "$tmp/agh.tgz" -C /opt/      # extracts /opt/AdGuardHome/AdGuardHome
    chown -R root:root /opt/AdGuardHome; chmod -R go-w /opt/AdGuardHome   # tarball ships world-writable
    chmod 755 /opt/AdGuardHome/AdGuardHome
  else
    die "AdGuard Home download failed"
  fi
  rm -rf "$tmp"
fi
cat > /etc/systemd/system/AdGuardHome.service <<'UNIT'
[Unit]
Description=AdGuard Home
After=network.target unbound.service privacypi-init.service
ConditionPathExists=/opt/AdGuardHome/AdGuardHome.yaml
[Service]
ExecStart=/opt/AdGuardHome/AdGuardHome --no-check-update --work-dir /opt/AdGuardHome --config /opt/AdGuardHome/AdGuardHome.yaml
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT

# Best-effort — these power the optional "proxy" routing mode. Failures only warn.
fetch_bin() {  # name url glob
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
fetch_bin sslocal "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${SS_VER}/shadowsocks-${SS_VER}.${SS_ARCH}.tar.xz" "sslocal"
fetch_bin xray "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-${XRAY_ARCH}.zip" "xray"
fetch_bin tun2socks "https://github.com/xjasonlyu/tun2socks/releases/download/${T2S_VER}/tun2socks-linux-${T2S_ARCH}.zip" "tun2socks*"

#-----------------------------------------------------------
log "5/9 Copying PrivacyPi to $INSTALL_PREFIX"
#-----------------------------------------------------------
mkdir -p "$INSTALL_PREFIX"/{app,scripts,system}
rsync -a --delete --exclude '__pycache__' --exclude '.pytest_cache' "$REPO_ROOT/app/" "$INSTALL_PREFIX/app/"
rsync -a --delete "$REPO_ROOT/opt/privacypi/scripts/" "$INSTALL_PREFIX/scripts/"
rsync -a --delete "$REPO_ROOT/system/" "$INSTALL_PREFIX/system/"
echo "$PP_VERSION" > "$INSTALL_PREFIX/VERSION"
chown -R privacypi:privacypi "$INSTALL_PREFIX/app"
chown -R root:root "$INSTALL_PREFIX/scripts" "$INSTALL_PREFIX/system"
chmod 755 "$INSTALL_PREFIX" "$INSTALL_PREFIX/scripts"
find "$INSTALL_PREFIX/scripts" -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod 755 {} \;

#-----------------------------------------------------------
log "6/9 Python venv + Flask deps"
#-----------------------------------------------------------
if [[ ! -x "$INSTALL_PREFIX/venv/bin/python" ]]; then
  python3 -m venv "$INSTALL_PREFIX/venv"
fi
"$INSTALL_PREFIX/venv/bin/pip" install --no-cache-dir --upgrade pip wheel >> "$LOG_FILE" 2>&1
"$INSTALL_PREFIX/venv/bin/pip" install --no-cache-dir -r "$INSTALL_PREFIX/app/requirements.txt" >> "$LOG_FILE" 2>&1 \
  || die "pip install failed — see $LOG_FILE"

#-----------------------------------------------------------
log "7/9 System configuration"
#-----------------------------------------------------------
SYS="$INSTALL_PREFIX/system/etc"

# --- networking: systemd-networkd owns the LAN bridge, the wired uplink and the
# WiFi-WAN radio (files rendered by net-roles.sh at boot). Other network
# managers must not fight it. Nothing is switched live — it takes effect on the
# next boot, so an SSH session running this installer is not cut off.
for unit in NetworkManager.service NetworkManager-wait-online.service NetworkManager-dispatcher.service \
            wpa_supplicant.service dhcpcd.service systemd-resolved.service \
            userconfig.service; do
  sc_q disable "$unit"
  sc_q mask "$unit"
done
# cloud-init would re-apply NetworkManager/netplan config and rename things on first boot.
[[ -d /etc/cloud ]] && touch /etc/cloud/cloud-init.disabled
rm -f /etc/ssh/sshd_config.d/rename_user.conf
sc_q enable systemd-networkd.service
# Don't hold boot for 2 minutes when no cable is plugged in.
install -d /etc/systemd/system/systemd-networkd-wait-online.service.d
cat > /etc/systemd/system/systemd-networkd-wait-online.service.d/10-privacypi.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/usr/lib/systemd/systemd-networkd-wait-online --any --timeout=15
EOF

# --- services whose start can race the LAN bridge: keep retrying
for svc in dnsmasq hostapd; do
  install -d "/etc/systemd/system/$svc.service.d"
  cat > "/etc/systemd/system/$svc.service.d/10-privacypi.conf" <<'EOF'
[Unit]
After=privacypi-init.service systemd-networkd.service
StartLimitIntervalSec=0
[Service]
Restart=on-failure
RestartSec=3
EOF
done
install -d /etc/systemd/system/tor@default.service.d
cat > /etc/systemd/system/tor@default.service.d/10-privacypi.conf <<'EOF'
[Unit]
StartLimitIntervalSec=0
[Service]
Restart=on-failure
RestartSec=10
EOF

# --- daemon configs
install -d /etc/dnsmasq.d /etc/unbound/unbound.conf.d /etc/chrony/conf.d /etc/hostapd
install -m 644 "$SYS"/dnsmasq.d/*.conf /etc/dnsmasq.d/
install -m 644 "$SYS"/unbound/unbound.conf.d/*.conf /etc/unbound/unbound.conf.d/
install -m 644 "$SYS"/chrony/conf.d/*.conf /etc/chrony/conf.d/
install -m 644 "$SYS/default/hostapd" /etc/default/hostapd
install -m 644 "$SYS/sysctl.d/99-privacypi.conf" /etc/sysctl.d/99-privacypi.conf
install -m 644 "$SYS/modules-load.d/privacypi.conf" /etc/modules-load.d/privacypi.conf
install -d /etc/iproute2/rt_tables.d
install -m 644 "$SYS"/iproute2/rt_tables.d/*.conf /etc/iproute2/rt_tables.d/ 2>/dev/null || true
if [[ -d /etc/tor ]]; then
  [[ -f /etc/tor/torrc && ! -f /etc/tor/torrc.dist ]] && cp /etc/tor/torrc /etc/tor/torrc.dist
  install -m 644 "$SYS/tor/torrc" /etc/tor/torrc
fi
# mDNS (privacypi.local) is for the PrivacyPi WiFi only — never announce the
# device on the upstream network.
if [[ -f /etc/avahi/avahi-daemon.conf ]]; then
  LAN_BRIDGE_V=$(awk -F= '/^LAN_BRIDGE=/{print $2; exit}' "$SITE_CONF"); LAN_BRIDGE_V=${LAN_BRIDGE_V:-br-vlan10}
  sed -i -e '/^[#[:space:]]*allow-interfaces=/d' -e "s/^\[server\]/[server]\nallow-interfaces=$LAN_BRIDGE_V/" /etc/avahi/avahi-daemon.conf
fi
# Bluetooth is unused: less radio noise next to the WiFi AP, smaller attack surface.
for unit in bluetooth.service hciuart.service; do sc_q disable "$unit"; sc_q mask "$unit"; done

# Keep the journal small on an SD card
install -d /etc/systemd/journald.conf.d
# Persistent, so a crash or freeze leaves evidence for the next boot.
install -d -m 2755 /var/log/journal
printf '[Journal]\nStorage=persistent\nSystemMaxUse=60M\nRuntimeMaxUse=30M\n' > /etc/systemd/journald.conf.d/10-privacypi.conf

# --- hostname → privacypi.local via mDNS
echo privacypi > /etc/hostname
{ grep -v '^127\.0\.1\.1' /etc/hosts 2>/dev/null; printf '127.0.1.1\tprivacypi\n'; } > /tmp/hosts.new
cat /tmp/hosts.new > /etc/hosts 2>/dev/null || warn "could not update /etc/hosts"
rm -f /tmp/hosts.new

# --- units + sudoers
install -m 644 "$SYS"/systemd/system/*.service /etc/systemd/system/
install -m 644 "$SYS"/systemd/system/*.timer   /etc/systemd/system/
rm -f /etc/systemd/system/privacypi-net-roles.service \
      /etc/systemd/system/multi-user.target.wants/privacypi-net-roles.service
rm -rf /etc/systemd/system/privacypi-flask.service.d
install -m 440 -o root -g root "$SYS/sudoers.d/privacypi" /etc/sudoers.d/privacypi
visudo -cf /etc/sudoers.d/privacypi >/dev/null || die "sudoers file invalid"

# systemd applies unit presets ("enable-only") on the very first boot of an
# image: every installed unit that no preset file disables gets ENABLED —
# verified in tests/e2e.sh (caddy-api, chronyd-restricted, rsync… came up).
# So: list what we want, and disable everything else. The file sorts after
# 90-systemd.preset so systemd's own defaults (getty, …) still apply; units
# already enabled in the base image are never disabled by this pass.
ENABLE_UNITS=(privacypi-init.service unbound.service dnsmasq.service hostapd.service AdGuardHome.service
              tor.service chrony.service avahi-daemon.service caddy.service systemd-networkd.service
              privacypi-firewall.service privacypi-vpn-up.service privacypi-setup-mode.service
              privacypi-wan-watch.service privacypi-flask.service privacypi-diag.timer)
install -d /etc/systemd/system-preset
{
  for u in "${ENABLE_UNITS[@]}"; do echo "enable $u"; done
  cat <<'EOF'
disable privacypi-*
disable NetworkManager*
disable wpa_supplicant.service
disable systemd-resolved.service
disable systemd-timesyncd.service
disable userconfig.service
disable ssh.service
disable ssh.socket
disable openvpn.service
disable nftables.service
disable cloud-*
disable *
EOF
} > /etc/systemd/system-preset/95-privacypi.preset
rm -f /etc/systemd/system-preset/00-privacypi.preset

sc_q daemon-reload
sc_q unmask hostapd        # ships masked on Debian / Raspberry Pi OS
for svc in "${ENABLE_UNITS[@]}"; do
  systemctl enable "$svc" >> "$LOG_FILE" 2>&1 || warn "could not enable $svc"
done
sc_q disable openvpn.service

# The Pi resolves through its own filtering DNS.
rm -f /etc/resolv.conf 2>/dev/null || true
{ printf 'nameserver 127.0.0.1\noptions edns0\n' > /etc/resolv.conf; } 2>/dev/null || warn "could not write /etc/resolv.conf"

#-----------------------------------------------------------
log "8/9 Provisioning"
#-----------------------------------------------------------
BOOT=/boot/firmware; [[ -d "$BOOT" ]] || BOOT=/boot
if [[ -d "$BOOT" && ! -f "$BOOT/privacypi-config.txt" ]]; then
  install -m 644 "$REPO_ROOT/system/boot/privacypi-config.txt" "$BOOT/privacypi-config.txt" 2>/dev/null || true
fi

if [[ "$IMAGE_BUILD" == "1" ]]; then
  # Nothing device-specific may be baked into an image. boot-init.sh provisions
  # the device on its first boot.
  rm -f "$ETC_PRIVACYPI"/{.provisioned,setup-complete,master.key,secret.key,secret.env,alert.secret,adguard.creds,wifi-psk.txt}
  rm -f /opt/AdGuardHome/AdGuardHome.yaml /etc/hostapd/hostapd.conf /etc/caddy/Caddyfile
  rm -f /var/lib/privacypi/privacypi.db
  log "    image build: secrets deferred to first boot"
else
  sysctl --system >> "$LOG_FILE" 2>&1 || true
  NET_ROLES_NO_RELOAD=1 "$INSTALL_PREFIX/scripts/net-roles.sh" apply 2>&1 | tee -a "$LOG_FILE" || warn "net-roles failed"
  "$INSTALL_PREFIX/scripts/provision.sh" 2>&1 | tee -a "$LOG_FILE" || warn "provisioning reported errors"
  # resolv.conf now points at our DNS — bring that path up so the Pi keeps resolving until the reboot.
  for svc in unbound AdGuardHome; do
    systemctl restart "$svc" >> "$LOG_FILE" 2>&1 || warn "service $svc did not start — check: systemctl status $svc"
  done
fi

#-----------------------------------------------------------
log "9/9 Done"
#-----------------------------------------------------------
if [[ "$IMAGE_BUILD" != "1" ]]; then
cat <<EOF

  ✓ PrivacyPi $PP_VERSION installed.

  Reboot now:   sudo reboot

  After the reboot:
    1. Join the WiFi  "PrivacyPi-Setup"   (password: privacypi)
    2. The setup page opens by itself — or browse to http://10.10.10.1
    3. Follow the wizard (about 2 minutes)

EOF
fi
