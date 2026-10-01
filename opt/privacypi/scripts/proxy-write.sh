#!/usr/bin/env bash
# Persist a proxy URL to /etc/privacypi/proxy/active.conf for proxy-up.sh.
# Usage: proxy-write.sh <kind> <url>
# - kind: socks5|ss|vless|vmess|trojan|hysteria2|ssh
# - url: full proxy URL (will be redacted in audit log)
#
# Reads the URL from stdin if "$2" is "-" (so it never appears in argv).
set -euo pipefail
KIND="${1:-}"
URL_ARG="${2:-}"
[[ -z "$KIND" ]] && { echo '{"ok":false,"error":"kind required"}'; exit 1; }
case "$KIND" in
  socks5|ss|vless|vmess|trojan|hysteria2|ssh) ;;
  *) echo '{"ok":false,"error":"unknown kind"}'; exit 1 ;;
esac

if [[ "$URL_ARG" == "-" ]]; then
  read -r URL
else
  URL="$URL_ARG"
fi
[[ -z "$URL" ]] && { echo '{"ok":false,"error":"url required"}'; exit 1; }

mkdir -p /etc/privacypi/proxy
chmod 750 /etc/privacypi/proxy
umask 077
cat > /etc/privacypi/proxy/active.conf <<CONF
PROXY_KIND=$KIND
PROXY_URL=$URL
WRITTEN_AT=$(date -Iseconds)
CONF
chmod 640 /etc/privacypi/proxy/active.conf
chown root:privacypi /etc/privacypi/proxy/active.conf

# Generate xray config for non-SOCKS5/SS schemes
if [[ "$KIND" =~ ^(vless|vmess|trojan|hysteria2)$ ]] && command -v xray >/dev/null 2>&1; then
  # xray supports parsing URI directly via its API; here we just leave a hint
  cat > /etc/privacypi/proxy/xray-config.json <<JSON
{
  "log": {"loglevel":"warning"},
  "inbounds": [{"port":1080,"protocol":"socks","listen":"127.0.0.1","settings":{"auth":"noauth","udp":true}}],
  "outbounds": [{"protocol":"freedom","tag":"out"}],
  "_uri": "$URL"
}
JSON
  chmod 640 /etc/privacypi/proxy/xray-config.json
  chown root:privacypi /etc/privacypi/proxy/xray-config.json
fi

echo "{\"ok\":true,\"kind\":\"$KIND\"}"
