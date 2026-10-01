#!/usr/bin/env bash
# Rotate the PreSharedKey on every WireGuard peer. Runs monthly.
# Each peer.conf is regenerated; clients must re-pair via QR (Travel page).
set -euo pipefail
WG_DIR="/etc/wireguard"
PEERS_DIR="$WG_DIR/peers"

[[ -d "$PEERS_DIR" ]] || { echo '{"ok":true,"rotated":0}'; exit 0; }

ROT=0
for peer in "$PEERS_DIR"/*; do
  [[ -d "$peer" ]] || continue
  NAME=$(basename "$peer")
  NEW_PSK=$(wg genpsk)
  echo -n "$NEW_PSK" > "$peer/preshared.key"
  chmod 600 "$peer/preshared.key"
  ROT=$((ROT+1))
done

# Trigger wg-server.sh to rebuild server config from each peer's keys
/opt/privacypi/scripts/wg-server.sh init >/dev/null 2>&1 || true
for peer in "$PEERS_DIR"/*; do
  [[ -d "$peer" ]] || continue
  NAME=$(basename "$peer")
  # Re-add: wg-server.sh add-peer is idempotent on key but must re-write peer.conf
  /opt/privacypi/scripts/wg-server.sh add-peer "$NAME" >/dev/null 2>&1 || true
done

systemctl is-active wg-quick@wg-srv >/dev/null && systemctl restart wg-quick@wg-srv || true

echo "{\"ok\":true,\"rotated\":$ROT,\"note\":\"clients must re-pair\"}"
