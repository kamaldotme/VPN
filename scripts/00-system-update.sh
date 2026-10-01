#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ssh-helpers.sh"
echo "==> apt update"
pi_ssh 'sudo apt-get update -y'
echo "==> upgrade"
pi_ssh 'sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y'
echo "==> autoremove"
pi_ssh 'sudo apt-get autoremove -y'
echo "==> Done"
