#!/usr/bin/env bash
# Run a speed test, output JSON. Two different tools install a `speedtest`
# command: Ookla's CLI and the Python speedtest-cli (the one Debian ships) —
# they take different flags, so pick by what is actually installed.
set -uo pipefail
if command -v speedtest >/dev/null 2>&1 && speedtest --version 2>&1 | grep -qi ookla; then
  exec speedtest --accept-license --accept-gdpr -f json
fi
for bin in speedtest-cli speedtest; do
  if command -v "$bin" >/dev/null 2>&1; then
    exec "$bin" --json --secure
  fi
done
echo '{"error":"no speedtest tool installed"}'
