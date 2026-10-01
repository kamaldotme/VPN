#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ssh-helpers.sh"
PASS=0; FAIL=0
report() {
  local desc="$1" cmd="$2" expect_re="$3"
  local out; out="$(eval "$cmd" 2>&1 || true)"
  if echo "$out" | grep -Eq "$expect_re"; then
    echo "  ✓ $desc"; PASS=$((PASS+1))
  else
    echo "  ✗ $desc"; echo "    got: $(echo "$out" | head -1)"
    FAIL=$((FAIL+1))
  fi
}
echo "==> Megaplan A — Network Visibility"
echo
report "vnstat installed" "pi_ssh 'vnstat --version | head -1'" "^vnStat"
report "vnstat tracking br-vlan10" "pi_ssh 'vnstat -i br-vlan10 --json | python3 -c \"import json,sys; d=json.load(sys.stdin); print(d.get(\\\"interfaces\\\",[{}])[0].get(\\\"name\\\",\\\"\\\"))\"'" "^br-vlan10$"
report "list-clients.sh executable" "pi_ssh 'test -x /opt/privacypi/scripts/list-clients.sh && echo OK'" "^OK$"
report "device-route.sh executable" "pi_ssh 'test -x /opt/privacypi/scripts/device-route.sh && echo OK'" "^OK$"
report "list-clients.sh returns valid JSON" "pi_ssh 'sudo /opt/privacypi/scripts/list-clients.sh' | python3 -c 'import json,sys; d=json.load(sys.stdin); print(\"timestamp\" in d and \"clients\" in d)'" "^True$"
report "device-route.sh list returns valid JSON" "pi_ssh 'sudo /opt/privacypi/scripts/device-route.sh list' | python3 -c 'import json,sys; d=json.load(sys.stdin); print(\"overrides\" in d)'" "^True$"
report "ipsets created" "pi_ssh 'sudo ipset list privacypi-direct | head -1'" "^Name: privacypi-direct"
report "/devices page renders" "curl -k -s -o /dev/null -w '%{http_code}' https://$PI_HOST/devices" "^(302|200)$"
report "Modern UI loaded (app.css)" "curl -k -s https://$PI_HOST/login | grep -c app.css" "^[1-9]"
report "Inter font loaded" "curl -k -s https://$PI_HOST/login | grep -c Inter" "^[1-9]"
echo
echo "==> Result: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
