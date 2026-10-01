#!/usr/bin/env bash
# Verify the v2.1.0 privacy round (proxies UI, onion-admin, DoH, tether,
# WireGuard PSK, Unbound 2026 hardening, AdGuard 2026 lists, hnsd, Tor PTs).
# Exit 0 if all green; 1 otherwise. Prints a numbered checklist.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/lib/ssh-helpers.sh"

OK=0; FAIL=0
say()  { printf "%-60s " "$1"; }
pass() { OK=$((OK+1)); echo "✓"; }
fail() { FAIL=$((FAIL+1)); echo "✗   ${1:-}"; }

run_pi() { pi_ssh "$1" 2>&1; }

# ---- Filesystem / scripts ----
say "1. proxy-write.sh on Pi"
run_pi 'test -x /opt/privacypi/scripts/proxy-write.sh' >/dev/null && pass || fail
say "2. proxy-test.sh on Pi"
run_pi 'test -x /opt/privacypi/scripts/proxy-test.sh' >/dev/null && pass || fail
say "3. onion-admin.sh on Pi"
run_pi 'test -x /opt/privacypi/scripts/onion-admin.sh' >/dev/null && pass || fail
say "4. doh-server.sh on Pi"
run_pi 'test -x /opt/privacypi/scripts/doh-server.sh' >/dev/null && pass || fail
say "5. tether-wan.sh on Pi"
run_pi 'test -x /opt/privacypi/scripts/tether-wan.sh' >/dev/null && pass || fail

# ---- Sudoers ----
say "6. sudoers includes proxy-write"
run_pi 'sudo grep -q proxy-write.sh /etc/sudoers.d/privacypi' >/dev/null && pass || fail
say "7. sudoers includes onion-admin"
run_pi 'sudo grep -q onion-admin.sh /etc/sudoers.d/privacypi' >/dev/null && pass || fail
say "8. sudoers root:root 440"
run_pi 'sudo stat -c "%U:%G %a" /etc/sudoers.d/privacypi' | grep -q "root:root 440" && pass || fail
say "9. sudoers parses cleanly"
run_pi 'sudo visudo -cf /etc/sudoers.d/privacypi' | grep -q "parsed OK" && pass || fail

# ---- Master key ----
say "10. /etc/privacypi/master.key exists"
run_pi 'sudo test -s /etc/privacypi/master.key' >/dev/null && pass || fail
say "11. master.key 0640 root:privacypi"
run_pi 'sudo stat -c "%U:%G %a" /etc/privacypi/master.key' | grep -q "root:privacypi 640" && pass || fail
say "12. alert.secret exists"
run_pi 'sudo test -s /etc/privacypi/alert.secret' >/dev/null && pass || fail

