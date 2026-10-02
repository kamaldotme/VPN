# PrivacyPi — Status

**Goal:** a layman downloads one image, flashes it, powers the Pi, joins the `PrivacyPi-Setup` WiFi
and finishes a short wizard — no terminal, SSH or monitor. Supported: Raspberry Pi 4 and 5.

**Where we are (v2.6.0):** the flashed image works on a real Pi 4 (tested 2026-10-02, no cable,
Edimax EW-7811Un plugged in): first boot, setup WiFi, wizard, restart, private WiFi, Tor mode and
.onion sites all worked. NordVPN (server auto-pick, Australia) connected from the dashboard and came
back by itself after a reboot.

## Hardware test results (Pi 4 + Edimax EW-7811Un, 2026-10-02)
- ✅ Built-in radio (brcmfmac) as access point; restarting it is safe.
- ✅ Edimax as the WiFi uplink to the home router (preset via `privacypi-config.txt`); survives the
  kernel swapping wlan0/wlan1 between boots.
- ✅ Wizard end to end, restart after Finish, clients online through Tor, .onion sites.
- ❌ **Edimax (rtl8192cu) as access point freezes the whole Pi** when hostapd is restarted — hence
  the role policy: built-in radio is always the AP, USB adapters are the uplink.
- ✅ NordVPN from the dashboard: connect, client exits in the chosen country, auto-reconnect after reboot.
- ⚠️ Setup page did not pop up by itself on an Android phone (had to open http://10.10.10.1).
  Suspected cause fixed (WiFi now starts only after the captive portal is ready) — needs a re-test.
- ✅ fixed: wizard Internet step "timeout" (wpa_cli cannot answer inside the dashboard sandbox).

## Done (code + container tests)
- [x] Port to Raspberry Pi OS Lite 64-bit (Debian 13); pure systemd-networkd.
- [x] Radio roles detected by capability at every boot (`net-roles.sh`) — no adapter model or MAC assumptions.
- [x] First-boot provisioning (`boot-init.sh` → `provision.sh`): per-device secrets, nothing baked into the image.
- [x] Setup mode: `PrivacyPi-Setup` WiFi (password `privacypi`), captive portal, no internet until the wizard is done.
- [x] New wizard over plain HTTP: password → internet → WiFi name/password/country → mode. Browser sets the Pi's clock.
- [x] VPN connect flow (`vpn-connect.sh`): OpenVPN + WireGuard, NordVPN server auto-pick, auto-reconnect,
      restore after reboot, blocked-not-leaked when the tunnel is down. (Before v2.6 nothing started a tunnel.)
- [x] Dashboard reachable only from the PrivacyPi WiFi; upstream network is firewalled off.
- [x] Encrypted upstream DNS (DNS-over-TLS) outside VPN tunnels.
- [x] WiFi name/password change, optional two-step login, factory reset (dashboard or SD card file).
- [x] Extras page: I2P / Yggdrasil / Lokinet installed on demand.
- [x] `build-image.sh`: flashable `.img.xz` from the official Raspberry Pi OS Lite image, Docker only.
- [x] Health report on the SD card's boot partition (`privacypi-status.txt`) for headless debugging.

## Test on a real Pi 4 — checklist
1. Flash `build/privacypi-2.6.0.img.xz` (Raspberry Pi Imager → Use custom; no customisation). Cable in, power on, wait ~2 min.
2. `PrivacyPi-Setup` appears → join with `privacypi` → setup page pops up (else http://10.10.10.1).
3. Finish the wizard → your WiFi appears ~15 s later → join it → a web page loads; an ad-heavy site shows no ads.
4. Dashboard http://10.10.10.1 → login `admin`.
5. Routing → Tor → https://check.torproject.org says you are using Tor → back to Direct.
6. VPN providers → NordVPN service credentials → Connect → public IP changes. Pull the Pi's cable for a minute: devices lose internet, then recover.
7. Reboot the Pi (power-cycle): WiFi and the VPN come back by themselves.
8. With the Edimax plugged in: Internet page → connect the Pi to home WiFi instead of the cable.
9. If anything fails: power off, put the card in the Mac, read `privacypi-status.txt` on `bootfs`.

## Known unknowns (only hardware can answer)
- Phone captive-portal pop-up behaviour (iOS / Android) — logic tested with the same probe URLs, not with real phones.
- First-boot timing on an SD card, and Raspberry Pi OS's own first-boot steps (root resize) together with ours.
- ExpressVPN: needs a real account; its config quirks are handled in `openvpn-run.sh` but unverified.

## Not in this release
- Background features from v2.x whose timers/services are **not enabled** in the image (never tested on a
  fresh install): anomaly detection, alert rules, daily digest, per-domain routing daemon, schedules,
  blocklist rotation, MAC rotation, VPN server-list refresh. Their dashboard pages load but stay idle.
- Over-the-air updates (`self-update.sh` is a placeholder). Updating = flashing a new image for now.
- 5 GHz access point, multiple SSIDs, split tunnelling, Handshake DNS.
- WAN choice lives in the wizard's Internet step and the Internet page; hot-plugging an adapter needs a reboot.
