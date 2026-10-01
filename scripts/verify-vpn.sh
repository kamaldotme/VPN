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

echo "==> PrivacyPi VPN Layer Verification"
echo
echo "[ Packages ]"
report "openvpn binary" "openvpn --version 2>&1 | head -1" "^OpenVPN"
report "wireguard tools" "wg --version" "^wireguard-tools"

echo "[ Provider scaffolding ]"
for p in nordvpn expressvpn mullvad protonvpn ivpn surfshark airvpn custom-ovpn custom-wg; do
  report "/etc/privacypi/vpn/$p exists" "test -d /etc/privacypi/vpn/$p && echo OK" "^OK$"
done

echo "[ Switching scripts ]"
report "route-mode.sh executable" "test -x /opt/privacypi/scripts/route-mode.sh && echo OK" "^OK$"
report "vpn-status.sh executable" "test -x /opt/privacypi/scripts/vpn-status.sh && echo OK" "^OK$"
report "vpn-pre-up.sh executable" "test -x /opt/privacypi/scripts/vpn-pre-up.sh && echo OK" "^OK$"
report "vpn-post-down.sh executable" "test -x /opt/privacypi/scripts/vpn-post-down.sh && echo OK" "^OK$"

echo "[ Mode switching tests ]"
report "Switch to direct works" "sudo /opt/privacypi/scripts/route-mode.sh direct" "via eth0"
report "FWD-br-vlan10 has eth0 ACCEPT" "sudo iptables -L FWD-br-vlan10 -n -v" "ACCEPT.*eth0"
report "Switch to killswitch works" "sudo /opt/privacypi/scripts/route-mode.sh killswitch" "Routing mode: killswitch"
report "FWD-br-vlan10 has no out-iface ACCEPT" "sudo iptables -L FWD-br-vlan10 -n -v | grep -v ESTABLISHED | grep ACCEPT" "^$"

echo "[ State + systemd ]"
report "active-vpn state file exists" "test -f /var/lib/privacypi/active-vpn && echo OK" "^OK$"
report "vpn-up.service enabled" "systemctl is-enabled privacypi-vpn-up.service" "^enabled$"
report "vpn-update.timer active" "systemctl is-active privacypi-vpn-update.timer" "^active$"

echo "[ Restore direct after test ]"
pi_ssh 'sudo /opt/privacypi/scripts/route-mode.sh direct' >/dev/null
report "Final state is direct" "cat /var/lib/privacypi/active-vpn" "\"mode\":\"direct\""

echo
echo "==> Result: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
