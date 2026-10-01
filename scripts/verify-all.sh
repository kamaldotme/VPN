#!/usr/bin/env bash
# Comprehensive PrivacyPi health check — covers everything from v2.0 to v2.5.
# Single command, green/red report. Exit 0 if all pass, 1 if any fail.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/lib/ssh-helpers.sh"

PASS=0; FAIL=0; SKIP=0
say()  { printf "%-70s " "$1"; }
ok()   { PASS=$((PASS+1)); echo "✓"; }
no()   { FAIL=$((FAIL+1)); echo "✗   ${1:-}"; }
skip() { SKIP=$((SKIP+1)); echo "—   ${1:-skipped}"; }
section() { echo; echo "=== $1 ==="; }
runp() { pi_ssh "$1" 2>&1; }

# ---------- 1. Foundation ----------
section "Foundation (Pi reachable, services healthy)"
say "1. Pi SSH reachable"; runp "echo ok" | grep -q ok && ok || no
for s in privacypi-flask caddy AdGuardHome unbound tor hnsd avahi-daemon hostapd dnsmasq chrony privacypi-domain-router crowdsec auditd; do
  say "$s active"
  runp "systemctl is-active $s 2>/dev/null" | grep -q "^active$" && ok || no
done
say "load average sane (<3)"; runp 'awk "{print \$1}" /proc/loadavg' | awk '{exit ($1+0 < 3 ? 0 : 1)}' && ok || no
say "memory: free > 200MB"; runp 'free -m | awk "/^Mem:/{print \$7}"' | awk '{exit ($1+0 > 200 ? 0 : 1)}' && ok || no
say "CPU temp < 80°C"; runp 'cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null' | awk '{exit ($1/1000 < 80 ? 0 : 1)}' && ok || no

# ---------- 2. TLS frontend ----------
section "TLS frontend (Caddy + internal CA)"
say "Caddy listening on :443"; runp 'sudo ss -lntp | grep -q ":443 "' >/dev/null && ok || no
say "Caddy listening on :80"; runp 'sudo ss -lntp | grep -q ":80 "' >/dev/null && ok || no
say "Flask on loopback only (127.0.0.1:8443)"
runp 'sudo ss -lntp | awk "/:8443/{print \$4}"' | grep -q "127.0.0.1" && ok || no
say "root.crt present"; runp 'sudo test -s /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt' >/dev/null && ok || no
say "/pi-root.crt downloads OK"
curl -sk -o /dev/null -w "%{http_code}" https://$PI_HOST/pi-root.crt | grep -q 200 && ok || no
say "TLS chain verifies (system trust)"
curl -s -o /dev/null -w "%{ssl_verify_result}" https://$PI_HOST/login | grep -q "^0$" && ok || no
say "mDNS publishes privacypi.local"
runp 'avahi-resolve -n privacypi.local 2>&1' | grep -q "192.168" && ok || no

# ---------- 3. DNS chain ----------
section "DNS chain (AdGuard → Unbound + hnsd)"
say "AdGuard answers cloudflare.com"
runp 'dig @127.0.0.1 cloudflare.com +short +time=2 +tries=1 | head -1' | grep -qE "^[0-9]" && ok || no
say "Unbound recursive resolver up"
runp 'sudo ss -lnup | grep -q "127.0.0.1:5335"' >/dev/null && ok || no
say "hnsd listens on :5350"; runp 'sudo ss -lnup | grep -q "127.0.0.1:5350"' >/dev/null && ok || no
say "AdGuard forwards .hns zone"
runp 'sudo grep -q "\[/hns/\]127.0.0.1:5350" /opt/AdGuardHome/AdGuardHome.yaml' >/dev/null && ok || no
say "AdGuard ≥10 filter lists enabled"
n=$(runp 'sudo grep -c "^  - enabled: true" /opt/AdGuardHome/AdGuardHome.yaml' | tr -d '[:space:]')
[[ "${n:-0}" -ge 10 ]] && ok || no "got $n"

# ---------- 4. DNS / NTP / DoH containment ----------
section "Containment (force LAN through filter chain)"
say "DNS-trap chain installed"
runp 'sudo iptables -t nat -L PRIVACYPI_DNSTRAP -n 2>/dev/null | grep -q DNAT' >/dev/null && ok || no
say "NTP-trap chain installed"
runp 'sudo iptables -t nat -L PRIVACYPI_NTPTRAP -n 2>/dev/null | grep -q DNAT' >/dev/null && ok || no
say "DoH-block chain rejects Cloudflare"
runp 'sudo iptables -L PRIVACYPI_DOHBLOCK -n 2>/dev/null | grep -q "1.1.1.1"' >/dev/null && ok || no
say "chrony serves LAN as NTP"; runp 'sudo grep -q "^allow 10" /etc/chrony/conf.d/privacypi.conf' >/dev/null && ok || no

