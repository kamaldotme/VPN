#!/usr/bin/env bash
# setup-finish.sh — called by the wizard's last step. Leaves setup mode, turns
# on the chosen routing mode and restarts the WiFi under the name/password the
# user picked. Runs detached a few seconds later so the "all done" page reaches
# the browser before the WiFi drops.
#
# Usage: setup-finish.sh <direct|tor>          (schedules itself)
#        setup-finish.sh --now <direct|tor>
set -uo pipefail
source /opt/privacypi/scripts/lib/site.sh
SCRIPTS=/opt/privacypi/scripts

if [[ "${1:-}" != "--now" ]]; then
  MODE="${1:-direct}"
  [[ "$MODE" == "direct" || "$MODE" == "tor" ]] || { echo '{"ok":false,"error":"bad mode"}'; exit 2; }
  touch "$SETUP_FLAG"
  systemd-run --quiet --collect --on-active=4 "$SCRIPTS/setup-finish.sh" --now "$MODE" >/dev/null 2>&1 \
    || { (sleep 4; "$SCRIPTS/setup-finish.sh" --now "$MODE") >/dev/null 2>&1 & }
  echo '{"ok":true}'
  exit 0
fi

MODE="${2:-direct}"
touch "$SETUP_FLAG"
"$SCRIPTS/setup-mode.sh" off
"$SCRIPTS/route-mode.sh" "$MODE" || "$SCRIPTS/route-mode.sh" direct || true
"$SCRIPTS/ap-config.sh" render
"$SCRIPTS/diag.sh" >/dev/null 2>&1 || true
sync
# Come up under the new WiFi name with a clean restart rather than restarting
# the access point in place: some WiFi drivers do not survive that.
[[ "${PRIVACYPI_NO_REBOOT:-0}" == "1" ]] && { systemctl restart hostapd 2>/dev/null; exit 0; }
systemctl reboot
