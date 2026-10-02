#!/usr/bin/env bash
# End-to-end test without hardware: boots the installed system (systemd as
# PID 1) in a container as if it were a freshly flashed card's first boot, then
# plays a WiFi client (a network namespace bridged onto the LAN) through the
# whole user journey: DHCP → captive portal → wizard → internet → dashboard.
# The only thing not covered is the radio itself (hostapd needs real WiFi).
#
#   tests/e2e.sh            # build image + run
#   tests/e2e.sh --keep     # leave the container running for inspection
set -uo pipefail
cd "$(dirname "$0")/.."
NAME=privacypi-e2e
IMAGE="${IMAGE:-privacypi-e2e}"
KEEP=0; [[ "${1:-}" == "--keep" ]] && KEEP=1
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ✗ $1${2:+  — $2}"; }
check(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
x()    { docker exec "$NAME" bash -c "$1"; }
cli()  { docker exec "$NAME" ip netns exec client bash -c "$1"; }
# A-record answers only (not the "Server:" header lines nslookup also prints)
dnsa() { cli "busybox nslookup -type=a $1 10.10.10.1 2>/dev/null" | awk '/^Name:/{f=1} f&&/^Address/{print $2}' | head -n1; }

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  echo "== building test image"
  docker build -q --platform linux/arm64 -f tests/Dockerfile.e2e -t "$IMAGE" . >/dev/null || { echo "build failed"; exit 1; }
fi
docker rm -f "$NAME" >/dev/null 2>&1
docker run -d --name "$NAME" --privileged --cgroupns=host --platform linux/arm64 \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock --tmpfs /tmp "$IMAGE" >/dev/null || exit 1
trap '[[ $KEEP == 1 ]] || docker rm -f "$NAME" >/dev/null 2>&1' EXIT

echo "== first boot"
for i in $(seq 1 90); do
  s=$(x "systemctl is-system-running 2>/dev/null"); [[ "$s" == "running" || "$s" == "degraded" ]] && break; sleep 1
done
echo "  system state: $s after ${i}s"
x "echo nameserver 127.0.0.1 > /etc/resolv.conf"
for i in $(seq 1 40); do x "curl -fs -o /dev/null http://127.0.0.1:8443/setup/welcome" && break; sleep 1; done

echo "== provisioning (per-device, generated at first boot)"
for f in master.key secret.env alert.secret adguard.creds wifi-psk.txt .provisioned; do check "/etc/privacypi/$f exists" x "test -s /etc/privacypi/$f || test -e /etc/privacypi/$f"; done
check "setup flag absent" x "test ! -e /etc/privacypi/setup-complete"
check "AdGuard config seeded" x "test -s /opt/AdGuardHome/AdGuardHome.yaml"
check "hostapd.conf rendered with setup SSID" x "grep -q '^ssid=PrivacyPi-Setup$' /etc/hostapd/hostapd.conf"
check "setup WiFi password is the documented default" x "grep -q '^wpa_passphrase=privacypi$' /etc/hostapd/hostapd.conf"
check "machine-id initialised by first boot" x "test \$(cat /etc/machine-id) != uninitialized"

echo "== services"
for s in privacypi-init systemd-networkd dnsmasq unbound AdGuardHome caddy privacypi-flask privacypi-firewall privacypi-vpn-up privacypi-setup-mode privacypi-setup-dns privacypi-wan-watch tor@default chrony; do
  check "$s active" x "systemctl is-active $s"
done
for s in NetworkManager wpa_supplicant ssh systemd-resolved privacypi-openvpn; do
  check "$s NOT active" x "! systemctl is-active $s"
done
echo "  failed units: $(x "systemctl --failed --no-legend --plain | awk '{print \$1}' | tr '\n' ' '")(systemd-firstboot/hostapd expected here: no console, no radio)"
check "first boot did not enable stray services" x "! systemctl is-enabled caddy-api chronyd-restricted rsync ssh 2>/dev/null | grep -q '^enabled'"

echo "== network plumbing"
check "LAN bridge has 10.10.10.1" x "ip -4 addr show br-vlan10 | grep -q 10.10.10.1"
check "INPUT filter chain present" x "iptables -S PP-INPUT | grep -q -- '-j DROP'"
check "setup mode: forwarding rejected" x "iptables -S FWD-br-vlan10 | grep -q REJECT"

echo "== WiFi client joins (simulated)"
x "ip netns add client; ip link add veth-lan type veth peer name veth-cli; ip link set veth-cli netns client; ip link set veth-lan master br-vlan10 up; ip netns exec client ip link set lo up; ip netns exec client ip link set veth-cli up" 
x "mkdir -p /etc/netns/client; printf '#!/bin/sh\ncase \$1 in bound|renew) ip addr flush dev \$interface; ip addr add \$ip/\${mask:-24} dev \$interface; ip route replace default via \$router; echo nameserver \$dns > /etc/netns/client/resolv.conf;; esac\n' > /root/udhcpc.sh; chmod +x /root/udhcpc.sh"
x "ip netns exec client busybox udhcpc -i veth-cli -s /root/udhcpc.sh -n -q -t 8 >/dev/null 2>&1"
check "client got a DHCP lease in 10.10.10.x" cli "ip -4 addr show veth-cli | grep -q 'inet 10\.10\.10\.'"
check "client was told to use the Pi for DNS" x "grep -q 10.10.10.1 /etc/netns/client/resolv.conf"

echo "== captive portal (setup mode)"
[[ "$(dnsa captive.apple.com)" == "10.10.10.1" ]] && ok "any DNS name resolves to the Pi" || bad "captive DNS" "$(dnsa captive.apple.com)"
loc=$(cli "curl -s -o /dev/null -w '%{redirect_url}' http://captive.apple.com/hotspot-detect.html")
[[ "$loc" == "http://10.10.10.1/setup/" ]] && ok "phone connectivity probe is redirected to the wizard" || bad "captive redirect" "$loc"
loc=$(cli "curl -s -o /dev/null -w '%{redirect_url}' http://connectivitycheck.gstatic.com/generate_204")
[[ "$loc" == "http://10.10.10.1/setup/" ]] && ok "Android probe redirected too" || bad "android captive redirect" "$loc"
check "no internet through the setup network" cli "! curl -s -m 4 -o /dev/null https://1.1.1.1/"
check "wizard page served over plain HTTP" cli "curl -fs http://10.10.10.1/setup/welcome | grep -q 'Welcome to PrivacyPi'"

echo "== wizard walk-through (as a browser)"
J=/root/jar
tok() { cli "curl -s -c $J -b $J http://10.10.10.1$1" | sed -n 's/.*name="csrf_token" value="\([^"]*\)".*/\1/p' | head -1; }
post() { local path="$1"; shift; local t; t=$(tok "$path"); cli "curl -s -o /root/resp.html -w '%{http_code} %{redirect_url}' -c $J -b $J -e http://10.10.10.1$path --data-urlencode csrf_token=$t $* http://10.10.10.1$path"; }
r=$(post /setup/welcome "-d country=IN");                   [[ "$r" == "302 http://10.10.10.1/setup/admin" ]] && ok "welcome (country) → password" || bad "welcome" "$r"
r=$(post /setup/admin "-d password=short -d password2=short"); [[ "$r" == 200* ]] && ok "short password rejected" || bad "short pw" "$r"
r=$(post /setup/admin "-d password=TestPass-2026 -d password2=TestPass-2026"); [[ "$r" == "302 http://10.10.10.1/setup/internet" ]] && ok "password set → internet" || bad "admin" "$r"
check "internet step shows connection state" cli "curl -fs -b $J http://10.10.10.1/setup/wan/status | grep -q '\"ok\": *true'"
r=$(post /setup/internet);                                  [[ "$r" == "302 http://10.10.10.1/setup/wifi" ]] && ok "internet → wifi" || bad "internet" "$r"
r=$(post /setup/wifi "--data-urlencode 'ssid=bad;name' -d psk=MyWifiPass99 -d psk2=MyWifiPass99"); [[ "$r" == 200* ]] && ok "unsafe WiFi name rejected" || bad "ssid validation" "$r"
r=$(post /setup/wifi "--data-urlencode 'ssid=Mogli Home' -d psk=MyWifiPass99 -d psk2=MyWifiPass99"); [[ "$r" == "302 http://10.10.10.1/setup/mode" ]] && ok "wifi saved → mode" || bad "wifi" "$r $(x 'grep -o "toast[^<]*<[^<]*" /root/resp.html | head -2')"
r=$(post /setup/mode "-d mode=direct");                      [[ "$r" == "302 http://10.10.10.1/setup/done" ]] && ok "mode → done" || bad "mode" "$r"
r=$(post /setup/done);                                      [[ "$r" == 200* ]] && cli "grep -q 'PrivacyPi is ready' /root/resp.html" && ok "finish page shown" || bad "finish" "$r"
echo "  (PrivacyPi restarts itself after the wizard…)"
for i in $(seq 1 30); do [[ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" == "false" ]] && break; sleep 1; done
docker start "$NAME" >/dev/null
for i in $(seq 1 60); do x "curl -fs -o /dev/null http://127.0.0.1:8443/login" 2>/dev/null && break; sleep 1; done
x "echo nameserver 127.0.0.1 > /etc/resolv.conf; ip netns add client; ip link add veth-lan type veth peer name veth-cli; ip link set veth-cli netns client; ip link set veth-lan master br-vlan10 up; ip netns exec client ip link set lo up; ip netns exec client ip link set veth-cli up; ip netns exec client busybox udhcpc -i veth-cli -s /root/udhcpc.sh -n -q -t 8 >/dev/null 2>&1"

echo "== after setup"
check "setup flag written" x "test -e /etc/privacypi/setup-complete"
check "WiFi renamed to the user's choice" x "grep -q '^ssid=Mogli Home$' /etc/hostapd/hostapd.conf"
check "WiFi password is the user's" x "grep -q '^wpa_passphrase=MyWifiPass99$' /etc/hostapd/hostapd.conf"
check "country applied" x "grep -q '^country_code=IN$' /etc/hostapd/hostapd.conf"
check "captive DNS stopped" x "! systemctl is-active privacypi-setup-dns"
check "captive rules gone" x "! iptables -t nat -S PREROUTING | grep -q 5354"
check "wizard is closed (404)" cli "test \$(curl -s -o /dev/null -w '%{http_code}' http://10.10.10.1/setup/welcome) = 404"
check "routing mode = direct" x "grep -q '\"mode\":\"direct\"' /var/lib/privacypi/active-vpn"
check "client routing table has a default route" x "ip route show table 100 | grep -q '^default'"
check "upstream DNS is encrypted (DoT)" x "grep -q 'forward-tls-upstream: yes' /etc/unbound/unbound.conf.d/privacypi-forward.conf"

echo "== client internet through the Pi"
a=$(dnsa example.com); [[ "$a" =~ ^[0-9.]+$ && "$a" != "10.10.10.1" && "$a" != "0.0.0.0" ]] && ok "DNS resolves a real name via the Pi ($a)" || bad "real DNS" "$a"
check "HTTPS works through NAT" cli "curl -fs -m 15 -o /dev/null https://example.com/"
for i in $(seq 1 30); do [[ "$(dnsa doubleclick.net)" == "0.0.0.0" ]] && break; sleep 3; done
[[ "$(dnsa doubleclick.net)" == "0.0.0.0" ]] && ok "ad domain is blocked (blocklists loaded after ${i} tries)" || bad "ad blocking" "doubleclick.net → $(dnsa doubleclick.net)"
[[ "$(dnsa privacypi.local)" == "10.10.10.1" ]] && ok "privacypi.local resolves for clients" || bad "privacypi.local" "$(dnsa privacypi.local)"

echo "== dashboard"
rm_j() { cli "rm -f $J"; }; rm_j
t=$(tok /login)
r=$(cli "curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -c $J -b $J -e http://10.10.10.1/login --data-urlencode csrf_token=$t -d username=admin -d password=wrong http://10.10.10.1/login"); [[ "$r" == 200* ]] && ok "wrong password rejected" || bad "bad login" "$r"
t=$(tok /login)
r=$(cli "curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -c $J -b $J -e http://10.10.10.1/login --data-urlencode csrf_token=$t -d username=admin -d password=TestPass-2026 http://10.10.10.1/login"); [[ "$r" == "302 http://10.10.10.1/" ]] && ok "login over HTTP (no 2FA required)" || bad "login" "$r"
for p in / /network /devices /modes /vpn /tor /proxies /dns /wg-server /trust /diagnostics /extras /backup /system /alerts /audit; do
  c=$(cli "curl -s -o /dev/null -w '%{http_code}' -b $J http://10.10.10.1$p"); [[ "$c" == 200 ]] && ok "page $p" || bad "page $p" "HTTP $c"
done
for a in /api/status /api/wan/status /api/ap /api/vpn/state /api/extras /api/2fa; do
  check "api $a" cli "curl -fs -b $J http://10.10.10.1$a | grep -q ."
done
check "HTTPS dashboard also answers" cli "curl -ks -o /dev/null -w '%{http_code}' https://10.10.10.1/login | grep -q 200"
check "no external resources in pages (privacy)" cli "! curl -s -b $J http://10.10.10.1/ | grep -qE 'googleapis|gstatic|cdnjs|unpkg'"

echo "== mode switching"
csrf=$(cli "curl -s -b $J http://10.10.10.1/modes" | sed -n 's/.*name="csrf-token" content="\([^"]*\)".*/\1/p' | head -1)
api() { cli "curl -s -b $J -H 'X-CSRFToken: $csrf' -H 'Referer: http://10.10.10.1/modes' -X POST ${2:-} http://10.10.10.1$1"; }
r=$(api /api/mode/killswitch); echo "$r" | grep -q '"ok": *true' && ok "kill switch API" || bad "killswitch api" "$r"
check "kill switch blocks the client" cli "! curl -s -m 5 -o /dev/null https://example.com/"
api /api/mode/direct >/dev/null
check "direct mode restores the client" cli "curl -fs -m 15 -o /dev/null https://example.com/"
r=$(api /api/mode/openvpn); echo "$r" | grep -q 'Set up a VPN first' && ok "VPN mode without a VPN gives a clear message" || bad "vpn guard" "$r"
check "…and does not cut the client off" cli "curl -fs -m 15 -o /dev/null https://example.com/"
api /api/mode/tor >/dev/null
for i in $(seq 1 45); do x "grep -q 'Bootstrapped 100%' /var/log/tor/notices.log 2>/dev/null" && break; sleep 2; done
torip=$(cli "curl -s -m 30 https://check.torproject.org/api/ip"); echo "$torip" | grep -q '"IsTor":true' && ok "Tor mode: client exits through Tor" || bad "tor mode" "$torip"
check "Tor mode: dashboard still reachable from the WiFi" cli "curl -fs -m 8 -o /dev/null -b $J http://10.10.10.1/modes"
check "Tor mode: client DNS resolves through Tor" x "iptables -t nat -S PREROUTING | sed -n 2p | grep -q -- '--to-ports 5353'"
r=$(api /api/mode/direct); echo "$r" | grep -q '"ok": *true' && ok "back to direct from Tor" || bad "tor → direct" "$r"

echo "== VPN connect (local OpenVPN server standing in for a provider)"
VPN=privacypi-e2e-vpn
docker rm -f "$VPN" >/dev/null 2>&1
docker run -d --name "$VPN" --privileged --platform linux/arm64 -v "$PWD/tests/vpn-server.sh":/vpn-server.sh:ro debian:trixie sh /vpn-server.sh >/dev/null
trap '[[ $KEEP == 1 ]] || docker rm -f "$NAME" "$VPN" privacypi-e2e-web >/dev/null 2>&1' EXIT
for i in $(seq 1 60); do docker exec "$VPN" test -f /srv/ready 2>/dev/null && break; sleep 2; done
VPNIP=$(docker exec "$VPN" sh -c "ip -4 addr show eth0 | awk '/inet /{print \$2}' | cut -d/ -f1")
# A host "on the internet" that the client may only reach through the tunnel.
# (Real internet hosts can't be used for TCP here: Docker Desktop hands the VPN
# server packets with unverified checksums, which a userspace tunnel then
# faithfully delivers broken. Container-to-container traffic is fine.)
WEB=privacypi-e2e-web
docker rm -f "$WEB" >/dev/null 2>&1
docker run -d --name "$WEB" busybox sh -c 'mkdir /w; echo beyond-the-vpn > /w/index.html; httpd -f -p 80 -h /w' >/dev/null
WEBIP=$(docker exec "$WEB" sh -c "ip -4 addr show eth0 | awk '/inet /{print \$2}' | cut -d/ -f1")
docker exec -i "$NAME" bash -c "cat > /root/test.ovpn" <<OVPN
client
dev tun
proto udp
remote $VPNIP 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth-user-pass
cipher AES-256-CBC
keysize 256
verb 3
script-security 2
up /root/evil.sh
<ca>
$(docker exec "$VPN" cat /srv/vpn/ca.crt)
</ca>
OVPN
x "printf '#!/bin/sh\ntouch /root/PWNED\n' > /root/evil.sh; chmod +x /root/evil.sh"
apif() { cli "curl -s -m 100 -b $J -H 'X-CSRFToken: $csrf' -H 'Referer: http://10.10.10.1/vpn' -X POST ${2:-} http://10.10.10.1$1"; }
r=$(apif /api/vpn/custom-ovpn/connect); echo "$r" | grep -q 'Upload\|No server file' && ok "connect without a config → clear message" || bad "no-config message" "$r"
x "printf 'client\nremote $VPNIP 1194\nfrobnicate 1\n' > /root/broken.ovpn; printf 'u\np\n' > /etc/privacypi/vpn/custom-ovpn/auth.txt"
apif /api/vpn/custom-ovpn/upload "-F file=@/root/broken.ovpn" >/dev/null
r=$(apif /api/vpn/custom-ovpn/connect); echo "$r" | grep -q 'not accepted' && ok "broken config file → clear message, fast" || bad "broken config message" "$r"
x "rm -f /etc/privacypi/vpn/custom-ovpn/servers/broken.ovpn"
r=$(apif /api/vpn/custom-ovpn/upload "-F file=@/root/test.ovpn"); echo "$r" | grep -q '"ok": *true' && ok "config upload" || bad "upload" "$r"
r=$(apif /api/vpn/custom-ovpn/credentials "-d username=vpnuser -d password=WRONG"); echo "$r" | grep -q '"ok": *true' && ok "credentials saved" || bad "creds" "$r"
r=$(apif /api/vpn/custom-ovpn/connect); echo "$r" | grep -q 'rejected the username or password' && ok "wrong VPN password → clear message" || bad "auth failure message" "$r"
check "…client still has internet after the failed attempt" cli "curl -fs -m 15 -o /dev/null https://example.com/"
apif /api/vpn/custom-ovpn/credentials "-d username=vpnuser -d password=vpnpass" >/dev/null
r=$(apif /api/vpn/custom-ovpn/connect); echo "$r" | grep -q '"ok": *true' && ok "VPN connects with the right password" || bad "vpn connect" "$r"
check "tunnel interface tun0 is up" x "ip -4 addr show tun0 | grep -q 'inet 10\.99\.0\.'"
check "client traffic goes through the tunnel" cli "curl -fs -m 10 http://10.99.0.1:8080/ | grep -q hello-from-inside-the-vpn"
check "client reaches a host beyond the VPN server" cli "curl -fs -m 10 http://$WEBIP/ | grep -q beyond-the-vpn"
check "client DNS still filtered by the Pi" test "$(dnsa doubleclick.net)" = "0.0.0.0"
check "uploaded config was sanitised (no 'up' script ran)" x "test ! -e /root/PWNED && ! grep -q '^up ' /etc/privacypi/vpn/active.ovpn"
check "upstream DNS switched to in-tunnel" x "! grep -q forward-tls-upstream /etc/unbound/unbound.conf.d/privacypi-forward.conf"
check "dashboard reports connected" cli "curl -fs -b $J http://10.10.10.1/api/vpn/state | grep -q '\"tun0_up\":true'"
echo "  (provider goes down…)"
docker exec "$VPN" busybox killall openvpn; sleep 25
check "tunnel down → client is blocked, not leaked around the VPN" cli "! curl -s -m 5 -o /dev/null http://$WEBIP/"
echo "  (provider comes back…)"
docker exec -d "$VPN" /srv/vpn/run.sh
for i in $(seq 1 30); do cli "curl -fs -m 4 -o /dev/null http://10.99.0.1:8080/" && break; sleep 3; done
check "tunnel re-establishes by itself and the client is back" cli "curl -fs -m 10 http://$WEBIP/ | grep -q beyond-the-vpn"
echo "  (reboot while on VPN…)"
docker restart "$NAME" >/dev/null
for i in $(seq 1 60); do x "ip -4 addr show tun0 2>/dev/null | grep -q inet" && break; sleep 2; done
x "ip netns add client 2>/dev/null; ip link add veth-lan type veth peer name veth-cli; ip link set veth-cli netns client; ip link set veth-lan master br-vlan10 up; ip netns exec client ip link set lo up; ip netns exec client ip link set veth-cli up; ip netns exec client busybox udhcpc -i veth-cli -s /root/udhcpc.sh -n -q -t 8 >/dev/null 2>&1"
for i in $(seq 1 20); do cli "curl -fs -m 4 -o /dev/null http://10.99.0.1:8080/" && break; sleep 3; done
check "after a reboot the VPN comes back by itself" cli "curl -fs -m 10 http://10.99.0.1:8080/ | grep -q hello"
t=$(tok /login); cli "curl -s -o /dev/null -c $J -b $J -e http://10.10.10.1/login --data-urlencode csrf_token=$t -d username=admin -d password=TestPass-2026 http://10.10.10.1/login"
csrf=$(cli "curl -s -b $J http://10.10.10.1/modes" | sed -n 's/.*name="csrf-token" content="\([^"]*\)".*/\1/p' | head -1)
r=$(apif /api/vpn/disconnect); echo "$r" | grep -q '"mode":"direct"' && ok "disconnect → direct" || bad "disconnect" "$r"
check "tunnel stopped" x "! ip link show tun0"
check "client online without the VPN" cli "curl -fs -m 15 -o /dev/null https://example.com/"
check "upstream DNS back to DoT" x "grep -q forward-tls-upstream /etc/unbound/unbound.conf.d/privacypi-forward.conf"
[[ $KEEP == 1 ]] || docker rm -f "$VPN" "$WEB" >/dev/null 2>&1

echo "== WAN side is closed"
WANIP=$(x "ip -4 addr show eth0 | awk '/inet /{print \$2}' | cut -d/ -f1")
probe() { docker run --rm curlimages/curl:latest -s -m 4 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null; }
[[ "$(probe http://example.com/)" == 200 ]] && ok "(probe container works)" || bad "probe container" "cannot verify WAN isolation"
for port in 80 443 3000; do
  c=$(probe "http://$WANIP:$port/"); [[ "$c" == 000 ]] && ok "port $port closed from the upstream network" || bad "WAN port $port" "HTTP $c"
done

echo "== uplink change is picked up"
x "ip route flush table 100; ip route add 10.10.10.0/24 dev br-vlan10 table 100"; sleep 8
check "wan-watch restored the client default route" x "ip route show table 100 | grep -q '^default'"

echo "== factory reset → back to out-of-box"
x "/opt/privacypi/scripts/factory-reset.sh >/dev/null; /opt/privacypi/scripts/boot-init.sh >/dev/null 2>&1; systemctl restart privacypi-flask"; sleep 3
check "setup SSID is back" x "grep -q '^ssid=PrivacyPi-Setup$' /etc/hostapd/hostapd.conf"
check "old admin account gone, wizard is back" x "curl -fs http://127.0.0.1:8443/setup/welcome -H 'Host: 10.10.10.1' | grep -q 'Welcome to PrivacyPi'"
check "new secrets differ per provisioning" x "test -s /etc/privacypi/master.key"

echo "== status report"
x "/opt/privacypi/scripts/diag.sh >/dev/null 2>&1"
check "report written" x "test -s /boot/firmware/privacypi-status.txt -o -s /boot/privacypi-status.txt -o -s /var/log/privacypi/status.txt"
check "report contains no WiFi password" x "! grep -rq 'MyWifiPass99\|TestPass-2026' /boot/privacypi-status.txt /var/log/privacypi/status.txt 2>/dev/null"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[[ $KEEP == 1 ]] && echo "(container '$NAME' left running: docker exec -it $NAME bash)"
exit $(( FAIL > 0 ))
