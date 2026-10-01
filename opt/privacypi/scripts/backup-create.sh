#!/usr/bin/env bash
# Create encrypted backup of PrivacyPi state. Output to stdout.
# Usage: backup-create.sh <admin-password>
set -euo pipefail
PASS="${1:-}"
[[ -z "$PASS" ]] && { echo "password required" >&2; exit 2; }

TMPDIR="$(mktemp -d)"
trap "rm -rf $TMPDIR" EXIT

# Snapshot critical state
mkdir -p "$TMPDIR/snapshot"
cp -r /etc/privacypi/ "$TMPDIR/snapshot/etc-privacypi" 2>/dev/null || true
cp /var/lib/privacypi/privacypi.db "$TMPDIR/snapshot/" 2>/dev/null || true
cp /etc/tor/torrc "$TMPDIR/snapshot/torrc" 2>/dev/null || true
cp /opt/AdGuardHome/AdGuardHome.yaml "$TMPDIR/snapshot/" 2>/dev/null || true

# Tar + encrypt with openssl AES-256
tar -C "$TMPDIR" -cf - snapshot/ | \
  openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -k "$PASS"
