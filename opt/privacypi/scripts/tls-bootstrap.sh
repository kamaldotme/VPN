#!/usr/bin/env bash
# Set up Caddy as TLS frontend with internal CA, move Flask to HTTP-loopback.
# Idempotent — re-run to refresh.
#
# Usage:
#   tls-bootstrap.sh setup    # install everything
#   tls-bootstrap.sh status   # report current state
#   tls-bootstrap.sh teardown # roll back to direct gunicorn HTTPS on :8443
set -euo pipefail
source /opt/privacypi/scripts/lib/site.sh
ACTION="${1:-status}"

CADDYFILE_SRC=/opt/privacypi/system/etc/caddy/Caddyfile
CADDYFILE_DST=/etc/caddy/Caddyfile
DROPIN_DIR=/etc/systemd/system/privacypi-flask.service.d
DROPIN=$DROPIN_DIR/10-http-loopback.conf

setup() {
  # 1. Caddyfile
  install -d -m 755 /etc/caddy
  install -m 644 "$CADDYFILE_SRC" "$CADDYFILE_DST"

  # 2. Move Flask to plain HTTP on loopback. Caddy fronts TLS.
  mkdir -p "$DROPIN_DIR"
  cat > "$DROPIN" <<'UNIT'
[Service]
# Caddy on :443 terminates TLS and reverse-proxies to us on 127.0.0.1:8443.
# Loopback-only means no plaintext ever leaves the box.
Environment=PRIVACYPI_COOKIE_SECURE=1
ExecStart=
ExecStart=/opt/privacypi/venv/bin/gunicorn --bind 127.0.0.1:8443 \
  --forwarded-allow-ips=127.0.0.1 \
  --workers 2 --threads 4 wsgi:app
UNIT
  systemctl daemon-reload
  systemctl restart privacypi-flask

  # 3. Caddy
  systemctl enable --now caddy
  systemctl restart caddy
  sleep 3

  # 4. Sanity: did Caddy generate the root CA?
  ROOT=/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
  for i in 1 2 3 4 5; do
    [[ -f "$ROOT" ]] && break
    sleep 2
  done
  if [[ ! -f "$ROOT" ]]; then
    echo '{"ok":false,"error":"caddy root not generated"}'
    exit 1
  fi

  # 5. Report
  echo "{\"ok\":true,\"caddy\":\"$(systemctl is-active caddy)\",\"flask\":\"$(systemctl is-active privacypi-flask)\",\"root_ca\":\"$ROOT\",\"endpoint_lan\":\"https://${HOST_MDNS}/\",\"endpoint_ip\":\"https://${HOST_IP}/\"}"
}

teardown() {
  systemctl stop caddy 2>/dev/null || true
  systemctl disable caddy 2>/dev/null || true
  rm -f "$DROPIN"
  systemctl daemon-reload
  systemctl restart privacypi-flask
  echo '{"ok":true,"reverted":true}'
}

case "$ACTION" in
  setup)    setup ;;
  teardown) teardown ;;
  status)
    if systemctl is-active caddy >/dev/null 2>&1; then
      ROOT=/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
      ROOT_FP=""
      [[ -f "$ROOT" ]] && ROOT_FP=$(openssl x509 -in "$ROOT" -noout -fingerprint -sha256 | cut -d= -f2)
      echo "{\"ok\":true,\"caddy\":\"active\",\"root_fingerprint\":\"$ROOT_FP\"}"
    else
      echo '{"ok":true,"caddy":"inactive"}'
    fi
    ;;
  *) echo '{"ok":false,"error":"unknown action"}'; exit 2 ;;
esac
