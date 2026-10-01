# PrivacyPi v2.0 — System Design Specification

**Status:** Approved (pending final user review)
**Date:** 2026-05-01
**Target hardware:** Raspberry Pi 4B
**Target OS:** Ubuntu Server 24.04 LTS

---

## 1. Project Goal

Build a complete, layman-friendly privacy WiFi router on Raspberry Pi 4B. The device broadcasts multiple WiFi networks (SSIDs) simultaneously, each with independent privacy routing (raw, VPN, Tor, proxy, IoT, guest). Per-device routing rules allow any device to be assigned a specific privacy mode regardless of which SSID it joined. The entire system is administered through a browser-based UI — no terminal commands are required for the end user.

---

## 2. Architectural Pillars

1. **Privacy by Default** — All traffic exits through a privacy layer unless explicitly placed on the Direct SSID.
2. **Layman-First UX** — Multi-SSID + per-device rules eliminate "mode switching." The user picks the SSID matching the use case.
3. **Defense in Depth** — Independent kill switches per VLAN, multiple DNS leak guards, layered filtering.
4. **Zero-Trust Pi** — The Pi itself is hardened against compromise (AppArmor, CrowdSec, 2FA, sudoers whitelist, encrypted backups).
5. **Decentralized Where Possible** — Self-recursive DNS via Unbound; pluggable Handshake/ENS resolvers; no required upstream trust.

---

## 3. Hardware & Network Topology

### 3.1 Hardware
- Raspberry Pi 4B (4GB or 8GB RAM)
- Built-in WiFi (`wlan0`) — used as WAN, connects to home router
- Edimax USB WiFi adapter (`wlan1`) — used as multi-SSID AP
- Ethernet (`eth0`) — development access only, removed post-setup

### 3.2 Network Topology

```
Internet
   ↑
Home Router
   ↑ wlan0 (Pi as WiFi client)
┌────────────────────────────────────────────┐
│  Raspberry Pi 4B — PrivacyPi               │
│  ┌─────────────────────────────────────┐  │
│  │ Privacy Engine: VPN/Tor/Proxy/DNS   │  │
│  └─────────────────────────────────────┘  │
└─┬──────────────────────────────────────────┘
  ↓ wlan1 (multi-SSID, VLAN-tagged)
  ├── SSID: PrivacyPi-Direct (VLAN 10) — raw
  ├── SSID: PrivacyPi-VPN    (VLAN 20) — VPN
  ├── SSID: PrivacyPi-Tor    (VLAN 30) — Tor
  ├── SSID: PrivacyPi-Proxy  (VLAN 40) — proxy
  ├── SSID: PrivacyPi-IoT    (VLAN 70) — allowlist
  ├── SSID: PrivacyPi-Guest  (VLAN 60) — direct, isolated
  └── SSID: PrivacyPi-Setup  (VLAN 99) — first-boot only
```

### 3.3 SSID & VLAN Plan (Defaults)

| SSID | VLAN | Subnet | Routing |
|---|---|---|---|
| `PrivacyPi-Direct` | 10 | 10.10.10.0/24 | Raw internet |
| `PrivacyPi-VPN` | 20 | 10.10.20.0/24 | Active VPN tunnel |
| `PrivacyPi-Tor` | 30 | 10.10.30.0/24 | Transparent Tor proxy |
| `PrivacyPi-Proxy` | 40 | 10.10.40.0/24 | Active proxy mode |
| `PrivacyPi-IoT` | 70 | 10.10.70.0/24 | Allowlist-only |
| `PrivacyPi-Guest` | 60 | 10.10.60.0/24 | Direct, isolated |
| `PrivacyPi-Setup` | 99 | 192.168.99.0/24 | First-boot wizard only |

The Pi is the gateway on each VLAN at `.1`. SSIDs are individually enable/disable-able from the UI.

### 3.4 Per-Device Override
Any device's MAC address can be assigned a routing mode that overrides its SSID's default routing. Used for parental controls, IoT containment, or forcing specific devices through Tor regardless of SSID.

---

## 4. Software Stack

