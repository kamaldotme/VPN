#!/usr/bin/env bash
# Manage a local DoH server that fronts AdGuard's DNS for WG clients.
# When a phone is connected via WG (10.20.0.0/24) it can use
#   https://10.20.0.1/dns-query   (DoH3 / DoH/2)
# So even when the phone is roaming, DNS is encrypted and routed through
# our filter chain (AdGuard → Unbound/hnsd).
#
# Implementation: caddy + adguard's plain :53. Caddy is tiny and supports
# DoH out of the box (forward_proxy or builtin).
#
# Usage:
#   doh-server.sh enable
#   doh-server.sh disable
#   doh-server.sh status
set -euo pipefail
source /opt/privacypi/scripts/lib/site.sh
ACTION="${1:-status}"
CADDYFILE=/etc/privacypi/Caddyfile.doh
SERVICE=/etc/systemd/system/privacypi-doh.service

write_caddyfile() {
  cat > "$CADDYFILE" <<CFG
{
  auto_https off
  servers {
    protocols h1 h2 h3
  }
}

# Listen on the WG interface only ($WG_GW) — never on the WAN.
https://$WG_GW:443 {
  tls internal
  route /dns-query {
    forward_proxy_or_dns_to 127.0.0.1:53
    @doh path /dns-query
    handle @doh {
      reverse_proxy h2c://127.0.0.1:53 {
        header_up Host {host}
      }
    }
  }
  respond /healthz "ok" 200
}
CFG
}

write_unit() {
  cat > "$SERVICE" <<UNIT
[Unit]
Description=PrivacyPi DoH front (Caddy → AdGuard)
After=network-online.target AdGuardHome.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/caddy run --config /etc/privacypi/Caddyfile.doh --adapter caddyfile
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/caddy /etc/privacypi
DynamicUser=true

[Install]
WantedBy=multi-user.target
UNIT
}

case "$ACTION" in
  enable)
    if ! command -v caddy >/dev/null 2>&1; then
      # Lightweight: install caddy from apt (Debian/Ubuntu)
      DEBIAN_FRONTEND=noninteractive apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl >/dev/null 2>&1 || true
      curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key 2>/dev/null | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null || true
      echo 'deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main' > /etc/apt/sources.list.d/caddy-stable.list
      apt-get update -qq 2>/dev/null
      DEBIAN_FRONTEND=noninteractive apt-get install -y caddy 2>&1 | tail -3
    fi
    mkdir -p /etc/privacypi
    write_caddyfile
    write_unit
    systemctl daemon-reload
    systemctl enable --now privacypi-doh
    sleep 2
    systemctl is-active privacypi-doh && echo "{\"ok\":true,\"status\":\"active\",\"endpoint\":\"https://$WG_GW/dns-query\"}"
    ;;
  disable)
    systemctl disable --now privacypi-doh 2>/dev/null || true
    rm -f "$SERVICE"
    systemctl daemon-reload
    echo '{"ok":true,"status":"stopped"}'
    ;;
  status)
    if systemctl is-active privacypi-doh >/dev/null 2>&1; then
      echo "{\"ok\":true,\"status\":\"active\",\"endpoint\":\"https://$WG_GW/dns-query\"}"
    else
      echo '{"ok":true,"status":"inactive"}'
    fi
    ;;
  *) echo '{"ok":false,"error":"unknown action"}'; exit 2 ;;
esac
