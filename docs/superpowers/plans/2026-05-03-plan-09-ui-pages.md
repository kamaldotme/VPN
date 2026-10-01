# PrivacyPi — Plan 9: Flask UI Core Pages

**Goal:** Build the post-wizard admin UI. End state: every privacy-stack feature is configurable from the browser — no SSH, no editing config files. Each page wires to real backend services already built in Plans 1-7.

**Architecture:** Same Flask app + new blueprints. Pages render Bootstrap 5 cards; mode switches use HTMX-style fetch calls; live data via SSE.

---

## Page Inventory

1. **Dashboard** — current mode, public IP, bandwidth (placeholder), connected devices (from `arp`), DNS query stats (AdGuard API), AdGuard rule count
2. **Mode Selector** — visual cards for {Direct, VPN (NordVPN/Express/etc), Tor, Proxy, Killswitch}; one-click switch
3. **VPN Providers** — list 9 provider slots, per-provider username/password, drag-drop `.ovpn` upload, server dropdown
4. **Tor Configuration** — direct vs bridge mode, transport selector (obfs4/snowflake/meek/WebTunnel), bridge line editor
5. **DNS Settings** — pick AdGuard upstream, pick filtering profile (Light/Standard/Strict/Family/IoT), embedded link to AdGuard's web UI on :3000
6. **Diagnostics** — buttons that run `dig`, `traceroute`, `mtr`, `ping`, `dnsleaktest.com`, `browserleaks.com/webrtc` from the Pi and show output
7. **System** — CPU/RAM/temp (live), uptime, restart Flask, reboot Pi, factory reset, change admin password, regenerate TOTP
8. **Audit Log** — paginated viewer

---

## Tasks

1. Move `api.py` into a proper `pages/` blueprint structure (refactor)
2. Add page blueprints: dashboard, modes, vpn, tor, dns, diagnostics, system, audit
3. Add `/api/` endpoints each page calls (mostly POST handlers + JSON GETs)
4. Templates per page using Bootstrap 5 cards + a sidebar nav
5. Verify each page renders + each backend action fires correctly

---

## Done

End state: full admin UI usable. Plan 10 (Wiring) hardens edge cases and per-device rules; Plan 11 adds diagnostics + alerts; Plan 12 tests + ships.

**Next:** Plan 10 — Wiring & Integration.
