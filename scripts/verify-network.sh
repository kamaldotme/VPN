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

echo "==> PrivacyPi Network Verification"
echo
echo "[ Bridges ]"
report "br-vlan10 has 10.10.10.1" "ip -4 addr show br-vlan10" "10\.10\.10\.1/24"

echo "[ Interfaces ]"
report "wlan1 in AP mode" "iw dev wlan1 info" "type AP"
report "wlan1 in br-vlan10" "bridge link show | grep wlan1" "master br-vlan10"
report "AP SSID = PrivacyPi" "iw dev wlan1 info" "ssid PrivacyPi"

echo "[ Services ]"
report "hostapd active" "systemctl is-active hostapd" "^active$"
report "dnsmasq active" "systemctl is-active dnsmasq" "^active$"
report "privacypi-firewall active" "systemctl is-active privacypi-firewall" "^active$"

echo "[ Firewall ]"
report "FORWARD policy DROP" "sudo iptables -L FORWARD -n | head -1" "policy DROP"
report "POSTROUTING masquerade on eth0" "sudo iptables -t nat -L POSTROUTING -n -v" "MASQUERADE.*eth0|.*eth0.*MASQUERADE"
report "DNS forced via DNAT" "sudo iptables -t nat -L PREROUTING -n -v | grep br-vlan10" "DNAT"
report "WebRTC port 3478 blocked" "sudo iptables -L FORWARD -n | grep dpt:3478" "DROP"
report "UPnP port 1900 blocked" "sudo iptables -L FORWARD -n | grep dpt:1900" "DROP"
report "FWD-br-vlan10 chain exists" "sudo iptables -L FWD-br-vlan10 -n" "Chain FWD-br-vlan10"

echo "[ Routing ]"
report "VLAN 10 table has default route" "ip route show table 100" "default via"
report "VLAN 10 source rule exists" "ip rule show" "from 10.10.10.0/24"

echo "[ DHCP ]"
report "dnsmasq listening on br-vlan10" "sudo ss -ulnp | grep dnsmasq" "br-vlan10:67"

echo "[ Kill switch ]"
report "killswitch.sh executable" "test -x /opt/privacypi/scripts/killswitch.sh && echo OK" "^OK$"

echo
echo "==> Result: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