# ---- DB schema ----
say "13. proxies table exists"
run_pi 'sudo -u privacypi /opt/privacypi/venv/bin/python -c "
import sys; sys.path.insert(0,\"/opt/privacypi/app\")
from privacypi_app import create_app
from privacypi_app.models import Proxy
from privacypi_app.extensions import db
app=create_app()
with app.app_context(): print(\"OK\" if Proxy.__tablename__ in db.metadata.tables else \"MISS\")"' \
  | grep -q OK && pass || fail
say "14. proxy_chains table exists"
run_pi 'sudo -u privacypi /opt/privacypi/venv/bin/python -c "
import sys; sys.path.insert(0,\"/opt/privacypi/app\")
from privacypi_app import create_app
from privacypi_app.models import ProxyChain
from privacypi_app.extensions import db
app=create_app()
with app.app_context(): print(\"OK\" if ProxyChain.__tablename__ in db.metadata.tables else \"MISS\")"' \
  | grep -q OK && pass || fail

# ---- Vault round-trip ----
say "15. master-key Fernet round-trip"
run_pi 'sudo -u privacypi /opt/privacypi/venv/bin/python -c "
import sys; sys.path.insert(0,\"/opt/privacypi/app\")
from privacypi_app import create_app
from privacypi_app.services.crypto import vault_encrypt, vault_decrypt
app=create_app()
with app.app_context():
  ct = vault_encrypt(\"hello\")
  print(\"OK\" if vault_decrypt(ct)==\"hello\" else \"BAD\")"' \
  | grep -q OK && pass || fail

# ---- Pluggable transports ----
say "16. obfs4proxy installed"
run_pi 'test -x /usr/bin/obfs4proxy' >/dev/null && pass || fail
say "17. snowflake-client installed"
run_pi 'test -x /usr/bin/snowflake-client' >/dev/null && pass || fail
say "18. webtunnel-client installed"
run_pi 'test -x /usr/local/bin/webtunnel-client' >/dev/null && pass || fail
say "19. torrc registers all 3 PTs"
run_pi 'sudo grep -c "^ClientTransportPlugin" /etc/tor/torrc' | grep -q '^3$' && pass || fail

# ---- Onion service ----
say "20. tor onion-admin reachable"
out=$(run_pi 'sudo /opt/privacypi/scripts/onion-admin.sh status')
echo "$out" | grep -q '"onion":"[a-z2-7]\{56\}\.onion"' && pass || fail "$out"
say "21. tor service active"
run_pi 'systemctl is-active tor' | grep -q active && pass || fail

# ---- WG PSK ----
say "22. wg-server.sh generates PSK"
run_pi 'grep -q "wg genpsk" /opt/privacypi/scripts/wg-server.sh' >/dev/null && pass || fail
say "23. wg-server.sh writes PresharedKey to client conf"
run_pi 'grep -q "PresharedKey = \\\$PEER_PSK" /opt/privacypi/scripts/wg-server.sh' >/dev/null && pass || fail

# ---- Unbound hardening ----
say "24. unbound qname-minimisation-strict"
run_pi 'sudo grep -q "qname-minimisation-strict: yes" /etc/unbound/unbound.conf.d/privacypi.conf' \
  >/dev/null && pass || fail
say "25. unbound rate-limit set"
run_pi 'sudo grep -q "ratelimit:" /etc/unbound/unbound.conf.d/privacypi.conf' >/dev/null && pass || fail
say "26. unbound harden-algo-downgrade"
run_pi 'sudo grep -q "harden-algo-downgrade: yes" /etc/unbound/unbound.conf.d/privacypi.conf' \
  >/dev/null && pass || fail
say "27. unbound active"
run_pi 'systemctl is-active unbound' | grep -q active && pass || fail

# ---- AdGuard 2026 lists ----
say "28. AdGuard has ≥10 enabled filters"
n=$(run_pi 'sudo grep -c "^  - enabled: true" /opt/AdGuardHome/AdGuardHome.yaml' | tr -d '[:space:]')
[[ "$n" =~ ^[0-9]+$ ]] && [[ $n -ge 10 ]] && pass || fail "got $n"
say "29. HaGeZi TIF list configured"
run_pi 'sudo grep -q "tif.txt" /opt/AdGuardHome/AdGuardHome.yaml' >/dev/null && pass || fail
say "30. HaGeZi DoH/VPN/Proxy bypass list"
run_pi 'sudo grep -q "doh-vpn-proxy-bypass" /opt/AdGuardHome/AdGuardHome.yaml' >/dev/null && pass || fail
say "31. HaGeZi NRD-30day list"
run_pi 'sudo grep -q "nrd-30day" /opt/AdGuardHome/AdGuardHome.yaml' >/dev/null && pass || fail
say "32. AdGuard active"
run_pi 'systemctl is-active AdGuardHome' | grep -q active && pass || fail
say "33. hns zone routes to hnsd"
run_pi 'sudo grep -q "\[/hns/\]127.0.0.1:5350" /opt/AdGuardHome/AdGuardHome.yaml' >/dev/null && pass || fail

# ---- hnsd ----
say "34. hnsd binary installed"
run_pi 'test -x /usr/local/bin/hnsd' >/dev/null && pass || fail
say "35. hnsd systemd unit active"
run_pi 'systemctl is-active hnsd' | grep -q active && pass || fail
say "36. hnsd listening on 127.0.0.1:5350"
run_pi 'sudo ss -lnup | grep -q "127.0.0.1:5350"' >/dev/null && pass || fail

# ---- Flask routes ----
say "37. Flask active"
run_pi 'systemctl is-active privacypi-flask' | grep -q active && pass || fail
say "38. /proxies route registered"
run_pi 'curl -sk -o /dev/null -w %{http_code} https://127.0.0.1:8443/proxies' | grep -qE "(200|302)" && pass || fail
say "39. /api/proxies route registered"
run_pi 'curl -sk -o /dev/null -w %{http_code} https://127.0.0.1:8443/api/proxies' | grep -qE "(200|302)" && pass || fail
say "40. /api/onion-admin route registered"
run_pi 'curl -sk -o /dev/null -w %{http_code} https://127.0.0.1:8443/api/onion-admin' | grep -qE "(200|302)" && pass || fail
say "41. /api/doh route registered"
run_pi 'curl -sk -o /dev/null -w %{http_code} https://127.0.0.1:8443/api/doh' | grep -qE "(200|302)" && pass || fail
say "42. /api/tether-wan route registered"
run_pi 'curl -sk -o /dev/null -w %{http_code} https://127.0.0.1:8443/api/tether-wan' | grep -qE "(200|302)" && pass || fail

# ---- Hardening ----
say "43. ubuntu user locked"
run_pi 'sudo passwd -S ubuntu' | grep -q "^ubuntu L" && pass || fail
say "44. alert internal endpoint accepts good secret"
run_pi 'SECRET=$(sudo cat /etc/privacypi/alert.secret); curl -sk -o /dev/null -w %{http_code} -X POST -H "X-Internal-Secret: $SECRET" -d "message=verify" https://127.0.0.1:8443/api/alert/internal/verify.smoke' \
  | grep -q 200 && pass || fail
say "45. alert internal endpoint rejects bad secret"
run_pi 'curl -sk -o /dev/null -w %{http_code} -X POST -H "X-Internal-Secret: bad" -d "message=x" https://127.0.0.1:8443/api/alert/internal/verify.smoke' \
  | grep -q 401 && pass || fail

echo
echo "==========================================="
echo "  Verification: ${OK} passed / ${FAIL} failed"
echo "==========================================="
exit $((FAIL > 0 ? 1 : 0))
