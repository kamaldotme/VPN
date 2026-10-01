#!/usr/bin/env bash
# SSH and rsync helpers for PrivacyPi deployment.
set -euo pipefail

PI_HOST_FILE="$HOME/.privacypi-host"
if [[ ! -s "$PI_HOST_FILE" ]]; then
  echo "ERROR: $PI_HOST_FILE missing or empty." >&2
  exit 1
fi
PI_HOST="$(tr -d '[:space:]' < "$PI_HOST_FILE")"
PI_USER="${PI_USER:-privacypi}"

pi_ssh() { ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes "${PI_USER}@${PI_HOST}" "$@"; }
pi_scp() { scp -o StrictHostKeyChecking=accept-new "$1" "${PI_USER}@${PI_HOST}:$2"; }
pi_rsync() {
  rsync -avz --rsync-path="sudo rsync" -e "ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes" "$1" "${PI_USER}@${PI_HOST}:$2"
}
pi_sudo() { pi_ssh "sudo bash -c '$*'"; }
