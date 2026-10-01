#!/usr/bin/env bash
# Toggle AdGuard upstream DNS between Unbound and Tor.
# Usage: tor-dns.sh on | off
set -euo pipefail
ACTION="${1:-off}"
YAML=/opt/AdGuardHome/AdGuardHome.yaml

case "$ACTION" in
  on)
    # Replace upstream_dns to point to Tor's DNSPort
    python3 -c "
import yaml
with open('$YAML') as f: d = yaml.safe_load(f)
d['dns']['upstream_dns'] = ['127.0.0.1:5353']
with open('$YAML', 'w') as f: yaml.dump(d, f)
"
    /opt/AdGuardHome/AdGuardHome -s restart 2>&1 | tail -2
    echo "DNS now via Tor"
    ;;
  off)
    python3 -c "
import yaml
with open('$YAML') as f: d = yaml.safe_load(f)
d['dns']['upstream_dns'] = ['127.0.0.1:5335']
with open('$YAML', 'w') as f: yaml.dump(d, f)
"
    /opt/AdGuardHome/AdGuardHome -s restart 2>&1 | tail -2
    echo "DNS via Unbound (default)"
    ;;
  status)
    grep -A1 "upstream_dns:" "$YAML" | tail -1
    ;;
  *) echo "usage: $0 on|off|status"; exit 2 ;;
esac
