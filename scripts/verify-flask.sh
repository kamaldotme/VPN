#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ssh-helpers.sh"

BASE_URL="https://$(cat ~/.privacypi-host)"
: "${PRIVACYPI_ADMIN_PASS:?export PRIVACYPI_ADMIN_PASS (admin UI password)}"

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

echo "==> PrivacyPi Flask App Verification"
echo
echo "[ Service ]"
report "Flask service active" "pi_ssh 'systemctl is-active privacypi-flask'" "^active$"
report "Flask listening 8443" "pi_ssh 'sudo ss -tulnp | grep :8443'" "gunicorn"
report "HTTPS responds with 200 on /login" "curl -k -s -o /dev/null -w '%{http_code}' $BASE_URL/login" "^200$"

echo "[ Auth flow ]"
report "Bad password rejected (200 stays on login)" "python3 -c \"
import urllib3, requests, re; urllib3.disable_warnings()
s=requests.Session(); s.verify=False
csrf=re.search(r'csrf_token\\\" value=\\\"([^\\\"]+)\\\"', s.get('$BASE_URL/login').text).group(1)
r=s.post('$BASE_URL/login', data={'csrf_token':csrf,'username':'admin','password':'wrong'}, headers={'Referer':'$BASE_URL/'}, allow_redirects=False)
print(r.status_code)\
\"" "^200$"
report "Good password redirects to /2fa (TOTP enabled)" "python3 -c \"
import urllib3, requests, re; urllib3.disable_warnings()
s=requests.Session(); s.verify=False
csrf=re.search(r'csrf_token\\\" value=\\\"([^\\\"]+)\\\"', s.get('$BASE_URL/login').text).group(1)
r=s.post('$BASE_URL/login', data={'csrf_token':csrf,'username':'admin','password':'$PRIVACYPI_ADMIN_PASS'}, headers={'Referer':'$BASE_URL/'}, allow_redirects=False)
print(f'{r.status_code} {r.headers.get(chr(76)+chr(111)+chr(99)+chr(97)+chr(116)+chr(105)+chr(111)+chr(110),\\\"\\\")}')\
\"" "^302 /2fa$"

echo "[ Audit log ]"
report "Audit log has rows" "pi_ssh '
sudo -u privacypi /opt/privacypi/venv/bin/python -c \"
import sys; sys.path.insert(0, \\\"/opt/privacypi/app\\\")
from privacypi_app import create_app
from privacypi_app.extensions import db
from privacypi_app.models import AuditLog
app = create_app()
with app.app_context(): print(db.session.query(AuditLog).count())
\"'" "^[1-9][0-9]*$"

echo "[ Sandboxing ]"
report "Flask runs as privacypi user" "pi_ssh 'systemctl show privacypi-flask -p User --value'" "^privacypi$"
report "Self-signed cert exists" "pi_ssh 'sudo test -f /etc/ssl/privacypi/cert.pem && echo OK'" "^OK$"
report "TOTP enabled for admin" "pi_ssh '
sudo -u privacypi /opt/privacypi/venv/bin/python -c \"
import sys; sys.path.insert(0, \\\"/opt/privacypi/app\\\")
from privacypi_app import create_app
from privacypi_app.extensions import db
from privacypi_app.models import User
app = create_app()
with app.app_context():
    u = db.session.query(User).filter_by(username=\\\"admin\\\").first()
    print(\\\"yes\\\" if u and u.totp_enabled else \\\"no\\\")
\"'" "^yes$"

echo
echo "==> Result: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
