#!/usr/bin/env bash
# Apply Tor bridge configuration.
# Usage:
#   tor-bridges.sh set < bridges-input    (stdin: one bridge line per line, blank to disable)
#   tor-bridges.sh status
set -euo pipefail
TORRC=/etc/tor/torrc
TORRC_BRIDGES=/etc/tor/torrc.bridges

case "${1:-status}" in
  set)
    cat > "$TORRC_BRIDGES" <<'CONF'
# Managed by PrivacyPi — replace via UI
UseBridges 1
ClientTransportPlugin obfs4 exec /usr/bin/obfs4proxy
ClientTransportPlugin snowflake exec /usr/bin/snowflake-client
CONF
    LINES=0
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      [[ "$line" =~ ^Bridge\  ]] || line="Bridge $line"
      echo "$line" >> "$TORRC_BRIDGES"
      LINES=$((LINES + 1))
    done
    chmod 644 "$TORRC_BRIDGES"
    
    # Include in main torrc if not already
    grep -q "torrc.bridges" "$TORRC" || echo "%include $TORRC_BRIDGES" >> "$TORRC"
    
    if [[ $LINES -eq 0 ]]; then
      # Disable bridges
      sed -i 's|^%include /etc/tor/torrc.bridges|# %include /etc/tor/torrc.bridges|' "$TORRC"
      systemctl reload tor
      echo '{"ok": true, "bridges": 0, "enabled": false}'
    else
      sed -i 's|^# %include /etc/tor/torrc.bridges|%include /etc/tor/torrc.bridges|' "$TORRC"
      systemctl reload tor
      echo "{\"ok\": true, \"bridges\": $LINES, \"enabled\": true}"
    fi
    ;;
  status)
    if [[ -f "$TORRC_BRIDGES" ]] && grep -q "^Bridge " "$TORRC_BRIDGES"; then
      LINES=$(grep -c "^Bridge " "$TORRC_BRIDGES")
      ENABLED=true
      grep -q "^%include $TORRC_BRIDGES" "$TORRC" || ENABLED=false
      echo "{\"bridges\": $LINES, \"enabled\": $ENABLED}"
    else
      echo '{"bridges": 0, "enabled": false}'
    fi
    ;;
  show)
    [[ -f "$TORRC_BRIDGES" ]] && grep "^Bridge " "$TORRC_BRIDGES" || true
    ;;
esac
