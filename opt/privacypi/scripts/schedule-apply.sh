#!/usr/bin/env bash
# Read /etc/privacypi/schedule.json and apply current rule based on time.
# Schedule format: [{"name":"night-tor","mode":"tor","start":"22:00","end":"07:00","days":[0,1,2,3,4,5,6]}]
set -uo pipefail
SCHED=/etc/privacypi/schedule.json
[[ ! -f "$SCHED" ]] && exit 0

NOW_HM=$(date +"%H:%M")
DAY_OF_WEEK=$(($(date +"%u") % 7))  # Sun=0..Sat=6

# Find first matching rule (Python for JSON parsing)
TARGET=$(python3 - "$SCHED" "$NOW_HM" "$DAY_OF_WEEK" <<'PY'
import json, sys
sched_path, now_hm, dow = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(sched_path) as f:
    rules = json.load(f)
def in_window(now, start, end):
    if start <= end: return start <= now < end
    return now >= start or now < end  # crosses midnight
for r in rules:
    if dow not in r.get("days", list(range(7))): continue
    if in_window(now_hm, r["start"], r["end"]):
        print(r["mode"]); sys.exit(0)
PY
)

if [[ -n "$TARGET" ]]; then
  CURRENT=$(python3 -c "import json; print(json.load(open('/var/lib/privacypi/active-vpn')).get('mode','direct'))" 2>/dev/null || echo "")
  if [[ "$CURRENT" != "$TARGET" ]]; then
    /opt/privacypi/scripts/route-mode.sh "$TARGET"
    echo "$(date -Iseconds) scheduled switch: $CURRENT → $TARGET" >> /var/log/privacypi/schedule.log
  fi
fi
