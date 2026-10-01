#!/usr/bin/env bash
# Daily digest — fetches insight summary and dispatches via apprise.
# Triggered by systemd timer at 08:00 local.
set -euo pipefail
SECRET=$(cat /etc/privacypi/alert.secret 2>/dev/null || echo "")
[[ -z "$SECRET" ]] && exit 0

# Build the message
MSG=$(curl -sk --max-time 5 -b /tmp/.daily-digest.cookie \
  "https://127.0.0.1:8443/api/insights/digest" 2>/dev/null \
  | python3 -c "import sys, json; print(json.load(sys.stdin).get('summary_text',''))")

if [[ -z "$MSG" ]]; then
  # Fallback: hit the script-internal alert endpoint with a short message
  MSG="PrivacyPi daily digest unavailable (Flask insight endpoint failed)."
fi

# Dispatch via internal alert endpoint (loopback + shared secret)
curl -sk --max-time 5 -X POST \
  -H "X-Internal-Secret: $SECRET" \
  --data-urlencode "message=$MSG" \
  --data-urlencode "level=info" \
  "https://127.0.0.1:8443/api/alert/internal/digest.daily" >/dev/null
echo "{\"ok\":true,\"sent_chars\":${#MSG}}"