| Layer | Component | Purpose |
|---|---|---|
| OS | Ubuntu Server 24.04 LTS | Hardened base |
| Sandboxing | AppArmor (enforcing) | Per-service sandboxing |
| Auto-updates | unattended-upgrades | Security patches |
| IDS / IPS | CrowdSec + bouncers | Brute-force, scan, threat intel |
| Audit | auditd | Audit trail of system changes |
| Watchdog | bcm2835_wdt | Hang recovery |
| AP | hostapd (multi-SSID, VLAN) | Broadcasts SSIDs |
| DHCP | dnsmasq | Per-VLAN ranges |
| WAN client | wpa_supplicant | wlan0 → home router |
| Network | netplan, ip rule, iptables, ipset | Routing & firewall |
| DNS resolver | Unbound | Recursive, DNSSEC |
| DNS filter | AdGuard Home | Per-SSID profiles |
| Decentralized DNS | hnsd (Handshake), ENS bridge | Alt name systems |
| VPN | OpenVPN, WireGuard | VPN tunnels |
| Tor | tor + obfs4proxy + snowflake-client + meek-client + WebTunnel | Anonymity |
| Anonymity | i2pd, lokinet, yggdrasil, cjdns | Alternative networks |
| Proxies | shadowsocks-rust, xray-core, trojan-go, hysteria2, naiveproxy, brook, cloak, psiphon-tunnel-core | Censorship bypass |
| DPI bypass | GoodbyeDPI / zapret, DPITunnel | DPI evasion |
| MAC spoofing | macchanger | wlan0 MAC randomization |
| Web backend | Flask + Gunicorn | Admin UI server |
| Web frontend | Bootstrap 5 + HTMX + Alpine.js | Lightweight UI |
| Real-time | Server-Sent Events | Live status push |
| Database | SQLite + SQLAlchemy | Config storage |
| Auth | Flask-Login + bcrypt + pyotp | Password + TOTP 2FA |
| Encryption | cryptography (Fernet), age | At-rest + backup encryption |
| Notifications | apprise | Telegram/Discord/Email/ntfy |
| Backup | age + tar + rclone | Local + cloud backups |

---

## 5. Network Architecture

### 5.1 hostapd (Multi-SSID, VLAN)
- Single hostapd instance with `bss=` directives for each SSID
- VLAN tagging via `dynamic_vlan=1` (or static SSID-to-VLAN map)
- Per-SSID WPA2/WPA3 password
- Per-SSID client isolation toggle

### 5.2 VLAN Interfaces
For each SSID, a corresponding `vlanXX` interface is created on top of `wlan1`. Bridge per VLAN if needed for inter-bridging Setup or Guest.

### 5.3 dnsmasq
Multi-range DHCP server. Per-VLAN range, per-VLAN gateway, per-VLAN DNS pointer (which is always `10.10.X0.1`, i.e., the Pi). Lease times tuned per profile (short for Setup/Guest, longer for trusted SSIDs).

### 5.4 Routing Tables
- One `ip rule` per VLAN selects a dedicated routing table (`100`, `200`, `300`, etc.)
- Each table's default route points to the active tunnel for that SSID, or to `wlan0` directly for Direct/Guest
- Mode switches rewrite the relevant table; other tables are untouched (true independent SSID routing)

### 5.5 iptables Strategy
- Default `FORWARD` policy: `DROP`
- Custom chains per VLAN (e.g., `FWD-VLAN20`)
- Each chain enforces:
  - Allow only traffic out the correct tunnel/interface (kill switch)
  - Force DNS to Pi
  - Drop WebRTC/STUN
  - Drop UPnP/NetBIOS/LLMNR
  - Optional Geo-IP block via `ipset`
  - Per-MAC override rules
- Rules persisted via `iptables-persistent`; reloaded by Flask scripts on changes

### 5.6 Per-VLAN Kill Switch
Each VLAN has its own kill switch script that sets/unsets the chain's allow rule based on tunnel health. A drop on `PrivacyPi-VPN` does not affect `PrivacyPi-Tor`.

---

## 6. DNS Architecture

