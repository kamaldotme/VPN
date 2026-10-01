#!/usr/bin/env bash
# Bring up SOCKS-via-tun chain. Reads /etc/privacypi/proxy/active.conf for the proxy.
# active.conf: PROXY_URL=<scheme://...> (e.g., ss://, vless://, trojan://, hysteria2://)
set -euo pipefail

CONF=/etc/privacypi/proxy/active.conf
if [[ ! -f "$CONF" ]]; then
  echo "no active proxy config at $CONF"; exit 1
fi
source "$CONF"
[[ -z "${PROXY_URL:-}" ]] && { echo "PROXY_URL not set in $CONF"; exit 1; }

# Step 1: Start xray with the URL (xray-uri-parse → config.json)
# For now: simple shadowsocks SOCKS via sslocal (xray more general; defer)
SCHEME="${PROXY_URL%%://*}"

case "$SCHEME" in
  socks5)
    # User supplied a SOCKS5 directly — just create a passthrough on 1080.
    # We tunnel via socat so kill-switch & tun2socks stay coherent.
    HOSTPORT="${PROXY_URL#socks5://*@}"
    HOSTPORT="${HOSTPORT##*@}"
    HOST="${HOSTPORT%%:*}"; PORT="${HOSTPORT##*:}"
    USERPASS="${PROXY_URL#socks5://}"; USERPASS="${USERPASS%@*}"
    if [[ "$USERPASS" == "$PROXY_URL" ]]; then USERPASS=""; fi
    # Use 3proxy or socat; use a tiny relay with redsocks if installed.
    # Simplest path: launch redsocks2 listening on 1080 → upstream SOCKS5.
    if command -v redsocks2 >/dev/null 2>&1; then
      cat > /tmp/redsocks-active.conf <<RS
base { log_debug=off; log_info=on; log = "stderr"; daemon = off; redirector = iptables; }
redsocks { local_ip = 127.0.0.1; local_port = 1080; ip = $HOST; port = $PORT; type = socks5; ${USERPASS:+login = "${USERPASS%%:*}"; password = "${USERPASS##*:}";} }
RS
      redsocks2 -c /tmp/redsocks-active.conf &>/var/log/privacypi/proxy.log &
    else
      # Fallback: ssh-style SOCKS forward via ssh master tunnel impossible here;
      # require redsocks2.
      echo "redsocks2 missing; install: apt-get install redsocks2" >&2
      exit 5
    fi
    echo $! > /run/privacypi-proxy.pid
    ;;
  ssh)
    # ssh://user@host:port — dynamic SOCKS over SSH. Key auth only.
    SSH_TARGET="${PROXY_URL#ssh://}"
    ssh -N -D 127.0.0.1:1080 -o StrictHostKeyChecking=accept-new \
        -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
        -o ExitOnForwardFailure=yes "$SSH_TARGET" \
        &>/var/log/privacypi/proxy.log &
    echo $! > /run/privacypi-proxy.pid
    ;;
  ss)
    sslocal -U "$PROXY_URL" -b 127.0.0.1:1080 &>/var/log/privacypi/proxy.log &
    echo $! > /run/privacypi-proxy.pid
    ;;
  vless|vmess|trojan|hysteria2)
    # Use xray with appropriate config (Plan 9 Flask UI generates config.json)
    xray run -config /etc/privacypi/proxy/xray-config.json &>/var/log/privacypi/proxy.log &
    echo $! > /run/privacypi-proxy.pid
    ;;
  *)
    echo "unsupported proxy scheme: $SCHEME"; exit 2 ;;
esac

sleep 2

# Step 2: Bring up tun0 and run tun2socks
ip tuntap add dev tun0 mode tun || true
ip addr add 198.18.0.1/15 dev tun0 || true
ip link set dev tun0 up

tun2socks -device tun0 -proxy socks5://127.0.0.1:1080 -loglevel warning &>/var/log/privacypi/tun2socks.log &
echo $! > /run/privacypi-tun2socks.pid

sleep 2
echo "Proxy chain up: tun0 → SOCKS5 1080 → $SCHEME"
