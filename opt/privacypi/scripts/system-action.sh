#!/usr/bin/env bash
# Privileged system actions.
# Usage:
#   system-action.sh reboot | shutdown
#   system-action.sh restart-flask
#   system-action.sh factory-reset    # wipe everything, reboot into the setup wizard
set -euo pipefail
case "${1:-}" in
  reboot)   systemd-run --quiet --collect --on-active=3 systemctl reboot ;;
  # Safe power-off before unplugging (protects the SD card).
  shutdown) systemd-run --quiet --collect --on-active=3 systemctl poweroff ;;
  restart-flask) systemctl restart privacypi-flask.service ;;
  factory-reset)
    # Full wipe back to the out-of-box state, then reboot into the setup wizard.
    systemd-run --quiet --collect --on-active=2 /opt/privacypi/scripts/factory-reset.sh --reboot
    ;;
  *) echo "unknown action" >&2; exit 2 ;;
esac