# ---------- 5. RF / WiFi crypto ----------
section "WiFi (AP hardening)"
say "hostapd active"; runp 'systemctl is-active hostapd' | grep -q active && ok || no
say "wpa_key_mgmt includes SAE"
runp 'sudo grep -E "^wpa_key_mgmt=" /etc/hostapd/hostapd.conf' | grep -q "SAE" && ok || no
say "ap_isolate=1"
runp 'sudo grep -E "^ap_isolate=" /etc/hostapd/hostapd.conf' | grep -q "=1" && ok || no
say "sae_require_mfp=1"
runp 'sudo grep -E "^sae_require_mfp=" /etc/hostapd/hostapd.conf' | grep -q "=1" && ok || no

# ---------- 6. Tor & pluggable transports ----------
section "Tor (transparent + bridges + onion services)"
say "tor active"; runp 'systemctl is-active tor' | grep -q active && ok || no
say "TransPort 9040 listening"; runp 'sudo ss -lntp | grep -q ":9040"' >/dev/null && ok || no
say "DNSPort 5353 listening"; runp 'sudo ss -lnup | grep -q ":5353"' >/dev/null && ok || no
say "ControlPort 9051 listening"; runp 'sudo ss -lntp | grep -q ":9051"' >/dev/null && ok || no
for pt in obfs4proxy snowflake-client webtunnel-client; do
  say "$pt installed"
  runp "command -v $pt 2>/dev/null || test -x /usr/local/bin/$pt" >/dev/null && ok || no
done
say "torrc registers all 3 PTs"
runp 'sudo grep -c "^ClientTransportPlugin" /etc/tor/torrc' | grep -q "^3$" && ok || no
say "Admin onion service has hostname"
runp 'sudo test -s /var/lib/tor/privacypi-admin/hostname' >/dev/null && ok || no
say "SSH onion service has hostname"
runp 'sudo test -s /var/lib/tor/privacypi-ssh/hostname' >/dev/null && ok || no
say "tor circuits API returns JSON"
runp 'sudo /opt/privacypi/scripts/tor-circuits.sh' | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null && ok || no

# ---------- 7. WireGuard ----------
section "WireGuard (travel, PSK)"
say "wg-server.sh installed"; runp 'test -x /opt/privacypi/scripts/wg-server.sh' >/dev/null && ok || no
say "wg-server.sh generates PSK"
runp 'grep -q "wg genpsk" /opt/privacypi/scripts/wg-server.sh' >/dev/null && ok || no
say "wg-server.sh writes PresharedKey"
runp 'grep -q "PresharedKey = \\\$PEER_PSK" /opt/privacypi/scripts/wg-server.sh' >/dev/null && ok || no
say "wstunnel binary installed"
runp 'test -x /usr/local/bin/wstunnel' >/dev/null && ok || no

