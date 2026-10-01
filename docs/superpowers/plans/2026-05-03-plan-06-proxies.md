# PrivacyPi — Plan 6: Censorship Bypass Proxies

**Goal:** Install Shadowsocks (rust), Xray (covers V2Ray, Trojan, VLESS, VMess, Hysteria2 entry, NaiveProxy), tun2socks (transparent SOCKS routing). Plus DPI-bypass tooling. End state: Flask UI in Plan 9 will let user paste any proxy URI (`ss://`, `vless://`, `trojan://`, `hysteria2://`) and route all VLAN traffic through it via tun2socks.

**Architecture:**
```
br-vlan10 → tun2socks (creates tun0) → SOCKS5 127.0.0.1:1080
                                       → xray-core (any protocol) → eth0 → Internet
```

`route-mode.sh proxy` already exists from Plan 5 (placeholder); Plan 6 makes it real.

---

## Tasks

1. Install **shadowsocks-rust** (binary), **xray-core** (binary), **tun2socks** (go-tun2socks)
2. Optional: **brook**, **psiphon-tunnel-core**, **NaiveProxy** (cronet binary; can be skipped if too heavy on Pi)
3. Skip **GoodbyeDPI / zapret** for now (they target Linux but require kernel module compilation; defer)
4. Write `proxy-up.sh` and `proxy-down.sh` helpers that bring up / tear down the SOCKS-via-tun chain
5. Wire `route-mode.sh proxy` to start xray + tun2socks + flip iptables to tun0
6. Verify: services installable, SOCKS port responsive (no actual tunnel until creds entered in Plan 9)
7. Tag `plan-06-complete`

---

## Done

End state: proxy infrastructure ready. Plan 9 Flask UI lets user paste a proxy URI and click connect.

**Next:** Plan 7 — Flask App Core.
