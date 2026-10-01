#!/usr/bin/env bash
# Stream the AdGuard Home query log via its admin API (in-memory, real-time).
# Uses the "internal" user credentials in /etc/privacypi/adguard.cred.
#
# Usage:
#   dns-tail.sh recent [N=50]      # last N entries as JSON {data:[...]}
#   dns-tail.sh since <iso8601>    # entries newer than timestamp
set -euo pipefail
ACTION="${1:-recent}"
ARG="${2:-50}"
CRED_FILE=/etc/privacypi/adguard.cred
[[ -r "$CRED_FILE" ]] || { echo '{"error":"no creds"}'; exit 1; }
CRED=$(cat "$CRED_FILE")

case "$ACTION" in
  recent)
    curl -s --max-time 4 -u "$CRED" \
      "http://127.0.0.1:3000/control/querylog?limit=$ARG"
    ;;
  since)
    # AdGuard supports older_than parameter; we filter client-side instead
    curl -s --max-time 4 -u "$CRED" \
      "http://127.0.0.1:3000/control/querylog?limit=200" \
      | python3 -c "
import json, sys
d = json.load(sys.stdin)
since = '$ARG'
out = [r for r in d.get('data',[]) if (r.get('time') or '') > since]
print(json.dumps({'data': out}))
"
    ;;
  *) echo '{"error":"unknown"}'; exit 2 ;;
esac
