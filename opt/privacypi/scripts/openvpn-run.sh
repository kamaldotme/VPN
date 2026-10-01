#!/usr/bin/env bash
# Exec OpenVPN for the active profile (privacypi-openvpn.service).
# Options here override the provider's file where we need control:
#  - fixed device name tun0 (firewall + routing depend on it)
#  - IPv6 pushed by the provider is ignored (IPv6 forwarding is blocked, so a
#    half-configured v6 tunnel would only cause leaks or stalls)
#  - older provider configs (ExpressVPN, Surfshark, …) carry options OpenVPN 2.6
#    dropped or ciphers it no longer negotiates by default
set -uo pipefail
CONF=/etc/privacypi/vpn/active.ovpn
AUTH=/etc/privacypi/vpn/active.auth
# --ignore-unknown-option only applies to options that come AFTER it, so it
# must precede --config.
args=(--ignore-unknown-option keysize ns-cert-type block-outside-dns
      --config "$CONF" --dev tun0 --dev-type tun --auth-nocache --verb 3
      --data-ciphers "AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305:AES-256-CBC:AES-128-CBC"
      --allow-compression asym
      --pull-filter ignore "ifconfig-ipv6" --pull-filter ignore "route-ipv6"
      --pull-filter ignore "dhcp-option DNS6" --pull-filter ignore "block-outside-dns"
      --connect-retry 5 30 --resolv-retry 60
      # Some providers ship "ping-restart 0" (never notice a dead tunnel). We do
      # want to notice: restart the session after a minute of silence.
      --ping 15 --ping-restart 60)
[[ -s "$AUTH" ]] && args+=(--auth-user-pass "$AUTH")
exec /usr/sbin/openvpn "${args[@]}"
