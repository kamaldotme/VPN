#!/usr/bin/env bash
# dns-profile.sh <Light|Standard|Strict|Family> — apply a blocking level to
# AdGuard Home through its API (the dashboard's "DNS" page).
#
#   Light     ads + trackers (AdGuard list only)
#   Standard  + the StevenBlack hosts list (ads, trackers, malware)
#   Strict    Standard + AdGuard browsing security (phishing/malware lookups)
#   Family    Strict + adult-content blocking + enforced safe search
set -uo pipefail
PROFILE="${1:-}"
CRED=$(cat /etc/privacypi/adguard.cred 2>/dev/null) || { echo '{"ok":false,"error":"AdGuard credentials missing"}'; exit 1; }
API=http://127.0.0.1:3000/control
F1=https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
F2=https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts

call() {  # method path [json]
  local m="$1" p="$2" d="${3:-}"
  if [[ -n "$d" ]]; then curl -s -m 15 -o /dev/null -w '%{http_code}' -u "$CRED" -X "$m" -H 'Content-Type: application/json' -d "$d" "$API$p"
  else curl -s -m 15 -o /dev/null -w '%{http_code}' -u "$CRED" -X "$m" "$API$p"; fi
}
set_list() {  # url name enabled
  call POST /filtering/set_url "{\"url\":\"$1\",\"whitelist\":false,\"data\":{\"name\":\"$2\",\"url\":\"$1\",\"enabled\":$3}}"
}
toggle() { call POST "/$1/$([[ "$2" == true ]] && echo enable || echo disable)"; }
safesearch() {
  call PUT /safesearch/settings "{\"enabled\":$1,\"bing\":true,\"duckduckgo\":true,\"ecosia\":true,\"google\":true,\"pixabay\":true,\"yandex\":true,\"youtube\":true}"
}

case "$PROFILE" in
  Light)    l2=false; sb=false; par=false; ss=false ;;
  Standard) l2=true;  sb=false; par=false; ss=false ;;
  Strict)   l2=true;  sb=true;  par=false; ss=false ;;
  Family)   l2=true;  sb=true;  par=true;  ss=true  ;;
  *) echo '{"ok":false,"error":"unknown level"}'; exit 2 ;;
esac

codes="$(set_list "$F1" "AdGuard DNS filter" true) $(set_list "$F2" "StevenBlack hosts" "$l2") $(toggle safebrowsing "$sb") $(toggle parental "$par") $(safesearch "$ss")"
if [[ "$codes" =~ ^(200\ ?)+$ ]]; then
  echo "{\"ok\":true,\"profile\":\"$PROFILE\"}"
else
  echo "{\"ok\":false,\"error\":\"AdGuard Home did not accept the change (HTTP $codes)\"}"; exit 1
fi
