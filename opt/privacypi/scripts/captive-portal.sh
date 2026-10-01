#!/usr/bin/env bash
# Captive portal handling — auto-detect, pause killswitch during login,
# re-enable VPN after.
#
# A "captive portal" is the WiFi-login intercept page common at airports,
# coffee shops, hotels. Without special handling, our killswitch+DNS
# enforcement breaks the captive-portal flow entirely.
#
# Usage:
#   captive-portal.sh check      # JSON {present, type, url}
#   captive-portal.sh bypass     # temporarily relax: drop DNS-redirect, allow direct
#   captive-portal.sh restore    # re-engage full privacy chain
#   captive-portal.sh status     # current state
set -euo pipefail
ACTION="${1:-check}"
STATE=/run/privacypi-captive.state

is_present() {
  # gstatic.com/generate_204 returns 204 if no portal.
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 4 \
        --connect-timeout 2 \
        http://connectivitycheck.gstatic.com/generate_204 || echo "000")
  case "$CODE" in
    204) echo "no";;
    301|302|303|307|308|200) echo "yes";;
    *) echo "unreachable";;
  esac
}

portal_url() {
  curl -s -L -o /dev/null --max-time 4 -w "%{url_effective}" \
       http://connectivitycheck.gstatic.com/generate_204 2>/dev/null || echo ""
}

case "$ACTION" in
  check)
    P=$(is_present)
    URL=""
    [[ "$P" == "yes" ]] && URL=$(portal_url)
    echo "{\"present\":\"$P\",\"url\":\"$URL\"}"
    ;;
  bypass)
    # Save current state for restore
    iptables-save > "${STATE}.iptables"
    # Allow direct outbound for 30 minutes; drop DNS redirects
    iptables -t nat -F PREROUTING 2>/dev/null || true
    # Save policy
    echo "bypass:$(date +%s)" > "$STATE"
    # Schedule auto-restore after 30 min
    systemd-run --on-active=30min --unit=privacypi-captive-restore \
      /opt/privacypi/scripts/captive-portal.sh restore 2>/dev/null || true
    echo '{"ok":true,"bypass_seconds":1800}'
    ;;
  restore)
    if [[ -f "${STATE}.iptables" ]]; then
      iptables-restore < "${STATE}.iptables"
      rm -f "${STATE}.iptables"
    fi
    rm -f "$STATE"
    /opt/privacypi/scripts/route-mode.sh "$(cat /etc/privacypi/last-mode 2>/dev/null || echo direct)" >/dev/null 2>&1 || true
    echo '{"ok":true,"restored":true}'
    ;;
  status)
    if [[ -f "$STATE" ]]; then
      echo "{\"state\":\"$(cat $STATE)\"}"
    else
      P=$(is_present)
      echo "{\"state\":\"normal\",\"portal_present\":\"$P\"}"
    fi
    ;;
  *) echo '{"ok":false,"error":"unknown action"}'; exit 2 ;;
esac
