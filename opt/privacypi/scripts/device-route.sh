#!/usr/bin/env bash
# Per-device routing override using ipsets + iptables MARK + ip rule.
# Usage:
#   device-route.sh assign <mac> <mode>   # mode in {direct, tor, killswitch, none}
#   device-route.sh list                   # show current overrides
set -euo pipefail

ACTION="${1:-list}"

# Make sure ipsets exist
for set in privacypi-direct privacypi-tor privacypi-killswitch; do
  ipset list "$set" >/dev/null 2>&1 || ipset create "$set" hash:mac
done

case "$ACTION" in
  assign)
    MAC="${2:-}"; MODE="${3:-}"
    [[ -z "$MAC" || -z "$MODE" ]] && { echo "usage: $0 assign <mac> <mode>"; exit 2; }
    [[ "$MAC" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] || { echo "bad MAC: $MAC"; exit 2; }
    
    # Remove from all sets first
    for set in privacypi-direct privacypi-tor privacypi-killswitch; do
      ipset del "$set" "$MAC" 2>/dev/null || true
    done
    
    case "$MODE" in
      none) echo "$MAC: cleared (uses default routing)" ;;
      direct|tor|killswitch)
        ipset add "privacypi-$MODE" "$MAC"
        echo "$MAC: assigned to $MODE"
        ;;
      *) echo "unknown mode: $MODE"; exit 2 ;;
    esac
    ;;
  list)
    echo '{"overrides": ['
    first=1
    for set in privacypi-direct privacypi-tor privacypi-killswitch; do
      mode="${set#privacypi-}"
      while read -r mac; do
        [[ -z "$mac" || ! "$mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] && continue
        [[ $first -eq 0 ]] && echo ","
        first=0
        printf '  {"mac": "%s", "mode": "%s"}' "$mac" "$mode"
      done < <(ipset list "$set" 2>/dev/null | tail -n +9)
    done
    echo
    echo ']}'
    ;;
  *)
    echo "usage: $0 {assign <mac> <mode>|list}"; exit 2 ;;
esac
