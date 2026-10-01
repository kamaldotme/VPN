#!/usr/bin/env bash
# Smoke-test a proxy URL without committing it to active.conf.
# Usage: proxy-test.sh <kind> <url>
# Reads URL from stdin if "$2" is "-".
# Returns JSON: {ok,latency_ms,exit_ip,error}
set -euo pipefail
KIND="${1:-}"
URL_ARG="${2:-}"
[[ "$URL_ARG" == "-" ]] && read -r URL || URL="$URL_ARG"
[[ -z "$KIND" || -z "${URL:-}" ]] && { echo '{"ok":false,"error":"args"}'; exit 1; }

TMPLOG=$(mktemp)
trap "rm -f $TMPLOG; pkill -P $$ 2>/dev/null || true" EXIT

START_PROXY() {
  case "$KIND" in
    socks5)
      HP="${URL#socks5://*@}"; HP="${HP##*@}"
      HOST="${HP%%:*}"; PORT="${HP##*:}"
      # Ephemeral local relay on 11080
      if ! command -v redsocks2 >/dev/null 2>&1; then
        # Direct test: just curl --socks5
        echo "DIRECT"
        return 0
      fi
      cat > "$TMPLOG.conf" <<RS
base { log = "stderr"; daemon = off; redirector = iptables; }
redsocks { local_ip = 127.0.0.1; local_port = 11080; ip = $HOST; port = $PORT; type = socks5; }
RS
      redsocks2 -c "$TMPLOG.conf" >"$TMPLOG" 2>&1 &
      sleep 1
      echo "11080"
      ;;
    ss)
      sslocal -U "$URL" -b 127.0.0.1:11080 >"$TMPLOG" 2>&1 &
      sleep 2
      echo "11080"
      ;;
    *)
      # vless/vmess/trojan/hysteria2/ssh — require xray/ssh plumbing already running
      echo "UNSUPPORTED-IN-TEST"
      return 1
      ;;
  esac
}

PORT_OR_DIRECT=$(START_PROXY) || {
  echo "{\"ok\":false,\"error\":\"start_failed\",\"log\":\"$(tail -3 $TMPLOG | tr '\n' ' ' | sed 's/"/\\"/g')\"}"
  exit 0
}

T0=$(date +%s%N)
case "$KIND" in
  socks5)
    if [[ "$PORT_OR_DIRECT" == "DIRECT" ]]; then
      EXIT_IP=$(curl -s --socks5-hostname "$URL" --max-time 8 https://api.ipify.org || echo "")
    else
      EXIT_IP=$(curl -s --max-time 8 -x "socks5h://127.0.0.1:$PORT_OR_DIRECT" https://api.ipify.org || echo "")
    fi
    ;;
  ss)
    EXIT_IP=$(curl -s --max-time 8 -x "socks5h://127.0.0.1:$PORT_OR_DIRECT" https://api.ipify.org || echo "")
    ;;
esac
T1=$(date +%s%N)
LAT_MS=$(( (T1 - T0) / 1000000 ))

if [[ -z "$EXIT_IP" ]]; then
  echo "{\"ok\":false,\"latency_ms\":$LAT_MS,\"error\":\"no_exit_ip\"}"
else
  echo "{\"ok\":true,\"latency_ms\":$LAT_MS,\"exit_ip\":\"$EXIT_IP\"}"
fi
