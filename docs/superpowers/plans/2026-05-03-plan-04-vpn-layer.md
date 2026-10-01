# PrivacyPi — Plan 4: VPN Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** Install and scaffold OpenVPN + WireGuard with multi-provider support (NordVPN, ExpressVPN, Mullvad, ProtonVPN, IVPN, Surfshark, AirVPN, plus custom OpenVPN/WireGuard slots). Build the **routing integration** that lets the Flask UI (Plan 9) flip `FWD-br-vlan10` from direct (`eth0`) to a VPN tunnel (`tun0` / `wg0`) with kill-switch enforcement. **No actual VPN credentials are entered in this plan** — that comes in Plan 9 via the UI.

**Architecture:**
```
                    ┌── tun0 (OpenVPN) ──┐
br-vlan10 (clients)─┼── wg0  (WireGuard) ┼── eth0 → home router → Internet
                    └── direct ──────────┘
                       (raw, current default)

Switch is owned by /opt/privacypi/scripts/route-mode.sh <mode>
  modes: direct | openvpn | wireguard | killswitch
```

**Tech Stack:** openvpn, wireguard-tools, macchanger (already in Plan 1), systemd unit templates, iptables (already in place), provider config scaffolding.

---

## File Structure

```
system/etc/
├── privacypi/
│   ├── vpn/
│   │   ├── nordvpn/    {auth.txt placeholder, servers/, README}
│   │   ├── expressvpn/
│   │   ├── mullvad/
│   │   ├── protonvpn/
│   │   ├── ivpn/
│   │   ├── surfshark/
│   │   ├── airvpn/
│   │   ├── custom-ovpn/
│   │   └── custom-wg/
│   └── wireguard/
│       └── wg0.conf.example
└── systemd/system/
    ├── privacypi-vpn-up.service     ← oneshot to start active mode on boot
    └── privacypi-mode.target        ← group target

opt/privacypi/scripts/
├── route-mode.sh           ← THE switcher: direct | openvpn | wg | killswitch
├── vpn-status.sh           ← latency, public IP, server detection
├── vpn-pre-up.sh           ← MAC spoof, save current state
└── vpn-post-down.sh        ← restore state, leak check

scripts/
├── 16-deploy-vpn.sh        ← orchestrator
└── verify-vpn.sh           ← infrastructure checks (no creds needed)
```

---

## Task 1 — Install OpenVPN + WireGuard

- [ ] `apt install openvpn wireguard wireguard-tools resolvconf openvpn-systemd-resolved`
- [ ] Verify both have systemd units available
- [ ] Disable any auto-started services (we control start via Flask)

## Task 2 — Provider Config Scaffolding

For each of 9 providers (Nord, Express, Mullvad, Proton, IVPN, Surfshark, AirVPN, custom-ovpn, custom-wg):

- [ ] Create `/etc/privacypi/vpn/<provider>/` with mode 750 owned by privacypi:privacypi
- [ ] Add `README.md` documenting expected file layout (where `.ovpn`, `auth.txt`, `wg.conf` go)
- [ ] Add empty `servers/` subdir for `.ovpn` config files
- [ ] Add `auth.txt.example` showing format (username on line 1, password on line 2)

## Task 3 — Routing Switcher (`route-mode.sh`)

This is the core script the Flask UI will call.

- [ ] Write `route-mode.sh <mode>` where mode is one of: `direct`, `openvpn`, `wireguard`, `killswitch`
- [ ] Each mode rewrites the `FWD-br-vlan10` chain atomically:
  - **direct**: allow output to `eth0`
  - **openvpn**: only allow output to `tun0` (kill switch implicit if `tun0` not present)
  - **wireguard**: only allow output to `wg0`
  - **killswitch**: drop everything
- [ ] Each mode also rewrites `POSTROUTING` MASQUERADE target accordingly
- [ ] Each mode updates routing table 100 default route
- [ ] Logs the change to `/var/log/privacypi/mode.log`

## Task 4 — VPN Up/Down Hooks

- [ ] `vpn-pre-up.sh`: runs before tunnel starts. Random MAC on `wlan0` if user opted in. Save current `default route` for post-down restore.
- [ ] `vpn-post-down.sh`: runs after tunnel stops. Verifies traffic is in killswitch state before restoring direct.
- [ ] Wire into OpenVPN config: `up`, `down`, `script-security 2` directives
- [ ] Wire into wg-quick: `PostUp`, `PostDown`

## Task 5 — Active Provider State Tracking

- [ ] Create `/var/lib/privacypi/active-vpn` JSON file:
  ```json
  {"provider": null, "mode": "direct", "since": null, "server": null}
  ```
- [ ] `route-mode.sh` updates this whenever it switches
- [ ] Set ownership privacypi:privacypi 644 (Flask reads it; user-data only)

## Task 6 — VPN Status Helper

- [ ] `vpn-status.sh`: prints
  - active mode
  - tunnel interface state (`tun0` / `wg0` if present)
  - current public IP (via short-timeout curl to `ifconfig.me`)
  - latency to gateway
  - tunnel uptime
- [ ] Used by Flask Dashboard widget (Plan 9)

## Task 7 — Server List Auto-Update

- [ ] systemd timer `privacypi-vpn-update.timer`: runs weekly Sunday 03:00
- [ ] Service: `privacypi-vpn-update.service` runs a script that:
  - For each provider with credentials present, downloads/refreshes server list (provider-specific URL)
  - Falls back to no-op if creds missing or URL fails
- [ ] Best-effort, never blocks boot

## Task 8 — Boot-Time Mode Restore

- [ ] systemd unit `privacypi-vpn-up.service` runs at boot, reads `/var/lib/privacypi/active-vpn`, calls `route-mode.sh` with the persisted mode
- [ ] If a tunnel was active before reboot, this brings it back

## Task 9 — Verification Suite

- [ ] Check OpenVPN + WireGuard packages installed
- [ ] Check all 9 provider directories exist with correct perms
- [ ] Check `route-mode.sh` exists and is executable
- [ ] Test mode switching: `direct` → `killswitch` → `direct`
- [ ] Verify `FWD-br-vlan10` chain rewrites correctly per mode
- [ ] Verify `/var/lib/privacypi/active-vpn` is updated
- [ ] No actual VPN connect tested here (no creds yet) — Plan 9 covers that

## Task 10 — Tracker + Tag

- [ ] Mark Phase 6 complete in TRACKER.md
- [ ] Tag `plan-04-complete`

---

## Done

End state: VPN tunnel infrastructure ready for credentials. Flask UI in Plan 9 will populate `auth.txt` files, drop `.ovpn` configs into `servers/`, and call `route-mode.sh openvpn` to flip routing.

**Next:** Plan 5 — Anonymity Networks (Tor + bridges, I2P, Lokinet, Yggdrasil).
