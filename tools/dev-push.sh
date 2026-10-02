#!/usr/bin/env bash
# dev-push.sh <pi-address> — copy this working tree to a running PrivacyPi over
# SSH and re-run the installer there (idempotent, ~1 minute). The fast loop:
# no image rebuild, no reflash. Needs SSH enabled on the device
# (ssh_password= in privacypi-config.txt) and the key ~/.ssh/privacypi_dev.
set -euo pipefail
HOST="${1:?usage: tools/dev-push.sh <pi-address>}"
cd "$(dirname "$0")/.."
SSH=(ssh -i ~/.ssh/privacypi_dev -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
rsync -az --delete -e "${SSH[*]}" --exclude build --exclude .git --exclude '.playwright-mcp' --exclude '*.png' \
  --exclude __pycache__ --exclude .claude --exclude 'CREDENTIALS.local.md' ./ "pi@$HOST:/tmp/privacypi-src/"
"${SSH[@]}" "pi@$HOST" 'sudo bash /tmp/privacypi-src/install.sh 2>&1 | grep -E "==>|!!|##" ; sudo systemctl daemon-reload; sudo systemctl restart privacypi-flask'
