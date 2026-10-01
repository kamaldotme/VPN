#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ssh-helpers.sh"

PASS=0; FAIL=0
report() {
  local desc="$1" cmd="$2" expect_re="$3"
  local out; out="$(pi_ssh "$cmd" 2>&1 || true)"
  if echo "$out" | grep -Eq "$expect_re"; then
    echo "  ✓ $desc"; PASS=$((PASS+1))
  else
    echo "  ✗ $desc"
    echo "    cmd: $cmd"; echo "    got: $(echo "$out" | head -1)"
    FAIL=$((FAIL+1))
  fi
}

echo "==> PrivacyPi DNS Stack Verification"
echo
echo "[ Services ]"
report "Unbound active" "systemctl is-active unbound" "^active$"
report "AdGuard Home running" "sudo /opt/AdGuardHome/AdGuardHome -s status" "running"
report "AdGuard listening 0.0.0.0:53" "sudo ss -tulnp | grep AdGuardHome | grep ':53 '" "AdGuardHome"
report "AdGuard web UI 0.0.0.0:3000" "sudo ss -tulnp | grep AdGuardHome | grep ':3000'" "AdGuardHome"
report "Unbound listening 127.0.0.1:5335" "sudo ss -tulnp | grep unbound | grep ':5335'" "unbound"

echo "[ Resolution ]"
report "Unbound resolves cloudflare.com" "dig +short @127.0.0.1 -p 5335 cloudflare.com" "^[0-9]+\."
report "Unbound DNSSEC ad flag" "dig +dnssec @127.0.0.1 -p 5335 cloudflare.com" "flags:.* ad;"
report "AdGuard resolves cloudflare.com via Unbound" "dig +short @127.0.0.1 cloudflare.com" "^[0-9]+\."
report "AdGuard from VLAN bridge resolves" "dig +short @10.10.10.1 cloudflare.com" "^[0-9]+\."

echo "[ Ad blocking ]"
report "doubleclick.net blocked" "dig +short @127.0.0.1 doubleclick.net" "^0\.0\.0\.0$|^$"
report "googleads.g.doubleclick.net blocked" "dig +short @127.0.0.1 googleads.g.doubleclick.net" "^0\.0\.0\.0$|^$"
report "google-analytics.com blocked" "dig +short @127.0.0.1 google-analytics.com" "^0\.0\.0\.0$|^$"
report "Filter rule count > 800k" "curl -s -u \"admin:\$(sudo sed -n 2p /etc/privacypi/adguard.creds)\" http://127.0.0.1:3000/control/filtering/status | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(f.get(\"rules_count\",0) for f in d.get(\"filters\",[])))'" "^[8-9][0-9]{5}$|^[1-9][0-9]{6,}$"

echo "[ DNS leak protection ]"
report "iptables DNAT redirects port 53 (vlan10)" "sudo iptables -t nat -L PREROUTING -n -v | grep br-vlan10 | head -1" "DNAT"

echo
echo "==> Result: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
