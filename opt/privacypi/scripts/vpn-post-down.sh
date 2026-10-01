#!/usr/bin/env bash
# Run by OpenVPN/wg-quick after tunnel goes down.
set -euo pipefail
# Kill switch: assume failure; require explicit Flask call to disarm.
/opt/privacypi/scripts/route-mode.sh killswitch
echo "vpn-post-down done at $(date -Iseconds), kill switch armed" >> /var/log/privacypi/vpn-hooks.log
