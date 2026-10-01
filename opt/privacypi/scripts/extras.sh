#!/usr/bin/env bash
# extras.sh — optional anonymity networks that are NOT in the base image
# (kept out to keep the download small). Installed on demand from the
# dashboard's Extras page; needs an internet connection.
#
#   extras.sh status                 # JSON for all extras
#   extras.sh install <name>         # starts a background job, returns at once
#   extras.sh remove  <name>
#   extras.sh log <name>             # tail of the last job log
#   names: i2p | yggdrasil | lokinet
set -uo pipefail
source /opt/privacypi/scripts/lib/site.sh
LOGDIR=/var/log/privacypi
NAME="${2:-}"

pkg_of()  { case "$1" in i2p) echo i2pd ;; yggdrasil) echo yggdrasil ;; lokinet) echo lokinet ;; *) return 1 ;; esac; }
unit_of() { case "$1" in i2p) echo i2pd ;; yggdrasil) echo yggdrasil ;; lokinet) echo lokinet ;; esac; }
job_of()  { echo "privacypi-extras-$1"; }
installed() { dpkg-query -W -f='${Status}' "$(pkg_of "$1")" 2>/dev/null | grep -q 'install ok installed'; }

do_install() {
  export DEBIAN_FRONTEND=noninteractive
  echo "== installing $1 at $(date -Iseconds)"
  case "$1" in
    i2p)
      apt-get update -q && apt-get install -y --no-install-recommends i2pd || return 1
      [[ -f /etc/i2pd/i2pd.conf && ! -f /etc/i2pd/i2pd.conf.dist ]] && cp /etc/i2pd/i2pd.conf /etc/i2pd/i2pd.conf.dist
      cat > /etc/i2pd/i2pd.conf <<CONF
# Written by PrivacyPi extras.sh. Devices on the PrivacyPi WiFi reach I2P by
# setting their browser's HTTP proxy to $LAN_GW port 4444.
ipv4 = true
ipv6 = false
[http]
enabled = true
address = 127.0.0.1
port = 7070
[httpproxy]
enabled = true
address = $LAN_GW
port = 4444
[socksproxy]
enabled = true
address = $LAN_GW
port = 4447
CONF
      systemctl enable i2pd && systemctl restart i2pd
      ;;
    yggdrasil)
      apt-get update -q && apt-get install -y --no-install-recommends yggdrasil || return 1
      systemctl enable yggdrasil && systemctl restart yggdrasil
      ;;
    lokinet)
      curl -fsSL https://deb.oxen.io/pub.oxen.io.gpg -o /usr/share/keyrings/oxen.gpg || return 1
      . /etc/os-release
      echo "deb [signed-by=/usr/share/keyrings/oxen.gpg] https://deb.oxen.io ${VERSION_CODENAME:-trixie} main" > /etc/apt/sources.list.d/oxen.list
      apt-get update -q && apt-get install -y --no-install-recommends lokinet || return 1
      systemctl enable lokinet && systemctl restart lokinet
      ;;
  esac
  echo "== done"
}

do_remove() {
  export DEBIAN_FRONTEND=noninteractive
  echo "== removing $1 at $(date -Iseconds)"
  systemctl disable --now "$(unit_of "$1")" 2>/dev/null || true
  apt-get purge -y "$(pkg_of "$1")" && apt-get autoremove -y
  [[ "$1" == "lokinet" ]] && rm -f /etc/apt/sources.list.d/oxen.list
  echo "== done"
}

case "${1:-status}" in
  status)
    out=""
    for n in i2p yggdrasil lokinet; do
      inst=false; installed "$n" && inst=true
      act=$(systemctl is-active "$(unit_of "$n")" 2>/dev/null); [[ -z "$act" ]] && act=inactive
      busy=false; systemctl is-active --quiet "$(job_of "$n")" 2>/dev/null && busy=true
      out+="\"$n\":{\"installed\":$inst,\"active\":\"$act\",\"busy\":$busy},"
    done
    printf '{"ok":true,"extras":{%s}}\n' "${out%,}"
    ;;
  install|remove)
    pkg_of "$NAME" >/dev/null || { echo '{"ok":false,"error":"unknown extra"}'; exit 2; }
    mkdir -p "$LOGDIR"
    # Run outside the dashboard's sandbox (apt writes all over the system).
    systemctl reset-failed "$(job_of "$NAME")" 2>/dev/null || true
    systemd-run --quiet --collect --unit="$(job_of "$NAME")" \
      /bin/bash -c "/opt/privacypi/scripts/extras.sh _$1 $NAME > $LOGDIR/extras-$NAME.log 2>&1" \
      || { echo '{"ok":false,"error":"could not start the job (already running?)"}'; exit 1; }
    echo '{"ok":true,"started":true}'
    ;;
  _install) do_install "$NAME" ;;
  _remove)  do_remove "$NAME" ;;
  log)
    pkg_of "$NAME" >/dev/null || exit 2
    tail -n 25 "$LOGDIR/extras-$NAME.log" 2>/dev/null
    ;;
  *) echo '{"ok":false,"error":"usage: status|install <name>|remove <name>|log <name>"}'; exit 2 ;;
esac
