#!/bin/sh
# Test double for a commercial VPN provider: OpenVPN server with username/password
# auth (vpnuser / vpnpass), pushing redirect-gateway like providers do.
# Runs inside a throwaway container started by tests/e2e.sh.
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq openvpn openssl iptables busybox-static iproute2 >/dev/null 2>&1
mkdir -p /srv/vpn && cd /srv/vpn
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 3 -subj /CN=test-ca >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout srv.key -out srv.csr -subj /CN=server >/dev/null 2>&1
printf 'extendedKeyUsage=serverAuth\nkeyUsage=digitalSignature,keyEncipherment\n' > ext
openssl x509 -req -in srv.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out srv.crt -days 3 -extfile ext >/dev/null 2>&1
printf '#!/bin/sh\n[ "$(sed -n 1p "$1")" = vpnuser ] && [ "$(sed -n 2p "$1")" = vpnpass ]\n' > check.sh; chmod +x check.sh
mkdir -p /dev/net; [ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200
echo 1 > /proc/sys/net/ipv4/ip_forward
iptables -t nat -A POSTROUTING -s 10.99.0.0/24 -o eth0 -j MASQUERADE
mkdir -p /srv/www && echo "hello-from-inside-the-vpn" > /srv/www/index.html
cat > /srv/vpn/run.sh <<'RUN'
#!/bin/sh
cd /srv/vpn
exec openvpn --dev tun --topology subnet --server 10.99.0.0 255.255.255.0 --proto udp --port 1194 \
  --ca ca.crt --cert srv.crt --key srv.key --dh none --verify-client-cert none --username-as-common-name \
  --auth-user-pass-verify /srv/vpn/check.sh via-file --script-security 2 --tmp-dir /tmp \
  --push "redirect-gateway def1" --push "dhcp-option DNS 10.99.0.1" --keepalive 3 10 \
  --data-ciphers AES-256-GCM --verb 3 --log /srv/vpn/server.log
RUN
chmod +x /srv/vpn/run.sh
/srv/vpn/run.sh &
sleep 2
( cd /srv/www && busybox httpd -f -p 10.99.0.1:8080 ) &
touch /srv/ready
sleep infinity
