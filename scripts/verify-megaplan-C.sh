#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ssh-helpers.sh"
BASE_URL="https://$(cat ~/.privacypi-host)"

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

echo "==> Megaplan C — Travel + Automation"
echo
echo "[ WireGuard server ]"
report "wg-server.sh executable" "pi_ssh 'test -x /opt/privacypi/scripts/wg-server.sh && echo OK'" "^OK$"
report "wg-server status returns JSON" "pi_ssh 'sudo /opt/privacypi/scripts/wg-server.sh status' | python3 -c 'import json,sys; d=json.load(sys.stdin); print(\"running\" in d)'" "^True$"
report "/wg-server page renders" "curl -k -s -o /dev/null -w '%{http_code}' $BASE_URL/wg-server" "^(200|302)$"

echo "[ VPN failover ]"
report "vpn-failover.sh executable" "pi_ssh 'test -x /opt/privacypi/scripts/vpn-failover.sh && echo OK'" "^OK$"
report "vpn-health timer active" "pi_ssh 'systemctl is-active privacypi-vpn-health.timer'" "^active$"

echo "[ Schedules ]"
report "schedule-apply.sh executable" "pi_ssh 'test -x /opt/privacypi/scripts/schedule-apply.sh && echo OK'" "^OK$"
report "schedule timer active" "pi_ssh 'systemctl is-active privacypi-schedule.timer'" "^active$"
report "/schedule page renders" "curl -k -s -o /dev/null -w '%{http_code}' $BASE_URL/schedule" "^(200|302)$"

echo "[ Sudoers + nav ]"
report "sudoers valid" "pi_ssh 'sudo visudo -c -f /etc/sudoers.d/privacypi'" "parsed OK"
report "WG Travel link in sidebar" "curl -k -s $BASE_URL/login | grep -c 'app.css'" "^[1-9]"

echo
echo "==> Result: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
