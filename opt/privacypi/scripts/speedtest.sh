#!/usr/bin/env bash
# Run speedtest-cli, output JSON.
set -euo pipefail
exec speedtest --accept-license --accept-gdpr -f json 2>&1 || \
  exec speedtest-cli --json 2>&1 || \
  echo '{"error":"no speedtest binary found"}'
