#!/usr/bin/env bash
# Replace /etc/privacypi/master.key from stdin (44-byte Fernet key
# urlsafe-base64). Backups the previous key.
#
# DANGEROUS — invalidates any existing encrypted credentials that were
# encrypted under a different master key.
set -euo pipefail
KEY=/etc/privacypi/master.key
PREV=/etc/privacypi/master.key.prev

NEW=$(cat -)
# basic shape check: 44 ascii chars, urlsafe alphabet
if [[ ! "$NEW" =~ ^[A-Za-z0-9_-]{43}=$ ]]; then
  echo '{"ok":false,"error":"malformed key"}'
  exit 1
fi
[[ -f "$KEY" ]] && cp "$KEY" "$PREV"
echo -n "$NEW" > "$KEY"
chown root:privacypi "$KEY"
chmod 0640 "$KEY"
echo '{"ok":true,"backup":"/etc/privacypi/master.key.prev"}'
