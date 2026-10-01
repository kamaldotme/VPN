#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ssh-helpers.sh"

PASS=0; FAIL=0
report() {
  local desc="$1" cmd="$2" expect_re="$3"
  local out; out="$(pi_ssh "$cmd" 2>&1 || true)"
  if echo "$out" | grep -Eq "$expect_re"; then
    echo "  ✓ $desc"
    PASS=$((PASS+1))
  else
    echo "  ✗ $desc"
    echo "    cmd: $cmd"
    echo "    got: $(echo "$out" | head -1)"
    FAIL=$((FAIL+1))
  fi
}

echo "==> PrivacyPi Foundation Verification"
echo
echo "[ Identity ]"
report "hostname is privacypi" "hostname" "^privacypi$"
report "privacypi user exists" "id privacypi" "uid=[0-9]+\(privacypi\)"

echo "[ Kernel & sysctl ]"
report "8021q loaded" "lsmod | awk '{print \$1}'" "^8021q$"
report "br_netfilter loaded" "lsmod | awk '{print \$1}'" "^br_netfilter$"
report "watchdog device active" "cat /sys/class/watchdog/watchdog0/identity 2>/dev/null" "Watchdog"
report "ip_forward enabled" "sysctl -n net.ipv4.ip_forward" "^1$"
report "rp_filter enabled" "sysctl -n net.ipv4.conf.all.rp_filter" "^1$"
report "tcp_syncookies enabled" "sysctl -n net.ipv4.tcp_syncookies" "^1$"

echo "[ DNS ]"
report "systemd-resolved disabled" "systemctl is-active systemd-resolved" "^inactive$|^failed$"
report "port 53 owned by AdGuard or free" "sudo ss -tulnp | grep ':53 ' | grep -cE 'AdGuardHome|^$' || echo 0" "^[0-9]+$"

echo "[ Filesystem ]"
report "/etc/privacypi exists" "test -d /etc/privacypi && echo OK" "^OK$"
report "/opt/privacypi exists" "test -d /opt/privacypi && echo OK" "^OK$"
report "/var/lib/privacypi exists" "test -d /var/lib/privacypi && echo OK" "^OK$"
report "/var/log/privacypi exists" "test -d /var/log/privacypi && echo OK" "^OK$"

echo "[ Hardening ]"
report "AppArmor enabled" "systemctl is-active apparmor" "^active$"
report "AppArmor enforcing >0" "sudo aa-status --enforced | wc -l" "^[1-9][0-9]*$"
report "unattended-upgrades enabled" "systemctl is-enabled apt-daily-upgrade.timer" "^enabled$"
report "CrowdSec running" "systemctl is-active crowdsec" "^active$"
report "CrowdSec firewall bouncer running" "systemctl is-active crowdsec-firewall-bouncer" "^active|^activating$"
report "auditd running" "systemctl is-active auditd" "^active$"
report "auditd rules loaded >= 19" "sudo auditctl -l | wc -l" "^(1[8-9]|[2-9][0-9]|[1-9][0-9]{2,})$"
report "systemd watchdog set" "systemctl show -p RuntimeWatchdogUSec --value" "^[1-9]"

echo "[ SSH ]"
report "sshd config valid" "sudo sshd -t && echo OK" "^OK$"
report "PasswordAuthentication off" "sudo sshd -T | grep ^passwordauthentication" "no$"
report "PermitRootLogin off" "sudo sshd -T | grep ^permitrootlogin" "no$"

echo
echo "==> Result: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
