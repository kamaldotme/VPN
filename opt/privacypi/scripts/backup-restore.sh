#!/usr/bin/env bash
# Restore from encrypted backup on stdin.
# Usage: backup-restore.sh <admin-password>
set -euo pipefail
PASS="${1:-}"
[[ -z "$PASS" ]] && { echo "password required" >&2; exit 2; }

TMPDIR="$(mktemp -d)"
trap "rm -rf $TMPDIR" EXIT

openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -k "$PASS" | \
  tar -C "$TMPDIR" -xf -

[[ -d "$TMPDIR/snapshot" ]] || { echo "invalid backup" >&2; exit 3; }

# Restore
[[ -d "$TMPDIR/snapshot/etc-privacypi" ]] && cp -r "$TMPDIR/snapshot/etc-privacypi"/* /etc/privacypi/ 2>/dev/null || true
[[ -f "$TMPDIR/snapshot/privacypi.db" ]] && cp "$TMPDIR/snapshot/privacypi.db" /var/lib/privacypi/privacypi.db
[[ -f "$TMPDIR/snapshot/torrc" ]] && cp "$TMPDIR/snapshot/torrc" /etc/tor/torrc
[[ -f "$TMPDIR/snapshot/AdGuardHome.yaml" ]] && cp "$TMPDIR/snapshot/AdGuardHome.yaml" /opt/AdGuardHome/AdGuardHome.yaml

systemctl restart privacypi-flask AdGuardHome tor 2>/dev/null || true
echo "restore complete"
