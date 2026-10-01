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

echo "==> PrivacyPi Anonymity Networks Verification"
echo
echo "[ Packages ]"
report "tor binary" "tor --version 2>&1" "^Tor version"
report "obfs4proxy binary" "obfs4proxy --version 2>&1" "obfs4proxy"
report "i2pd binary" "which i2pd" "/i2pd$"
report "lokinet binary" "which lokinet" "/lokinet$"
report "yggdrasil binary" "which yggdrasil" "/yggdrasil$"

echo "[ Tor ]"
report "tor active" "systemctl is-active tor" "^active$"
report "Tor TransPort 9040" "sudo ss -tulnp | grep tor | grep ':9040'" ":9040"
report "Tor DNSPort 5353" "sudo ss -tulnp | grep tor | grep ':5353'" ":5353"
report "Tor ControlPort 9051" "sudo ss -tulnp | grep tor | grep ':9051'" ":9051"
report "Tor bootstrapped" "sudo grep 'Bootstrapped 100' /var/log/tor/notices.log 2>/dev/null | tail -1" "100%"

echo "[ Other anon networks installed (start tested but not enabled at boot) ]"
report "i2pd config exists" "test -f /etc/i2pd/i2pd.conf && echo OK" "^OK$"
report "lokinet config exists" "test -d /etc/loki || test -d /var/lib/lokinet && echo OK" "^OK$"
report "yggdrasil config exists" "sudo test -f /etc/yggdrasil/yggdrasil.conf && echo OK" "^OK$"

echo "[ route-mode.sh tor support ]"
report "route-mode.sh tor switches mode" "sudo /opt/privacypi/scripts/route-mode.sh tor && cat /var/lib/privacypi/active-vpn" "\"mode\":\"tor\""
report "Tor REDIRECT in NAT" "sudo iptables -t nat -L PREROUTING -n -v | grep REDIRECT" "redir ports 9040"
report "Restore direct" "sudo /opt/privacypi/scripts/route-mode.sh direct && cat /var/lib/privacypi/active-vpn" "\"mode\":\"direct\""

echo
echo "==> Result: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
