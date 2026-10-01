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
    echo "  ✗ $desc"; echo "    got: $(echo "$out" | head -1)"
    FAIL=$((FAIL+1))
  fi
}

echo "==> PrivacyPi Proxy Layer Verification"
echo
echo "[ Binaries ]"
report "shadowsocks-rust ssserver" "ssserver --version" "^shadowsocks "
report "shadowsocks-rust sslocal" "sslocal --version" "^shadowsocks "
report "xray-core" "xray version 2>&1 | head -1" "^Xray"
report "tun2socks" "/usr/local/bin/tun2socks --version 2>&1 | head -1" "tun2socks-"

echo "[ Scripts ]"
report "proxy-up.sh executable" "test -x /opt/privacypi/scripts/proxy-up.sh && echo OK" "^OK$"
report "proxy-down.sh executable" "test -x /opt/privacypi/scripts/proxy-down.sh && echo OK" "^OK$"

echo "[ Config dirs ]"
report "/etc/privacypi/proxy exists" "test -d /etc/privacypi/proxy && echo OK" "^OK$"
report "Xray service available" "systemctl list-unit-files xray.service" "xray.service"

echo "[ route-mode.sh proxy mode ]"
report "route-mode.sh proxy switches mode" "sudo /opt/privacypi/scripts/route-mode.sh proxy && cat /var/lib/privacypi/active-vpn" "\"mode\":\"proxy\""
report "Restore direct" "sudo /opt/privacypi/scripts/route-mode.sh direct && cat /var/lib/privacypi/active-vpn" "\"mode\":\"direct\""

echo
echo "==> Result: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
