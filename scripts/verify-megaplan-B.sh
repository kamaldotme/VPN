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

echo "==> Megaplan B — Operations"
echo
echo "[ Apprise alerts ]"
report "AlertConfig table exists" "pi_ssh '
sudo -u privacypi /opt/privacypi/venv/bin/python -c \"
import sys; sys.path.insert(0, \\\"/opt/privacypi/app\\\")
from privacypi_app import create_app
from privacypi_app.extensions import db
from privacypi_app.models import AlertConfig
app = create_app()
with app.app_context(): print(\\\"ok\\\")
\"'" "^ok$"
report "/alerts page renders" "curl -k -s -o /dev/null -w '%{http_code}' $BASE_URL/alerts" "^(200|302)$"

echo "[ Speed test ]"
report "speedtest-cli installed" "pi_ssh 'which speedtest-cli'" "/usr/bin/speedtest-cli"
report "speedtest.sh executable" "pi_ssh 'test -x /opt/privacypi/scripts/speedtest.sh && echo OK'" "^OK$"
report "SpeedTestResult table exists" "pi_ssh '
sudo -u privacypi /opt/privacypi/venv/bin/python -c \"
import sys; sys.path.insert(0, \\\"/opt/privacypi/app\\\")
from privacypi_app import create_app
from privacypi_app.extensions import db
from privacypi_app.models import SpeedTestResult
app = create_app()
with app.app_context(): print(\\\"ok\\\")
\"'" "^ok$"

echo "[ Self-update ]"
report "self-update.sh executable" "pi_ssh 'test -x /opt/privacypi/scripts/self-update.sh && echo OK'" "^OK$"
report "self-update check returns JSON" "pi_ssh 'sudo /opt/privacypi/scripts/self-update.sh check' | python3 -c 'import json,sys; d=json.load(sys.stdin); print(\"service_started\" in d)'" "^True$"

echo "[ Page navigation ]"
report "alerts in sidebar" "curl -k -s $BASE_URL/login | grep -c 'app.css'" "^[1-9]"

echo "[ Sudoers valid ]"
report "sudoers config valid" "pi_ssh 'sudo visudo -c -f /etc/sudoers.d/privacypi'" "/etc/sudoers.d/privacypi: parsed OK"

echo
echo "==> Result: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
