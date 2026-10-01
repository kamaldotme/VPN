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

echo "==> Megaplan D — Privacy Maximalist"
echo
echo "[ DNS-over-Tor ]"
report "tor-dns.sh executable" "pi_ssh 'test -x /opt/privacypi/scripts/tor-dns.sh && echo OK'" "^OK$"
report "tor-dns status returns" "pi_ssh 'sudo /opt/privacypi/scripts/tor-dns.sh status'" "."

echo "[ Tor bridges ]"
report "tor-bridges.sh executable" "pi_ssh 'test -x /opt/privacypi/scripts/tor-bridges.sh && echo OK'" "^OK$"
report "tor-bridges status returns JSON" "pi_ssh 'sudo /opt/privacypi/scripts/tor-bridges.sh status' | python3 -c 'import json,sys; print(\"bridges\" in json.load(sys.stdin))'" "^True$"

echo "[ MAC rotation ]"
report "rotate-mac.sh executable" "pi_ssh 'test -x /opt/privacypi/scripts/rotate-mac.sh && echo OK'" "^OK$"
report "MAC rotate timer active" "pi_ssh 'systemctl is-active privacypi-mac-rotate.timer'" "^active$"

echo "[ Anomaly detection (IsolationForest) ]"
report "anomaly-detect.py executable" "pi_ssh 'test -x /opt/privacypi/scripts/anomaly-detect.py && echo OK'" "^OK$"
report "scikit-learn importable" "pi_ssh '/opt/privacypi/venv/bin/python -c \"import sklearn; print(sklearn.__version__)\"'" "^[0-9]"
report "anomaly timer active" "pi_ssh 'systemctl is-active privacypi-anomaly.timer'" "^active$"
report "anomaly script runs" "pi_ssh 'sudo /opt/privacypi/scripts/anomaly-detect.py --window-minutes 60' | python3 -c 'import json,sys; print(\"queries_analyzed\" in json.load(sys.stdin))'" "^True$"

echo "[ UI ]"
report "/anomalies page renders" "curl -k -s -o /dev/null -w '%{http_code}' $BASE_URL/anomalies" "^(200|302)$"

echo "[ Sudoers + Flask ]"
report "sudoers valid" "pi_ssh 'sudo visudo -c -f /etc/sudoers.d/privacypi'" "parsed OK"
report "Flask still active" "pi_ssh 'systemctl is-active privacypi-flask'" "^active$"

echo
echo "==> Result: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
