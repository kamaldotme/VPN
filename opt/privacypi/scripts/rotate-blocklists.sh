#!/usr/bin/env bash
# Trigger AdGuard to refresh all enabled filter lists. Runs weekly.
set -euo pipefail
CRED_FILE=/etc/privacypi/adguard.cred
[[ -r "$CRED_FILE" ]] || exit 0
CRED=$(cat "$CRED_FILE")

curl -s --max-time 10 -u "$CRED" \
  -X POST -H "Content-Type: application/json" \
  -d '{"whitelist":false}' \
  "http://127.0.0.1:3000/control/filtering/refresh" >/dev/null

curl -s --max-time 10 -u "$CRED" \
  -X POST -H "Content-Type: application/json" \
  -d '{"whitelist":true}' \
  "http://127.0.0.1:3000/control/filtering/refresh" >/dev/null

echo '{"ok":true,"action":"blocklists_refreshed"}'
