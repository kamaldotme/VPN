#!/usr/bin/env bash
# Manage the Tor hidden service for the PrivacyPi admin UI.
# Usage:
#   onion-admin.sh enable    # add HiddenServiceDir to torrc, reload tor, print .onion
#   onion-admin.sh disable
#   onion-admin.sh status    # print onion address (if any) + state
set -euo pipefail
ACTION="${1:-status}"
HS_DIR="/var/lib/tor/privacypi-admin"
TORRC="/etc/tor/torrc"
MARK_BEGIN="# >>> privacypi-admin onion (managed)"
MARK_END="# <<< privacypi-admin onion"

ensure_block() {
  if ! grep -q "$MARK_BEGIN" "$TORRC"; then
    cat >> "$TORRC" <<EOF

$MARK_BEGIN
HiddenServiceDir $HS_DIR
HiddenServicePort 80 127.0.0.1:8443
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
    # wait for hostname
    for i in 1 2 3 4 5 6 7 8 9 10; do
      [[ -f "$HS_DIR/hostname" ]] && break
      sleep 1
    done
    if [[ -f "$HS_DIR/hostname" ]]; then
      ONION=$(cat "$HS_DIR/hostname")
      echo "{\"ok\":true,\"onion\":\"$ONION\"}"
    else
      echo "{\"ok\":false,\"error\":\"hostname not generated yet\"}"
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
      ONION=$(cat "$HS_DIR/hostname")
      ENABLED="false"
      grep -q "$MARK_BEGIN" "$TORRC" && ENABLED="true"
      echo "{\"ok\":true,\"enabled\":$ENABLED,\"onion\":\"$ONION\"}"
    else
      echo '{"ok":true,"enabled":false,"onion":null}'
    fi
    ;;
  *)
    echo "{\"ok\":false,\"error\":\"unknown action\"}"; exit 2 ;;
esac
