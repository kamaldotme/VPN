#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ssh-helpers.sh"
PACKAGES=(
  git curl wget jq unzip ca-certificates gnupg lsb-release
  python3 python3-pip python3-venv python3-dev
  iproute2 iptables iptables-persistent ipset bridge-utils vlan
  net-tools tcpdump dnsutils ethtool wireless-tools iw
  sqlite3 rsync htop nano vim
  build-essential pkg-config libssl-dev
  apparmor apparmor-utils apparmor-profiles
  unattended-upgrades
  auditd audispd-plugins
  watchdog
)
pi_ssh 'sudo apt-get update -y'
pi_ssh "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ${PACKAGES[*]}"
echo "==> Done"
