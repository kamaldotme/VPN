#!/usr/bin/env bash
# Read Tor's control port and emit current circuits as JSON.
set -euo pipefail
COOKIE=/run/tor/control.authcookie
[[ -r "$COOKIE" ]] || COOKIE=/var/run/tor/control.authcookie
[[ -r "$COOKIE" ]] || { echo '{"circuits":[]}'; exit 0; }

HEX=$(xxd -p < "$COOKIE" | tr -d '\n')

# Talk to control port, capture output
RAW=$(
  exec 3<>/dev/tcp/127.0.0.1/9051 || exit 0
  printf 'AUTHENTICATE %s\r\n' "$HEX" >&3
  printf 'GETINFO circuit-status\r\n' >&3
  printf 'QUIT\r\n' >&3
  cat <&3
  exec 3<&-
)

echo "$RAW" | python3 -c '
import sys, json, re
data = sys.stdin.read()
circuits = []
m = re.search(r"250\+circuit-status=\r?\n([\s\S]*?)\r?\n\.\r?\n", data)
if not m:
    m = re.search(r"250-circuit-status=([^\r\n]*)", data)
    lines = [m.group(1)] if m and m.group(1) else []
else:
    lines = [l for l in m.group(1).splitlines() if l.strip()]
for line in lines:
    parts = line.split(" ")
    if len(parts) < 3:
        continue
    cid, status = parts[0], parts[1]
    if status not in ("BUILT", "EXTENDED", "LAUNCHED"):
        continue
    path = parts[2]
    nodes = []
    for h in path.split(","):
        if "~" in h:
            fp, nick = h.split("~", 1)
        elif "=" in h:
            fp, nick = h.split("=", 1)
        else:
            fp, nick = h, ""
        nodes.append({"fp": fp.lstrip("$"), "nickname": nick})
    purpose = ""
    for p in parts[3:]:
        if p.startswith("PURPOSE="):
            purpose = p.split("=", 1)[1]
    circuits.append({"id": cid, "status": status, "purpose": purpose, "hops": nodes})
print(json.dumps({"circuits": circuits, "count": len(circuits)}))
'
