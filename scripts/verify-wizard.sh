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
echo "==> Wizard verification"
echo
report "wizard route returns 404 after setup" "curl -k -s -o /dev/null -w '%{http_code}' $BASE_URL/setup/welcome" "^404$"
report "/ redirects to /login (setup complete)" "curl -k -s -o /dev/null -w '%{http_code}' $BASE_URL/" "^302$"
report "setup_complete=true in DB" "pi_ssh '
sudo -u privacypi /opt/privacypi/venv/bin/python -c \"
import sys; sys.path.insert(0, \\\"/opt/privacypi/app\\\")
from privacypi_app import create_app
from privacypi_app.extensions import db
from privacypi_app.models import Setting
app = create_app()
with app.app_context():
    s = db.session.get(Setting, \\\"setup_complete\\\")
    print(s.value if s else \\\"missing\\\")
\"'" "^true$"
report "profile setting was saved" "pi_ssh '
sudo -u privacypi /opt/privacypi/venv/bin/python -c \"
import sys; sys.path.insert(0, \\\"/opt/privacypi/app\\\")
from privacypi_app import create_app
from privacypi_app.extensions import db
from privacypi_app.models import Setting
app = create_app()
with app.app_context():
    s = db.session.get(Setting, \\\"profile\\\")
    print(s.value if s else \\\"missing\\\")
\"'" "^just-privacy$"
report "wizard.complete in audit log" "pi_ssh '
sudo -u privacypi /opt/privacypi/venv/bin/python -c \"
import sys; sys.path.insert(0, \\\"/opt/privacypi/app\\\")
from privacypi_app import create_app
from privacypi_app.extensions import db
from privacypi_app.models import AuditLog
app = create_app()
with app.app_context():
    rows = db.session.query(AuditLog).filter_by(action=\\\"wizard.complete\\\").count()
    print(rows)
\"'" "^[1-9]"
echo
echo "==> Result: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
