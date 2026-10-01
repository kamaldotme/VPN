#!/usr/bin/env bash
# Privileged system actions.
# Usage:
#   system-action.sh reboot
#   system-action.sh restart-flask
#   system-action.sh factory-reset    # nuclear: wipe DB and provider creds
set -euo pipefail
case "${1:-}" in
  reboot) shutdown -r +1 "PrivacyPi reboot from UI" ;;
  restart-flask) systemctl restart privacypi-flask.service ;;
  factory-reset)
    rm -f /var/lib/privacypi/privacypi.db
    rm -f /etc/privacypi/vpn/*/auth.txt
    rm -f /etc/privacypi/vpn/*/current.ovpn
    rm -rf /etc/privacypi/vpn/*/servers/*.ovpn
    systemctl restart privacypi-flask.service
    ;;
  *) echo "unknown action" >&2; exit 2 ;;
esac