### 6.1 Resolution Path
```
Device → 10.10.X0.1 (port 53)
       → AdGuard Home (filtering profile based on SSID)
       → Unbound (port 5335, recursive + DNSSEC)
       → upstream choice:
           ├── DoH/DoT/DoQ provider
           ├── DNSCrypt v2
           ├── Tor (DNSPort)
           ├── Handshake (hnsd)
           └── ENS bridge
```

### 6.2 AdGuard Home Filtering Profiles
Per-SSID and per-device:
- **Light** — ads, basic trackers
- **Standard** — ads, trackers, malware
- **Strict** — Standard + threat intel feeds (Hagezi, OISD, URLhaus, Phishtank)
- **Family** — Strict + adult content, social media schedules
- **IoT** — telemetry-block, manufacturer allowlist
- **Custom** — user-uploaded blocklists

### 6.3 DNS Privacy Features
- DNSSEC validation enforced at Unbound
- Encrypted Client Hello (ECH) supported
- DNS-over-Tor mode (resolves through Tor's DNSPort, decoupling client from DNS provider)
- DNS-over-VPN (DNS forced through tunnel for VPN SSIDs)
- DNS rebinding protection
- Per-SSID DNS profile selection
- Per-device DNS override
- iptables forces all port 53/853 traffic to the Pi (no bypass)
- IPv6 DNS handled symmetrically

---

## 7. Privacy Modes (Per SSID or Per-Device)

### 7.1 VPN Providers (First-Class)
NordVPN, ExpressVPN, Mullvad, ProtonVPN, IVPN, Surfshark, AirVPN, plus Custom OpenVPN and Custom WireGuard slots. Each provider has its own credential entry, server list, and selectable protocol (OpenVPN/WireGuard) where supported.

### 7.2 Anonymity Networks
Tor (with full pluggable transports — obfs4, Snowflake, meek, WebTunnel, conjure), I2P (i2pd), Lokinet, Yggdrasil, CJDNS. Optional: Freenet, ZeroNet, IPFS gateway.

### 7.3 Censorship Bypass / Obfuscation Proxies
Shadowsocks (with v2ray-plugin and simple-obfs), V2Ray/Xray, Trojan/Trojan-Go, Hysteria2, NaiveProxy, Brook, Cloak, Psiphon, Lantern, Outline, mtproto-proxy. SOCKS5 proxies are transparently routed via `tun2socks`.

### 7.4 DPI Bypass Tools
GoodbyeDPI, zapret, DPITunnel, uTLS fingerprint randomization built into proxies that support it.

### 7.5 Multi-Hop Chains (Opt-In Advanced)
Up to 3 hops chained via network namespaces. Patterns: VPN → Tor, Tor → VPN, VPN A → VPN B, Proxy → VPN. UI warns about latency cost.

### 7.6 Tor Configuration
- Direct or Bridge mode
- Pluggable transport selectable: obfs4, Snowflake, meek, WebTunnel, conjure
- Bridge line management (add/save/delete/import-from-torproject.org)
- DNSPort + TransPort + ControlPort enabled
- Optional: Tor relay or bridge contribution mode

---

## 8. Network Hardening

### 8.1 Leak Prevention (Per-SSID, Independently Toggleable)
- DNS leak (port 53/853 forced to Pi)
- IPv6 leak (per-SSID disable when VPN is IPv4-only)
- WebRTC / STUN (3478, 3479, 5349, 5350)
- ICMPv6 leak filtering
- DHCPv6 leak filtering
- mDNS containment (per VLAN)
- LLMNR (5355)
- UPnP (1900)
- NetBIOS (137-139)
- Captive portal probe handling

### 8.2 Anti-Fingerprinting
- MAC randomization on `wlan0` per VPN connect (`macchanger`)
- TLS fingerprint randomization (uTLS) in supporting proxies
- TTL normalization (defeats OS fingerprinting)

### 8.3 Per-VLAN Kill Switch
Independent kill switch per VLAN; manual override (intentional unprotected mode) requires 2FA confirmation.

### 8.4 Firewall (UI-Driven)
Pre-built rule templates with plain-English labels, plus custom rule builder. Per-SSID firewall stance: Strict / Balanced / Open. Rate limiting per device. Optional Geo-IP blocklists.

---

## 9. Pi Hardening

### 9.1 System Level
- AppArmor enforcing on all privacy services
- unattended-upgrades for security patches
- CrowdSec with firewall + Flask bouncers
- SSH disabled by default; UI toggle to enable; key-only when on
- systemd hardening per service: `NoNewPrivileges=true`, `ProtectSystem=strict`, `ProtectHome=true`, `PrivateTmp=true`, `ProtectKernelTunables=true`, capability dropping
- Optional LUKS SD-card encryption
- Optional overlayroot (read-only root)
- Hardware watchdog
- auditd with rule set covering privacy-config files

### 9.2 Flask App Hardening
- TOTP 2FA mandatory for admin login
- Rate-limited login (CrowdSec-backed)
- CSRF on every state-changing request
- Strict CSP
- Secure, HttpOnly, SameSite=strict cookies
- HTTPS via self-signed cert (with optional Let's Encrypt path)
- Sudoers file whitelists ONLY specific scripts under `/opt/privacypi/scripts/`
- Flask runs as `privacypi` user, never root
- Audit log records every admin action
- Account lockout after N failed logins
- Session expiry (default 4h, configurable)

---

## 10. Flask Application

### 10.1 Architecture
- Python venv at `/opt/privacypi/venv/`
- App at `/opt/privacypi/app/`
- Gunicorn behind systemd unit
- SQLAlchemy with Alembic migrations
- SQLite at `/var/lib/privacypi/privacypi.db`
- Logs at `/var/log/privacypi/`
- Service scripts at `/opt/privacypi/scripts/` (sudoers-whitelisted)

### 10.2 Module Layout
```
/opt/privacypi/app/
├── __init__.py            ← app factory
├── config.py
├── extensions.py          ← db, login_manager, csrf, etc.
├── models/                ← SQLAlchemy models
├── routes/                ← blueprints
│   ├── auth.py
│   ├── dashboard.py
│   ├── ssid.py
│   ├── modes.py
│   ├── devices.py
│   ├── vpn.py
│   ├── tor.py
│   ├── anonymity.py
│   ├── proxies.py
│   ├── chains.py
│   ├── dns.py
│   ├── firewall.py
│   ├── parental.py
│   ├── iot.py
│   ├── wg_server.py
│   ├── diagnostics.py
│   ├── alerts.py
│   ├── services.py
│   ├── backup.py
│   ├── system.py
│   └── audit.py
├── services/              ← business logic
│   ├── service_manager.py ← systemctl wrapper
│   ├── network_manager.py ← iptables wrapper
│   ├── dns_manager.py
│   ├── vpn_manager.py
│   ├── tor_manager.py
│   ├── proxy_manager.py
│   ├── crypto.py          ← Fernet helpers
│   └── ssh_executor.py    ← sudo subprocess wrapper
├── templates/
└── static/
```

### 10.3 Page Inventory

1. First-boot wizard (no auth, available only when uninitialized)
2. Login (password + TOTP)
3. Dashboard (live status, devices, bandwidth, threats)
4. SSID Manager
5. Privacy Mode Selector (per SSID)
6. Per-Device Rules
7. VPN Provider Manager
8. Server Manager (drag-drop .ovpn upload)
9. Tor Configuration (bridges, transports)
10. Anonymity Networks
11. Proxy Configuration
12. Multi-Hop Chains
13. DNS & Privacy Settings (links to embedded AdGuard dashboard)
14. Firewall Rules
15. Parental Controls
16. IoT Profile manager
17. Diagnostics
18. Alerts & Notifications config
19. WireGuard Server (Pi as server, QR code config)
20. Optional services (Tor relay, Samba, etc.)
21. Backup & Restore
22. System (stats, updates, reboot, factory reset, recovery mode)
23. Audit Log viewer
24. Help / Docs

### 10.4 First-Boot Wizard Flow
1. On first boot, `setup_complete=false` flag triggers Setup mode.
2. Only `PrivacyPi-Setup` SSID broadcast (open, captive portal).
3. dnsmasq redirects all DNS to Pi → Flask captive portal page.
4. User walks through: Welcome/language → Admin password + TOTP QR → Home WiFi connect → Profile pick (Just Privacy / Maximum / Family / Power / Travel) → First VPN (or skip) → SSID enable → Done.
5. On completion, `setup_complete=true`, hostapd reloaded with production SSIDs, Setup SSID disabled.

---

## 11. Data Model (Key Tables)

| Table | Purpose |
|---|---|
| `users` | Admin accounts (password hash, TOTP secret) |
| `settings` | Global key-value config |
| `ssids` | SSID definitions (name, VLAN, subnet, password, mode, DNS profile, IPv6, isolation) |
| `vpn_providers` | Provider records (name, encrypted creds, protocol preference) |
| `vpn_servers` | Server entries (provider, country, city, filename, favourite) |
| `tor_config` | Bridge mode, transport, bridge lines |
| `anonymity_config` | Per-network settings (I2P, Lokinet, Yggdrasil, etc.) |
| `proxy_config` | Per-proxy settings |
| `chains` | Multi-hop chain definitions |
| `dns_config` | Per-SSID DNS profile, blocklists, upstream |
| `device_rules` | MAC → friendly name, override mode, schedule |
| `firewall_rules` | Custom rules table |
| `parental_rules` | Per-device schedules and time limits |
| `iot_allowlists` | Per-device allowlist of allowed FQDNs |
| `wg_clients` | WireGuard server peer configs |
| `alerts_config` | Notification destinations and trigger toggles |
| `audit_log` | Admin actions (timestamp, user, action, before/after) |
| `backups` | Backup history (timestamp, destination, size, encrypted) |
| `mode_state` | Current routing state per SSID + active modes |

---

## 12. Service Configuration Layout

```
/etc/privacypi/
├── vpn/
│   ├── nordvpn/{auth.txt, servers/}
│   ├── expressvpn/{auth.txt, servers/}
│   ├── mullvad/, protonvpn/, ivpn/, surfshark/, airvpn/
│   ├── custom-ovpn/, custom-wg/
├── wireguard/wg0.conf
├── wireguard-server/{wg-srv.conf, peers/}
├── tor/torrc
├── i2p/, lokinet/, yggdrasil/, cjdns/
├── shadowsocks/, v2ray/, trojan/, hysteria2/, naiveproxy/, brook/, cloak/, psiphon/
├── adguardhome/AdGuardHome.yaml
├── unbound/unbound.conf.d/privacypi.conf
├── hostapd/hostapd.conf
├── dnsmasq.d/privacypi.conf
├── crowdsec/
└── audit/
```

---

## 13. Layman UX Decisions

- **Default landing page** is the Dashboard, not settings — status-first.
- **Big visual cards** for mode selection.
- **Plain-English labels** with optional "What does this do?" expanders.
- **Tooltips** on every setting.
- **Color-coded risk indicators** (green/yellow/red) for privacy-sensitive toggles.
- **Mobile-first** responsive design — phone is the primary admin device.
- **Dark / light / auto** theme.
- **Internationalization scaffold** in place from day 1 (English first).
- **Preset profiles** apply dozens of settings with one click.
- **Search bar** across all settings and help.
- **In-app help docs** with examples.

---

## 14. Threat Model (User-Visible)

Documented prominently in the Help section.

**Protects against:** ISP surveillance, DNS snooping, ad/tracker profiling, DPI/censorship, local network compromise (with isolation + 2FA + CrowdSec), malware C2 and phishing (via DNS blocklists), Pi compromise via internet (kill switch + hardening).

**Does NOT protect against:** endpoint compromise (browser exploits, malware on the device itself), browser fingerprinting (handled at browser level, not router), malicious VPN provider (you trust the provider you choose), hardware attacks on the Pi, legal compulsion.

---

## 15. Backup, Recovery, Updates

### 15.1 Backup
- All config encrypted-at-rest in SQLite (key derived from admin password)
- Manual or auto-scheduled (default weekly)
- Format: encrypted ZIP via `age`
- Destinations: local download, USB drive, cloud (S3/B2/Backblaze via rclone)
- One-click restore (upload, decrypt, apply)

### 15.2 Recovery
- **Factory reset** wipes config and re-runs Setup wizard
- **Recovery mode** boots without privacy services for emergency access
- **Watchdog** restarts the Pi if hung

### 15.3 Updates
- VPN server lists auto-update weekly
- DNS blocklists auto-update daily
- Tor consensus handled by Tor itself
- System security patches via `unattended-upgrades`
- App updates via UI (`git pull` + `systemctl restart`)
- Update notifications + changelog in UI

---

## 16. Key Implementation Constraints

- **Sudoers whitelist is the only path Flask uses for privileged operations.** No NOPASSWD blanket — only specific script paths in `/opt/privacypi/scripts/`. Any new privileged action requires a new whitelisted script.
- **All credentials encrypted at rest** with a key derived from the admin password (re-derived in memory at login). Plaintext credentials never stored.
- **Service config files are written by Flask via the whitelisted scripts**, never directly. Atomic writes (write to `.tmp`, then rename).
- **iptables changes are applied via scripts** that always lock with `iptables-restore --table=*`-style atomic apply where supported.
- **Mode switches are transactional**: on failure, the previous state is reverted and the kill switch remains active.
- **All admin actions logged in `audit_log`** with before/after diffs.

---

## 17. Out of Scope (Explicit)

- Tor onion service hosting (could be added later as opt-in)
- Suricata / Zeek IDS (too heavy for Pi 4B)
- Hardware TPM / secure boot (Pi 4B doesn't support)
- Endpoint security (browser, application-level)
- Plausible deniability / hidden volumes
- Coercion-resistance features beyond standard

---

## 18. Success Criteria

The build is complete when:

1. A non-technical user can flash an SD card, boot the Pi, and complete first-time setup entirely from a phone browser — no SSH, no terminal, no edits to config files.
2. They can connect any device to any of the 6 SSIDs and the device's traffic is routed accordingly without further action.
3. They can switch a device's effective routing via per-device rules from the UI.
4. They can add or change VPN provider credentials, .ovpn files, or Tor bridges from the UI.
5. The kill switch on each SSID is verifiable: dropping the upstream tunnel blocks all forwarded traffic on that SSID without affecting other SSIDs.
6. DNS, IPv6, WebRTC, and ad-block leak tests pass on every SSID with privacy enabled.
7. The Pi survives a power cycle and all services come up automatically.
8. A full encrypted backup can be downloaded and successfully restored.
9. Factory reset returns the Pi to first-boot wizard state.

---

## 19. Phased Implementation (See TRACKER.md)

The build is divided into 15 phases, from Phase 0 (spec) to Phase 15 (release wrap). Each phase has a discrete checklist tracked in `TRACKER.md`. Phase boundaries are designed so progress is verifiable and the Pi remains in a working (or recoverable) state at each phase boundary.

---

## 20. Appendix: Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Edimax USB adapter doesn't support multi-SSID | Verify chipset (`rt2800usb` or similar); fall back to fewer SSIDs or add a second USB adapter |
| hostapd VLAN config fragility | Test exhaustively in Phase 3; document fallback to multiple hostapd instances |
| AdGuard Home + Unbound port conflicts with systemd-resolved | Disable systemd-resolved in Phase 1 |
| Flask exposed on local network without HTTPS | Self-signed cert mandatory + warning page on first access |
| Sudoers misconfig leaks privileged shell | Keep whitelist surgical; audit every script for argument injection; Flask must validate arguments before passing |
| VPN provider breaks `.ovpn` format | Custom slot accepts any `.ovpn` and `wg0.conf`; auto-update tries best-effort |
| Tor pluggable transports break upstream | Bridge fallback chain (obfs4 → Snowflake → meek → WebTunnel) |
| Pi SD card corruption | Auto-backup + recovery mode + watchdog |
| Admin forgets TOTP | Recovery codes generated at setup time; offline reset path documented |

---

## 21. Approvals

- [x] Architecture approved
- [x] Privacy mode catalog approved
- [x] DNS stack approved
- [x] UX flow approved
- [x] Pi hardening scope approved
- [ ] Final user spec review (pending)
- [ ] Implementation plan written (next step)

---

*End of specification.*
