# PrivacyPi — Status

One privacy router on a Raspberry Pi. Devices join the `PrivacyPi` WiFi (Edimax `wlan1`); the Pi
reaches the internet by **Ethernet or WiFi** (chosen in the admin app) and routes traffic through
**Direct / VPN / Tor / Proxy / Killswitch**, with ad-blocking encrypted DNS. Install with
`sudo bash install.sh` on a fresh Ubuntu Server 24.04 Pi.

Single source of truth for host facts: `/etc/privacypi/site.conf` → `opt/privacypi/scripts/lib/site.sh`
→ Flask. Nothing is hardcoded to one Pi.

## Works (code complete, offline-validated)
- All privileged scripts derive interfaces/subnets from `site.conf` (no hardcoded eth0/IPs).
- **WAN selector**: `/network` page + `wan-config.sh` — Ethernet ⇄ WiFi-client, scan nearby
  networks, ~25s validate + auto-rollback to Ethernet if WiFi fails (can't lock you out).
- **`install.sh` provisions a fresh Pi end to end**: probes interfaces → writes `site.conf` →
  installs packages incl. WiFi-client tools, **AdGuard Home** (seeded config → Unbound), and
  proxy binaries (sslocal/xray/tun2socks) → applies network configs → disables systemd-resolved
  → enables the full stack (AP, DHCP, DNS, firewall, Direct-mode routing, TLS, UI). Idempotent.
- Routing modes, VPN provider config, Tor, DNS pages call the right scripts. Nav decluttered.
- Offline checks pass: `bash -n` all scripts, sudoers `visudo -c`, AdGuard YAML valid, Flask
  imports + all core routes present + context vars wired.

## Left to do (needs the Pi)
- [ ] Run the on-Pi bring-up checklist below; fix anything the hardware surfaces.
- [ ] Test ExpressVPN end to end with a real account (only NordVPN has been verified live).
- [ ] Re-create `app/tests/test_wan_api.py` — only a compiled `.pyc` of it was ever committed (now removed).
- [ ] Optional: add the WiFi-WAN choice into the first-boot wizard (today it's on the
      Internet page right after the wizard — fully functional, just one extra click).

## On-Pi bring-up checklist (run when you have the Pi)
1. Flash Ubuntu Server 24.04 → `sudo bash install.sh` → reboot.
2. Join the `PrivacyPi` WiFi (password: `sudo cat /etc/privacypi/wifi-psk.txt`).
3. Open `https://privacypi.local/` → finish the wizard (set admin password).
4. Load any site → confirm ads are blocked.
5. **Internet page** → switch WAN to WiFi (good creds works; wrong creds auto-rolls back to Ethernet).
6. **Modes** → Direct → VPN → Tor; confirm the public/exit IP changes each time.
7. Arm/disarm the kill switch; confirm client internet stops/resumes.
