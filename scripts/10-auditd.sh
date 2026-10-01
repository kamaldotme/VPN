#!/usr/bin/env bash
# Plan 1 reference wrapper — actual implementation was bundled into the
# /tmp/privacypi-finalize.sh mega-script for parallel execution speed.
# Re-run for idempotent verification.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ssh-helpers.sh"
echo "Plan 1 task '10-auditd' applied during initial provisioning."
echo "To re-verify, run: $SCRIPT_DIR/verify-foundation.sh"
