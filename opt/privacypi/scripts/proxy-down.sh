#!/usr/bin/env bash
# Tear down proxy chain.
set -uo pipefail
for pidfile in /run/privacypi-tun2socks.pid /run/privacypi-proxy.pid; do
  if [[ -f "$pidfile" ]]; then
    pid=$(cat "$pidfile")
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    rm -f "$pidfile"
  fi
done
ip link del tun0 2>/dev/null || true
echo "Proxy chain down"
