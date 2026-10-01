#!/usr/bin/env bash
# WireGuard server management.
# Usage:
#   wg-server.sh init                       # create server keys + config
#   wg-server.sh add-peer <name>            # generate peer config, return JSON
#   wg-server.sh remove-peer <name>
#   wg-server.sh list-peers
#   wg-server.sh start | stop | status
set -euo pipefail
source /opt/privacypi/scripts/lib/site.sh
WG_DIR="/etc/wireguard"
SRV_CONF="$WG_DIR/wg-srv.conf"
PEERS_DIR="$WG_DIR/peers"
SRV_PORT="$WG_PORT"
SRV_NET="$WG_NET"
SRV_IP="$WG_GW"
WG_PREFIX="${WG_GW%.*}"   # e.g. 10.20.0 — base for peer addresses

ACTION="${1:-status}"

ensure_init() {
  mkdir -p "$WG_DIR" "$PEERS_DIR"
  chmod 700 "$WG_DIR" "$PEERS_DIR"
  if [[ ! -f "$WG_DIR/server-private.key" ]]; then
    umask 077
    wg genkey | tee "$WG_DIR/server-private.key" | wg pubkey > "$WG_DIR/server-public.key"
  fi
}

case "$ACTION" in
  init)
    ensure_init
    SRV_PRIV=$(cat "$WG_DIR/server-private.key")
    cat > "$SRV_CONF" <<CONF
[Interface]
PrivateKey = $SRV_PRIV
Address = $SRV_IP/24
ListenPort = $SRV_PORT
PostUp = iptables -A FORWARD -i wg-srv -j ACCEPT; iptables -A FORWARD -o wg-srv -j ACCEPT; iptables -t nat -A POSTROUTING -o $WAN_IFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i wg-srv -j ACCEPT; iptables -D FORWARD -o wg-srv -j ACCEPT; iptables -t nat -D POSTROUTING -o $WAN_IFACE -j MASQUERADE
CONF
    chmod 600 "$SRV_CONF"
    echo "{\"ok\": true, \"public_key\": \"$(cat "$WG_DIR/server-public.key")\"}"
    ;;
    
  add-peer)
    NAME="${2:-}"
    [[ -z "$NAME" ]] && { echo '{"ok":false,"error":"name required"}'; exit 1; }
    [[ "$NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo '{"ok":false,"error":"bad name"}'; exit 1; }
    ensure_init
    [[ ! -f "$SRV_CONF" ]] && { echo '{"ok":false,"error":"server not initialized"}'; exit 1; }
    
    PEER_DIR="$PEERS_DIR/$NAME"
    mkdir -p "$PEER_DIR"; chmod 700 "$PEER_DIR"
    if [[ ! -f "$PEER_DIR/private.key" ]]; then
      umask 077
      wg genkey | tee "$PEER_DIR/private.key" | wg pubkey > "$PEER_DIR/public.key"
    fi
    # 2026 hardening: pre-shared key adds a hybrid post-quantum layer to the
    # WireGuard handshake (Curve25519 alone is not PQ-secure; the 32-byte PSK
    # is XOR'd into the chaining key and survives future quantum attacks on
    # the asymmetric exchange).
    if [[ ! -f "$PEER_DIR/preshared.key" ]]; then
      umask 077
      wg genpsk > "$PEER_DIR/preshared.key"
    fi
    
    # Pick next IP — count existing peers + 2 (server is .1, peers start at .2)
    # `set -e -o pipefail` + grep with no matches = pipeline fails; use awk instead
    EXISTING=$(awk '/^# peer /{c++} END{print c+0}' "$SRV_CONF" 2>/dev/null)
    PEER_IP="$WG_PREFIX.$((EXISTING + 2))"
    
    PEER_PUB=$(cat "$PEER_DIR/public.key")
    PEER_PRIV=$(cat "$PEER_DIR/private.key")
    PEER_PSK=$(cat "$PEER_DIR/preshared.key")
    SRV_PUB=$(cat "$WG_DIR/server-public.key")

    # Append peer to server config (with PSK for PQ hybrid)
    if ! grep -q "$PEER_PUB" "$SRV_CONF"; then
      cat >> "$SRV_CONF" <<CONF

# peer $NAME
[Peer]
PublicKey = $PEER_PUB
PresharedKey = $PEER_PSK
AllowedIPs = $PEER_IP/32
CONF
    fi
    
    # Get the Pi's public-facing IP (use the home router's WAN IP for production;
    # for now use the configured WAN_IFACE IP for LAN testing).
    EXT_IP=$(ip -4 addr show "$WAN_IFACE" | awk '/inet /{print $2; exit}' | cut -d/ -f1)
    
    # Generate peer config
    PEER_CONF="$PEER_DIR/peer.conf"
    cat > "$PEER_CONF" <<CONF
[Interface]
PrivateKey = $PEER_PRIV
Address = $PEER_IP/32
DNS = $WG_GW

[Peer]
PublicKey = $SRV_PUB
PresharedKey = $PEER_PSK
Endpoint = $EXT_IP:$SRV_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CONF
    chmod 600 "$PEER_CONF"
    
    # Reload server if running
    systemctl is-active wg-quick@wg-srv >/dev/null 2>&1 && systemctl restart wg-quick@wg-srv || true
    
    echo "{\"ok\":true,\"name\":\"$NAME\",\"ip\":\"$PEER_IP\",\"endpoint\":\"$EXT_IP:$SRV_PORT\",\"config_path\":\"$PEER_CONF\"}"
    ;;
    
  list-peers)
    ls -1 "$PEERS_DIR" 2>/dev/null | python3 -c "import sys,json; print(json.dumps({'peers': [l.strip() for l in sys.stdin]}))"
    ;;
    
  remove-peer)
    NAME="${2:-}"
    [[ -z "$NAME" ]] && exit 1
    rm -rf "$PEERS_DIR/$NAME"
    # Remove from server config (best-effort)
    sed -i "/^# peer $NAME$/,/^$/d" "$SRV_CONF"
    systemctl is-active wg-quick@wg-srv >/dev/null 2>&1 && systemctl restart wg-quick@wg-srv || true
    echo "{\"ok\":true}"
    ;;
    
  start)
    systemctl enable --now wg-quick@wg-srv 2>&1 | tail -2
    systemctl is-active wg-quick@wg-srv
    ;;
  stop)
    systemctl disable --now wg-quick@wg-srv
    ;;
  status)
    if systemctl is-active wg-quick@wg-srv >/dev/null 2>&1; then
      echo '{"running": true}'
    else
      echo '{"running": false}'
    fi
    ;;
  show-config)
    NAME="${2:-}"
    [[ -f "$PEERS_DIR/$NAME/peer.conf" ]] && cat "$PEERS_DIR/$NAME/peer.conf"
    ;;
  *)
    echo "usage: $0 {init|add-peer <name>|list-peers|remove-peer <name>|start|stop|status|show-config <name>}"
    exit 2 ;;
esac
