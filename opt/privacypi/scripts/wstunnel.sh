#!/usr/bin/env bash
# WireGuard DPI obfuscation — wrap WG packets in WebSocket-over-HTTPS so they
# look like vanilla TLS to deep-packet-inspection middleboxes.
#
# Server side: wstunnel server on TCP 8443 (would conflict with Flask, so we
# use 8444). Client side (your phone/laptop) needs wstunnel too — see the
# generated client config.
#
# Usage:
#   wstunnel.sh install        # apt-get install or fetch binary
#   wstunnel.sh enable [port]  # default 8444
#   wstunnel.sh disable
#   wstunnel.sh status
#   wstunnel.sh client-config <peer-name>   # emits a curl-able client conf
set -euo pipefail
source /opt/privacypi/scripts/lib/site.sh
ACTION="${1:-status}"
PORT="${2:-8444}"
SERVICE=/etc/systemd/system/privacypi-wstunnel.service

install_wstunnel() {
  if command -v wstunnel >/dev/null 2>&1; then return; fi
  ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
  case "$ARCH" in
    arm64|aarch64) BIN="wstunnel_linux_arm64" ;;
    amd64|x86_64)  BIN="wstunnel_linux_amd64" ;;
    *) echo "{\"ok\":false,\"error\":\"unsupported arch $ARCH\"}"; return 1 ;;
  esac
  # Use the official Rust rewrite (faster, smaller). Pin a stable tag.
  URL="https://github.com/erebe/wstunnel/releases/download/v10.4.0/wstunnel_10.4.0_linux_arm64.tar.gz"
  TMP=$(mktemp -d); trap "rm -rf $TMP" RETURN
  curl -fsSL -o "$TMP/wt.tgz" "$URL" || return 1
  tar -xzf "$TMP/wt.tgz" -C "$TMP"
  install -m 0755 "$TMP/wstunnel" /usr/local/bin/wstunnel
  /usr/local/bin/wstunnel --version 2>&1 | head -1
}

write_unit() {
  cat > "$SERVICE" <<UNIT
[Unit]
Description=PrivacyPi wstunnel server (WG over WSS)
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/wstunnel server --restrict-to 127.0.0.1:$WG_PORT wss://0.0.0.0:$PORT
Restart=on-failure
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT
}

case "$ACTION" in
  install)
    install_wstunnel && echo '{"ok":true,"installed":true}' || echo '{"ok":false}'
    ;;
  enable)
    install_wstunnel || true
    write_unit
    systemctl daemon-reload
    systemctl enable --now privacypi-wstunnel
    sleep 2
    systemctl is-active privacypi-wstunnel >/dev/null \
      && echo "{\"ok\":true,\"port\":$PORT,\"endpoint\":\"wss://<your-pi-public-ip>:$PORT\"}" \
      || echo '{"ok":false,"error":"failed to start"}'
    ;;
  disable)
    systemctl disable --now privacypi-wstunnel 2>/dev/null || true
    rm -f "$SERVICE"
    systemctl daemon-reload
    echo '{"ok":true}'
    ;;
  status)
    if systemctl is-active privacypi-wstunnel >/dev/null 2>&1; then
      echo "{\"active\":true,\"port\":$PORT}"
    else
      echo '{"active":false}'
    fi
    ;;
  client-config)
    NAME="${2:-default}"
    EXT_IP=$(ip -4 addr show "$WAN_IFACE" | awk '/inet /{print $2; exit}' | cut -d/ -f1)
    cat <<DOC
# Run on the CLIENT to wrap WireGuard via wstunnel:
#   wstunnel client -L 'udp://51820:127.0.0.1:$WG_PORT?timeout_sec=0' wss://$EXT_IP:$PORT
# Then point your wg-quick config Endpoint to 127.0.0.1:51820 (instead of $EXT_IP:$WG_PORT).
DOC
    ;;
  *) echo '{"ok":false}'; exit 2 ;;
esac
