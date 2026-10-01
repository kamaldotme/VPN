#!/usr/bin/env bash
# Write VPN auth.txt or upload .ovpn for a provider, owner-correct perms.
# Usage:
#   vpn-write.sh auth <provider> <username> <password>
#   vpn-write.sh server <provider> <filename> <base64-content>
#   vpn-write.sh select <provider> <filename>     (sets current.ovpn symlink)
#   vpn-write.sh delete-server <provider> <filename>
set -euo pipefail
ACTION="${1:-}"; P="${2:-}"
DIR="/etc/privacypi/vpn/$P"
[[ -d "$DIR" ]] || { echo "no provider dir: $P" >&2; exit 2; }

case "$ACTION" in
  auth)
    USER="${3:-}"; PASS="${4:-}"
    [[ -z "$USER" || -z "$PASS" ]] && { echo "user/pass required" >&2; exit 2; }
    printf '%s\n%s\n' "$USER" "$PASS" > "$DIR/auth.txt"
    chmod 600 "$DIR/auth.txt"
    chown root:privacypi "$DIR/auth.txt"
    echo "auth written for $P"
    ;;
  server)
    FN="${3:-}"; B64="${4:-}"
    [[ -z "$FN" || -z "$B64" ]] && { echo "filename/content required" >&2; exit 2; }
    [[ "$FN" =~ ^[[:alnum:]._-]+$ ]] || { echo "unsafe filename" >&2; exit 2; }
    echo "$B64" | base64 -d > "$DIR/servers/$FN"
    chmod 644 "$DIR/servers/$FN"
    echo "server $FN saved for $P"
    ;;
  select)
    FN="${3:-}"
    [[ -f "$DIR/servers/$FN" ]] || { echo "no such server" >&2; exit 2; }
    ln -sf "servers/$FN" "$DIR/current.ovpn"
    echo "selected $FN for $P"
    ;;
  delete-server)
    FN="${3:-}"
    [[ "$FN" =~ ^[[:alnum:]._-]+$ ]] || { echo "unsafe filename" >&2; exit 2; }
    rm -f "$DIR/servers/$FN"
    echo "deleted $FN"
    ;;
  *) echo "unknown action $ACTION" >&2; exit 2 ;;
esac