# ---------- 8. Crypto / vault ----------
section "Vault (master.key + Fernet)"
say "/etc/privacypi/master.key 0640 root:privacypi"
runp 'sudo stat -c "%U:%G %a" /etc/privacypi/master.key 2>/dev/null' | grep -q "root:privacypi 640" && ok || no
say "Fernet round-trip succeeds"
runp 'sudo -u privacypi /opt/privacypi/venv/bin/python -c "
import sys; sys.path.insert(0,\"/opt/privacypi/app\")
from privacypi_app import create_app
from privacypi_app.services.crypto import vault_encrypt, vault_decrypt
app=create_app()
with app.app_context():
  print(\"OK\" if vault_decrypt(vault_encrypt(\"x\"))==\"x\" else \"NO\")"' | grep -q OK && ok || no
say "BIP-39 mnemonic export round-trip"
runp 'sudo -u privacypi /opt/privacypi/venv/bin/python -c "
import sys; sys.path.insert(0,\"/opt/privacypi/app\")
from privacypi_app import create_app
from privacypi_app.services.recovery import export_mnemonic
app=create_app()
with app.app_context():
  m = export_mnemonic()
  print(\"OK\" if len(m.split())==24 else \"NO\")"' | grep -q OK && ok || no

# ---------- 9. Audit chain ----------
section "Audit log integrity (HMAC chain)"
say "audit_log has prev_hash + row_hash columns"
runp 'sudo -u privacypi /opt/privacypi/venv/bin/python -c "
import sys; sys.path.insert(0,\"/opt/privacypi/app\")
from sqlalchemy import text
from privacypi_app import create_app
from privacypi_app.extensions import db
app=create_app()
with app.app_context():
  cols = [r[1] for r in db.session.execute(text(\"PRAGMA table_info(audit_log)\")).fetchall()]
  print(\"OK\" if \"prev_hash\" in cols and \"row_hash\" in cols else \"NO\")"' | grep -q OK && ok || no
say "Chain verifies clean across all rows"
runp 'sudo -u privacypi /opt/privacypi/venv/bin/python -c "
import sys; sys.path.insert(0,\"/opt/privacypi/app\")
from privacypi_app import create_app
from privacypi_app.models import AuditLog
from privacypi_app.extensions import db
from privacypi_app.services.audit_chain import verify_chain
app=create_app()
with app.app_context():
  rows = db.session.query(AuditLog).order_by(AuditLog.id.asc()).all()
  ok, bad, n = verify_chain(rows)
  print(f\"OK n={n}\" if ok else f\"FAIL bad_id={bad}\")"' | grep -q OK && ok || no

# ---------- 10. New tables / model ----------
section "Schema (v2.0–v2.4 tables present)"
for t in users settings audit_log alert_configs speedtest_results proxies proxy_chains login_attempts webauthn_credentials domain_routes; do
  say "table $t exists"
  runp "sudo -u privacypi /opt/privacypi/venv/bin/python -c \"
import sys; sys.path.insert(0,'/opt/privacypi/app')
from sqlalchemy import text
from privacypi_app import create_app
from privacypi_app.extensions import db
app=create_app()
with app.app_context():
  r = db.session.execute(text(\\\"SELECT name FROM sqlite_master WHERE type='table' AND name='$t'\\\")).fetchone()
  print('OK' if r else 'NO')
\"" | grep -q OK && ok || no
done

# ---------- 11. HTTP routes ----------
section "Public routes reachable"
for ep in /login /trust /privacy /advanced /proxies /tor /vpn /devices /modes /dns /backup /alerts /audit /anomalies /diagnostics /system /pi-root.crt; do
  say "GET $ep"
  c=$(curl -sk -o /dev/null -w "%{http_code}" "https://$PI_HOST$ep")
  case "$c" in 200|302) ok ;; *) no "got $c" ;; esac
done

# ---------- 12. API routes ----------
section "API routes registered (302 unauth or 200 = OK)"
for ep in /api/dns/recent /api/audit/verify /api/onion-admin /api/onion-ssh /api/wstunnel \
          /api/tor/circuits /api/domain-routes /api/lockout /api/webauthn/credentials \
          /api/dns-trap /api/ntp-trap /api/ap-harden /api/captive-portal /api/tls/status \
          /api/proxies /api/tether-wan /api/doh /api/mac-traffic; do
  say "GET $ep"
  c=$(curl -sk -o /dev/null -w "%{http_code}" "https://$PI_HOST$ep")
  case "$c" in 200|302) ok ;; *) no "got $c" ;; esac
done

# ---------- 13. Hardening ----------
section "Hardening"
say "ubuntu fallback user locked"
runp 'sudo passwd -S ubuntu' | grep -q "^ubuntu L" && ok || no
say "alert.secret present"; runp 'sudo test -s /etc/privacypi/alert.secret' >/dev/null && ok || no
say "alert internal endpoint accepts good secret"
SECRET=$(runp 'sudo cat /etc/privacypi/alert.secret' | head -1)
c=$(runp "curl -sk -o /dev/null -w %{http_code} -X POST -H 'X-Internal-Secret: $SECRET' -d 'message=verify' https://127.0.0.1:8443/api/alert/internal/verify.smoke")
[[ "$c" = "200" ]] && ok || no "got $c"
say "alert internal endpoint rejects bad secret"
c=$(runp "curl -sk -o /dev/null -w %{http_code} -X POST -H 'X-Internal-Secret: bad' -d 'message=x' https://127.0.0.1:8443/api/alert/internal/verify.smoke")
[[ "$c" = "401" ]] && ok || no "got $c"
say "sudoers root:root 440"
runp 'sudo stat -c "%U:%G %a" /etc/sudoers.d/privacypi' | grep -q "root:root 440" && ok || no
say "sudoers parses cleanly"
runp 'sudo visudo -cf /etc/sudoers.d/privacypi' | grep -q "parsed OK" && ok || no

# ---------- Summary ----------
echo
echo "==============================================================="
printf "  Verification: %d passed, %d failed, %d skipped\n" "$PASS" "$FAIL" "$SKIP"
echo "==============================================================="
exit $((FAIL > 0 ? 1 : 0))
