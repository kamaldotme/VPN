# PrivacyPi — Plan 3: DNS Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** Layer a complete DNS privacy stack on top of Plan 2's network: **AdGuard Home** filters at port 53 (ad/tracker/malware/threat-intel), forwards to **Unbound** for recursive resolution with DNSSEC validation, with optional DoH/DoT/DoQ upstreams. **hnsd** resolves Handshake `.hns` domains. End state: connected devices automatically get ad-blocking, encrypted upstream DNS, no DNS provider trust required.

**Architecture:**
```
Device → 10.10.10.1:53 (AdGuard Home: filtering + caching)
       → 127.0.0.1:5335 (Unbound: recursive + DNSSEC)
         ├── direct recursive (no upstream trust)
         └── optional DoH/DoT/DoQ to Cloudflare/Quad9/Mullvad
       → 127.0.0.1:5350 (hnsd: Handshake .hns names)
```

iptables already redirects all DHCP-served port 53/853 traffic to the Pi (Plan 2). Now we make sure something useful answers on that port.

**Tech Stack:** AdGuard Home (binary install), Unbound (apt), hnsd (binary build), apparmor profiles for sandboxing.

---

## File Structure

```
system/etc/
├── unbound/unbound.conf.d/privacypi.conf  ← recursive config
├── AdGuardHome/AdGuardHome.yaml           ← AdGuard config
└── systemd/system/
    ├── hnsd.service                       ← Handshake resolver
    └── AdGuardHome.service                ← from installer
opt/privacypi/scripts/
└── dns-test.sh                            ← in-Pi diagnostics
scripts/
├── 15-deploy-dns.sh                       ← orchestrator
└── verify-dns.sh                          ← end-to-end checks
```

---

## Task 1 — Install Unbound + recursive config

- [ ] Install Unbound via apt
- [ ] Write `/etc/unbound/unbound.conf.d/privacypi.conf` with:
  - port 5335
  - `do-tcp: yes`, `do-udp: yes`
  - DNSSEC validation
  - aggressive NSEC, prefetch, qname-minimisation
  - hide identity/version
  - 4MB cache
  - root hints from `/var/lib/unbound/root.hints`
- [ ] Fetch root.hints
- [ ] systemd enable + start
- [ ] Verify with `dig @127.0.0.1 -p 5335 cloudflare.com +dnssec`

## Task 2 — Install AdGuard Home

- [ ] Run official installer: `curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v`
- [ ] Stop AdGuard immediately so we can write our own config
- [ ] Write `/opt/AdGuardHome/AdGuardHome.yaml`:
  - DNS: bind 0.0.0.0:53
  - Upstream: `127.0.0.1:5335` (Unbound) for everything except `.hns`
  - Conditional upstream for `[/hns/]127.0.0.1:5350` once hnsd is up (Task 3)
  - Default blocklists: AdGuard DNS Filter, Hagezi Multi PRO, OISD Big, StevenBlack, Phishtank, URLhaus
  - Web UI: bind 0.0.0.0:3000
  - Admin auth: random password (saved to `/etc/privacypi/adguard.creds`)
- [ ] Restart, verify with `dig @10.10.10.1 doubleclick.net` (should return 0.0.0.0)

## Task 3 — Install hnsd (Handshake)

- [ ] Build hnsd from source (small C project; no Ubuntu package)
  - apt install build deps: `libunbound-dev libldns-dev`
  - clone https://github.com/handshake-org/hnsd
  - configure / make / install to `/usr/local/bin/hnsd`
- [ ] systemd unit:
  - listens on 127.0.0.1:5350
  - runs as `nobody`
- [ ] Wire AdGuard's per-domain upstream `[/hns/]127.0.0.1:5350`
- [ ] Verify with `dig @10.10.10.1 welcome.nb` (a known .hns name)

## Task 4 — DNS leak protection re-confirm

The iptables DNAT from Plan 2 already forces port 53. Add explicit DROP rules for **outbound DNS from connected devices that bypasses the Pi** (defense-in-depth: if a device manually crafts a packet to 8.8.8.8:53 it gets DNAT'd to the Pi).

- [ ] Add a check rule: log + drop any packet that exits eth0 with dport 53 and src in 10.10.10.0/24 (should be impossible after DNAT — but log if it ever happens)

## Task 5 — Verification suite

`scripts/verify-dns.sh` checks:
- Unbound running, DNSSEC works
- AdGuard running, ad domains blocked, normal queries resolve
- hnsd running, .hns query works
- Device can reach 10.10.10.1:53 and gets answers
- DNS leak: client can't bypass Pi to reach external DNS

## Task 6 — Tracker + Tag

- [ ] Mark Phase 5 complete in TRACKER.md
- [ ] Tag `plan-03-complete`

---

## Done

End state: devices connecting to PrivacyPi WiFi automatically get full DNS privacy: ad/tracker blocking via AdGuard, recursive resolution via Unbound, optional decentralized .hns names, all queries pinned to the Pi via iptables.

**Next:** Plan 4 — VPN Layer (OpenVPN + WireGuard + provider scaffolding for Nord/Express/Mullvad/Proton/IVPN/Surfshark/AirVPN/custom).
