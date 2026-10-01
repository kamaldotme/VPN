#!/usr/bin/env bash
# Tor hidden service for SSH access to the Pi.
# Reach the Pi from anywhere via:  ssh -o "ProxyCommand=nc -X 5 -x 127.0.0.1:9050 %h %p" privacypi@<onion>
# (or equivalent torsocks / onioncat / Tor browser tunnel client side).
#
# Usage:
#   onion-ssh.sh enable
#   onion-ssh.sh disable
#   onion-ssh.sh status
set -euo pipefail
ACTION="${1:-status}"
HS_DIR="/var/lib/tor/privacypi-ssh"
TORRC="/etc/tor/torrc"
MARK_BEGIN="# >>> privacypi-ssh onion (managed)"
MARK_END="# <<< privacypi-ssh onion"

ensure_block() {
  if ! grep -q "$MARK_BEGIN" "$TORRC"; then
    cat >> "$TORRC" <<EOF

$MARK_BEGIN
HiddenServiceDir $HS_DIR
HiddenServicePort 22 127.0.0.1:22
HiddenServiceVersion 3
$MARK_END
EOF
  fi
}

remove_block() {
  if grep -q "$MARK_BEGIN" "$TORRC"; then
    sed -i "/$MARK_BEGIN/,/$MARK_END/d" "$TORRC"
  fi
}

case "$ACTION" in
  enable)
    mkdir -p "$HS_DIR"
    chown debian-tor:debian-tor "$HS_DIR" 2>/dev/null || chown _tor:_tor "$HS_DIR" 2>/dev/null || true
    chmod 700 "$HS_DIR"
    ensure_block
    systemctl reload tor 2>&1 | tail -2 || systemctl restart tor
    for i in 1 2 3 4 5 6 7 8 9 10; do
      [[ -f "$HS_DIR/hostname" ]] && break
      sleep 1
    done
    if [[ -f "$HS_DIR/hostname" ]]; then
      echo "{\"ok\":true,\"onion\":\"$(cat "$HS_DIR/hostname")\",\"port\":22}"
    else
      echo '{"ok":false,"error":"hostname not generated yet"}'
      exit 1
    fi
    ;;
  disable)
    remove_block
    systemctl reload tor 2>&1 | tail -2 || systemctl restart tor
    echo '{"ok":true}'
    ;;
  status)
    if [[ -f "$HS_DIR/hostname" ]]; then
      ON=false; grep -q "$MARK_BEGIN" "$TORRC" && ON=true
      echo "{\"ok\":true,\"enabled\":$ON,\"onion\":\"$(cat "$HS_DIR/hostname")\"}"
    else
      echo '{"ok":true,"enabled":false,"onion":null}'
    fi
    ;;
  *) echo '{"ok":false}'; exit 2 ;;
esac
