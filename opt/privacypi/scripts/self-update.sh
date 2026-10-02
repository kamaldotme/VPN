#!/usr/bin/env bash
# Check or apply self-update from git.
# Usage: self-update.sh check | apply
set -uo pipefail
ACTION="${1:-check}"
REPO_DIR="${PRIVACYPI_REPO_DIR:-/opt/privacypi}"

# This script is meant to run on a Pi where the app was deployed FROM the Mac.
# In a self-hostable installation, REPO_DIR would be /opt/privacypi/repo and the
# Pi itself would have a git remote. For this deployment, we treat the Pi
# as "deployed from Mac" — self-update means "the Mac pushes a new build
# and runs migrations + restart".
#
# Safe alternative: check + apply local files only (assumes rsync from Mac
# already happened, just runs db migrations + restart).

case "$ACTION" in
  check)
    # Check if Flask app files have a newer mtime than systemd unit start time
    SVC_START=$(systemctl show -p ActiveEnterTimestamp --value privacypi-flask)
    SVC_EPOCH=$(date -d "$SVC_START" +%s 2>/dev/null || echo 0)
    APP_NEWEST=$(find /opt/privacypi/app -name "*.py" -newer /run/systemd/units/invocation:privacypi-flask.service -print 2>/dev/null | wc -l)
    cat <<JSON
{
  "service_started": "$SVC_START",
  "files_newer_than_service": $APP_NEWEST,
  "needs_restart": $([ "$APP_NEWEST" -gt 0 ] && echo true || echo false)
}
JSON
    ;;
  apply)
    # Run db migrations (if any), pip install requirements, restart Flask
    cd /opt/privacypi/app
    sudo -u privacypi /opt/privacypi/venv/bin/pip install --quiet -r requirements.txt 2>&1 | tail -3
    systemctl restart privacypi-flask
    sleep 2
    systemctl is-active privacypi-flask
    ;;
  *) echo "usage: $0 check|apply"; exit 2 ;;
esac
