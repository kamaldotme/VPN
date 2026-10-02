# PrivacyPi developer guide

How PrivacyPi 2.6.0 is put together, how to build and test it, and the traps already found. Everything
here describes the code in this repository. Where something is untested, it says so.

For the user-facing view see [USER-GUIDE.md](USER-GUIDE.md). Current state and open items are in
[STATUS.md](../STATUS.md). Material under `docs/history`, `docs/superpowers` and `docs/ops` describes
an older Ubuntu-based version and is not current.

## Contents

- [Overview](#overview)
- [Repository layout](#repository-layout)
- [Files on the device](#files-on-the-device)
- [Boot sequence](#boot-sequence)
- [Radio role detection](#radio-role-detection)
- [Setup mode and the captive portal](#setup-mode-and-the-captive-portal)
- [Routing modes and the firewall](#routing-modes-and-the-firewall)
- [DNS chain](#dns-chain)
- [VPN connect flow](#vpn-connect-flow)
- [The Flask app](#the-flask-app)
- [Privileged scripts and the sandbox](#privileged-scripts-and-the-sandbox)
- [Adding a privileged script](#adding-a-privileged-script)
- [Building the image](#building-the-image)
- [The fast development loop](#the-fast-development-loop)
- [Tests](#tests)
- [Coding conventions](#coding-conventions)
- [Known pitfalls](#known-pitfalls)
- [Inactive and legacy code](#inactive-and-legacy-code)

---

## Overview

PrivacyPi is Raspberry Pi OS Lite 64-bit (Debian 13 "trixie") plus:

- **systemd-networkd** for all interfaces (NetworkManager, dhcpcd, systemd-resolved and the stock
  `wpa_supplicant.service` are disabled and masked).
- **hostapd** for the access point, **dnsmasq** for DHCP only (`port=0`).
- **AdGuard Home → Unbound → DNS-over-TLS** for DNS.
- **iptables** for the firewall and NAT; one policy-routing table (100) for client egress.
- **OpenVPN** and **WireGuard** (`wg-quick`) clients, **Tor** as a transparent proxy.
- **Caddy** in front of a **Flask** app (gunicorn) for the dashboard and the setup wizard.
- A set of root-owned shell scripts in `/opt/privacypi/scripts` that do all privileged work. The
  Flask app calls them through `sudo`.

Design rules that show up everywhere:

- Nothing device-specific is baked into the image. Secrets are generated on first boot.
- Interface roles are detected by capability at every boot, never by adapter model, name or MAC.
- All host-specific facts live in `/etc/privacypi/site.conf`, read through `scripts/lib/site.sh`
  (shell) and `services/site.py` (Python).
- A headless user must always have a way back in: the SD card's boot partition carries rescue
  options and a health report.

## Repository layout

```
install.sh                 installer: image-build mode and developer mode
build-image.sh             host side of the image build (Docker only)
tools/build-image-inner.sh runs inside the build container
tools/dev-push.sh          rsync the tree to a running Pi and re-run install.sh
VERSION                    version string, copied to /opt/privacypi/VERSION
app/                       Flask app (privacypi_app/), wsgi.py, requirements.txt
  privacypi_app/wizard.py    setup wizard blueprint (/setup/…)
  privacypi_app/pages.py     dashboard pages and JSON API
  privacypi_app/auth.py      login, TOTP, lockout
  privacypi_app/config.py    Flask config, ALLOWED_MODES, ALLOWED_SCRIPTS
  privacypi_app/services/    runner.py (sudo wrapper), site.py, crypto.py, audit_chain.py, …
  privacypi_app/templates/   base.html (sidebar), pages/, wizard/
opt/privacypi/scripts/     privileged helpers, deployed to /opt/privacypi/scripts
system/                    files deployed to the device
  boot/privacypi-config.txt  rescue/developer options (goes to the boot partition)
  etc/systemd/system/        privacypi-*.service and *.timer
  etc/sudoers.d/privacypi    what the dashboard user may run as root
  etc/privacypi/             site.conf.example, Unbound forwarder variants
  etc/…                      dnsmasq, unbound, tor, caddy, sysctl, chrony snippets
  opt/AdGuardHome/           AdGuardHome.yaml.template
tests/                     hardware-free tests
scripts/                   legacy (see "Inactive and legacy code")
docs/                      this documentation, plus historical material
```

## Files on the device

| Path | Content |
|---|---|
| `/opt/privacypi/{app,scripts,system,venv,VERSION}` | Installed code. `app` is owned by `privacypi`, `scripts` and `system` by root. |
| `/etc/privacypi/site.conf` | Roles, WAN mode, SSID, country, subnets, ports. |
| `/etc/privacypi/setup-complete` | Flag file: the wizard has finished. |
| `/etc/privacypi/.provisioned` | Flag file: first-boot provisioning ran. |
| `/etc/privacypi/{master.key,secret.key,secret.env,alert.secret}` | Per-device secrets (`root:privacypi`, 640). |
| `/etc/privacypi/wifi-psk.txt` | AP passphrase. `privacypi` until the wizard replaces it. |
| `/etc/privacypi/adguard.creds`, `adguard.cred` | AdGuard Home admin user and random password (two lines, and `user:password` for API calls). |
| `/etc/privacypi/vpn/<provider>/{auth.txt,servers/}` | Saved VPN credentials and config files. |
| `/etc/privacypi/vpn/active.{ovpn,auth}` | Sanitised profile used by `privacypi-openvpn.service`. |
| `/var/lib/privacypi/privacypi.db` | SQLite database (users, settings, audit log, …). |
| `/var/lib/privacypi/active-vpn` | JSON state: current mode, provider, server, out interface. |
| `/var/log/privacypi/mode.log` | One line per routing-mode change. |
| `/etc/hostapd/hostapd.conf` | Rendered by `ap-config.sh` only. |
| `/etc/systemd/network/20-privacypi-*.{netdev,network}`, `30-privacypi-wifi-wan.network` | Rendered by `net-roles.sh`. |
| `/etc/unbound/unbound.conf.d/privacypi-forward.conf` | Upstream forwarder, switched by `route-mode.sh`. |
| `/boot/firmware/privacypi-config.txt` | Rescue/developer options read by `boot-init.sh`. |
| `/boot/firmware/privacypi-status.txt` | Health report written by `diag.sh`. |

## Boot sequence

Units enabled in the image (`ENABLE_UNITS` in `install.sh`): `privacypi-init`, `systemd-networkd`,
`unbound`, `dnsmasq`, `hostapd`, `AdGuardHome`, `tor`, `chrony`, `avahi-daemon`, `caddy`,
`privacypi-firewall`, `privacypi-vpn-up`, `privacypi-setup-mode`, `privacypi-wan-watch`,
`privacypi-flask`, `privacypi-diag.timer`.

Order, as declared in the unit files and the drop-ins written by `install.sh`:

| Step | Unit | What runs | Ordering |
|---|---|---|---|
| 1 | `privacypi-init.service` | `boot-init.sh` | `DefaultDependencies=no`; after `local-fs.target`, udev settle and `boot-firmware.mount`; before `network-pre.target`, networkd, hostapd, dnsmasq, unbound, AdGuardHome, caddy, flask, firewall, tor. Timeout 120 s. |
| 2 | `systemd-networkd` | Brings up bridge `br-vlan10` (10.10.10.1/24), DHCP on the wired uplink (metric 50) and on the WiFi-WAN radio (metric 100). | after init |
| 3 | `privacypi-firewall.service` | `firewall-base.sh`, then `routing-vlan.sh` | after init and networkd; deliberately **not** after `network-online` |
| 4 | `privacypi-vpn-up.service` | `vpn-connect.sh restore` — re-applies the saved routing mode and restarts a saved tunnel | after and requires firewall |
| 5 | `privacypi-setup-mode.service` | `setup-mode.sh on` (captive rules, starts `privacypi-setup-dns.service`) | after vpn-up, before hostapd; only if `/etc/privacypi/setup-complete` is absent |
| 6 | `unbound`, `AdGuardHome`, `dnsmasq`, `caddy`, `tor@default`, `privacypi-flask` | DNS, DHCP, web | after init; flask also after firewall; AdGuardHome only if its yaml exists |
| 7 | `hostapd` | The WiFi appears | after **all** of: firewall, vpn-up, setup-mode, setup-dns, dnsmasq, caddy, flask, AdGuardHome |
| 8 | `privacypi-wan-watch.service` | `wan-watch.sh` loop | after vpn-up |
| 9 | `privacypi-diag.timer` | `diag.sh` 75 s after boot, then hourly | |

hostapd is last on purpose: a phone that joins the setup network before the captive portal is ready
decides "no internet" and never shows the sign-in page (seen on hardware).

### What `boot-init.sh` does

1. Reads `privacypi-config.txt` from the boot partition. `reset=yes` runs `factory-reset.sh` and
   comments the line out.
2. Ensures `site.conf` exists, then runs `net-roles.sh apply` (waiting up to 15 s for a radio).
3. `admin_on_wan=yes|no` sets `ADMIN_ON_WAN` in `site.conf` (not one-shot).
4. `ssh_password=…` sets the password of user `pi`, gives it passwordless sudo, enables and starts
   `ssh.service`, then comments the line out.
5. `wifi_ssid` + `wifi_password` (≥ 8 chars), optional `wifi_country`: if a spare radio exists,
   writes `wpa_supplicant-<iface>.conf` with a hashed PSK, sets `WAN_MODE=wifi`, re-runs
   `net-roles.sh`, comments out the password line.
6. If WiFi-WAN is configured, enables and starts `wpa_supplicant@<iface>` for this boot.
7. Runs `provision.sh`.

### What `provision.sh` does

Idempotent; existing files are kept. Generates `master.key` (Fernet), `alert.secret`, `secret.key`,
`secret.env`; writes the default `wifi-psk.txt`; creates the VPN provider directories; seeds
`AdGuardHome.yaml` from the template with a random admin password (bcrypt hash in the yaml, plaintext
in `adguard.creds`, and as `user:password` in `adguard.cred` for scripts that call its API); renders the Caddyfile; installs the DoT forwarder for Unbound if none is
present; runs `ap-config.sh render`; touches `.provisioned`.

### Wizard finish

`setup-finish.sh <direct|tor>` touches the setup flag and schedules itself 4 s later via
`systemd-run` (so the final page reaches the browser, and so the work runs outside the dashboard
sandbox). The delayed run turns setup mode off, applies the routing mode, renders `hostapd.conf`,
writes a status report, and **reboots**. It reboots rather than restarting hostapd in place because
some WiFi drivers do not survive that. `PRIVACYPI_NO_REBOOT=1` restarts hostapd instead.

## Radio role detection

`net-roles.sh` decides three roles and writes them to `site.conf`:

| Role | Meaning |
|---|---|
| `ETH_IFACE` | Wired uplink. If none is seen, the previous name (default `eth0`) is kept. |
| `AP_IFACE` | Radio that broadcasts the PrivacyPi WiFi. |
| `WIFI_WAN_IFACE` | Spare radio that can join an upstream WiFi. Empty with a single radio. |

Policy:

- A radio is "built-in" if its bus is `sdio`, `platform` or `mmc`; anything else is an add-on.
- AP capability is read from `iw phy <phy> info` ("Supported interface modes" contains `AP`).
- The built-in radio is the AP whenever it supports AP mode. An external radio takes the AP role
  only if there is no AP-capable built-in radio.
- The first other radio becomes the WiFi-WAN client, AP-capable or not.
- `ROLE_LOCK=1` in `site.conf` keeps the configured roles.
- If WiFi-WAN was active and its radio was renamed by the kernel (wlan0/wlan1 swap), the
  `wpa_supplicant-<iface>.conf` file and the unit follow the new name. If the radio is gone,
  `WAN_MODE` falls back to `ethernet`.

Why built-in first: the Edimax EW-7811Un (rtl8192cu) froze a Pi 4 whenever hostapd was restarted on
it. Station mode on the same adapter is fine. Do not add code paths that prefer a USB radio for the AP.

The script also renders the networkd files and keeps `interface=`/`bridge=` in `hostapd.conf` in
step. `net-roles.sh detect` prints the detected roles without changing anything. Hot-plugging an
adapter needs a reboot.

The access point itself (`ap-config.sh render`): 2.4 GHz (`hw_mode=g`, channel `AP_CHANNEL`, 802.11n
when the radio reports HT20), WPA2-PSK/CCMP, `ap_isolate=1`. WPA3 transition mode and 802.11w are
only written when `AP_HARDEN=1` and the radio supports them.

## Setup mode and the captive portal

Setup mode is "the file `/etc/privacypi/setup-complete` does not exist" (shell: `setup_done`), plus
the `setup_complete` setting in the database for Flask.

- `setup-mode.sh rules`: the LAN forward chain rejects everything (no internet through the publicly
  known setup network); all DNS (UDP/TCP 53) from the bridge is redirected to port 5354; TCP 80 is
  redirected to the Pi's port 80.
- `privacypi-setup-dns.service` runs a second dnsmasq on port 5354 that answers every name with
  `10.10.10.1`.
- Caddy's `:80` site accepts any Host header and proxies to Flask.
- Flask's `before_request` hook (`__init__.py`): while setup is pending, a request for a foreign
  host gets `302 → http://10.10.10.1/setup/`; anything else outside `/setup` and `/static` is
  redirected to the wizard. That redirect of the OS connectivity probes
  (`captive.apple.com`, `connectivitycheck.gstatic.com`, …) is what makes phones open the sign-in sheet.
- `route-mode.sh` calls `setup-mode.sh rules` at the end, so a mode change during setup cannot
  un-captive the network.

The wizard blueprint (`wizard.py`, prefix `/setup`): `welcome` (country → `ap-config.sh country`),
`clock` (browser epoch → `set-time.sh`), `admin` (creates/updates user `admin`), `internet`
(`wan-config.sh status|scan|set-wifi`), `wifi` (`ap-config.sh set`, stored now, applied by the
reboot), `mode`, `done` (`setup-finish.sh`). Once setup is complete every `/setup` route returns
404. Steps after `admin` require the session that set the password.

## Routing modes and the firewall

### Base firewall (`firewall-base.sh`)

- `INPUT` → chain `PP-INPUT`: accept loopback, established, everything from the LAN bridge and
  `wg-srv`, ICMP, DHCP client (UDP 68), the WireGuard server port (UDP `WG_PORT`), TCP 22 (sshd is
  off unless enabled); TCP 80/443 from anywhere only if `ADMIN_ON_WAN=1`; then DROP.
- IPv6: INPUT restricted the same way, FORWARD policy DROP. IPv6 is disabled on the bridge by sysctl.
- `FORWARD` policy DROP. LAN traffic goes through chain `FWD-<bridge>`.
- DNS to any address other than the Pi (UDP/TCP 53) is DNATed to the Pi.
- Always dropped in FORWARD: STUN/TURN ports (3478, 3479, 5349, 5350), SSDP (1900), NetBIOS
  (137–139), LLMNR (5355).

### Modes (`route-mode.sh <mode> [provider] [server]`)

The script flushes the LAN forward chain and both NAT chains, re-adds the forced-DNS rules, applies
the mode, rewrites routing table 100, picks the Unbound forwarder, and saves state to
`/var/lib/privacypi/active-vpn` and `/etc/iptables/rules.v4`.

| Mode | Forward chain | NAT | Table 100 default | Unbound upstream |
|---|---|---|---|---|
| `direct` | accept out `WAN_IFACE` | masquerade on WAN | via WAN gateway | DoT |
| `openvpn` | accept out `tun0` only | masquerade on `tun0` | via `tun0` (if up) | plain :53 in tunnel |
| `wireguard` | accept out `wg0` only | masquerade on `wg0` | via `wg0` (if up) | plain :53 in tunnel |
| `tor` | reject | TCP SYN (not to the Pi) → `TOR_TRANS_PORT` 9040; UDP 53 → `TOR_DNS_PORT` 5353 (inserted first) | via WAN gateway | DoT |
| `proxy` | accept out `tun0` (tun2socks) | masquerade on `tun0` | via WAN gateway | DoT |
| `killswitch` | established only | none | none | DoT |

The VPN kill switch is by construction: in `openvpn`/`wireguard` mode the only accept rule points
at the tunnel interface, so a missing tunnel means no forwarding.

`wan-watch.sh` runs every 5 s. If the default route in table 100 no longer matches the uplink
(cable plugged in later, DHCP gave a new gateway, WiFi-WAN reconnected, `tun0` came back) it
re-applies the current mode. It also asks AdGuard Home to refresh its block lists until they have
been downloaded once.

`wan-config.sh` switches the uplink. `set-wifi` validates association, DHCP and a ping to 1.1.1.1
within 25 s and rolls back to the previous mode on failure.

## DNS chain

```
client ──(any :53 is DNATed to the Pi)──► AdGuard Home  10.10.10.1:53   block lists, 24 h query log
                                              │
                                              ▼
                                          Unbound  127.0.0.1:5335        DNSSEC, QNAME minimisation, no logging
                                              │
                    ┌─────────────────────────┴──────────────────────────┐
                    ▼                                                    ▼
   DNS-over-TLS to 1.1.1.1 / 9.9.9.9 (:853)             plain :53 to the same resolvers
   direct, tor, proxy, killswitch modes                 openvpn, wireguard modes (inside the tunnel)
```

- Plain DNS inside VPN tunnels is deliberate: some providers (NordVPN) block port 853, and the
  tunnel already encrypts it.
- In **Tor mode**, client UDP 53 is redirected to Tor's DNSPort before the DNAT rule, so AdGuard
  Home is bypassed. Tor's `AutomapHostsOnResolve` answers `.onion` names with addresses from
  `10.192.0.0/10`, which the TransPort maps back to the onion service.
- AdGuard Home returns no AAAA records (`aaaa_disabled`), and rewrites `privacypi.local` and
  `privacypi.lan` to the gateway for clients without mDNS.
- DoH to public resolvers is **not** blocked by default. `dns-trap.sh` can do that
  (`DOH_BYPASS_IPS`), but nothing enables it in the image.
- The blocking level on the "DNS & ad blocking" page is applied by `dns-profile.sh` through AdGuard
  Home's HTTP API on `127.0.0.1:3000` (which lists are enabled, safe browsing, parental, safe search).
- The Pi itself resolves through `127.0.0.1` (`/etc/resolv.conf`).
- In setup mode the captive dnsmasq on port 5354 takes over (see above).

## VPN connect flow

`vpn-connect.sh` is the only thing that starts or stops a tunnel.

1. Credentials: `vpn-write.sh auth <provider> <user> <pass>` writes `/etc/privacypi/vpn/<p>/auth.txt`.
   Config upload: `vpn-write.sh server <p> <name> <base64>` (≤ 200 kB, `.ovpn` or `.conf`).
2. `vpn-connect.sh up <provider> [file]` picks `current.ovpn` if that symlink exists, otherwise the
   newest file in `servers/`. `*.conf` means WireGuard, anything else OpenVPN.
3. `vpn-connect.sh nord [country-id]` asks NordVPN's API for the recommended `openvpn_udp` server,
   downloads its `.ovpn`, then continues as `up`.
4. **OpenVPN:** the file is sanitised (every directive that runs code, writes files elsewhere, or
   overrides device/auth/logging is stripped), installed as `active.ovpn`, and
   `privacypi-openvpn.service` (`openvpn-run.sh`) is started. The script waits up to 40 s for an
   address on `tun0`, watching the journal for `AUTH_FAILED` (exit 2) and `Options error` (exit 3).
5. **WireGuard:** `DNS=` and hook lines are stripped, the result becomes `/etc/wireguard/wg0.conf`,
   `wg-quick@wg0` is enabled and started, and a handshake is awaited for 15 s.
6. On success `route-mode.sh <kind> <provider> <file>` switches routing. On failure the previous
   mode is restored (or `direct` if the previous mode was itself a VPN) and a plain-language error
   is returned as JSON.
7. `privacypi-openvpn.service` has `Restart=always`, so a dropped tunnel is retried forever while
   clients stay blocked. `openvpn-run.sh` forces `tun0`, ignores pushed IPv6, widens `data-ciphers`,
   tolerates options removed in OpenVPN 2.6, and sets `--ping 15 --ping-restart 60`.
8. On boot, `vpn-connect.sh restore` applies the saved routing first (clients blocked, not leaked),
   then starts OpenVPN without blocking; `wan-watch.sh` completes the client route when `tun0`
   appears. `wg-quick@wg0` is an enabled unit and comes up by itself.

Verified: NordVPN on hardware; a generic username/password OpenVPN server in `tests/e2e.sh`.
Not verified: ExpressVPN and other real providers, and the WireGuard path.

## The Flask app

- `gunicorn` binds `127.0.0.1:8443` (plain HTTP), 2 workers × 4 threads, as user `privacypi`.
- **Caddy** serves `:80` (any host) and an HTTPS site for `privacypi.local`, `10.10.10.1` (and
  `HOST_IP` if set) with `tls internal`. There is no HTTP→HTTPS redirect. The root certificate is
  served at `/pi-root.crt` for the "Trust this device" page.
- `ProxyFix` trusts one hop of `X-Forwarded-*` from Caddy.
- Blueprints: `auth` (`/login`, `/2fa`, `/logout`), `pages` (dashboard pages and `/api/…`), `sse`,
  `wizard` (`/setup/…`).
- Sessions: `SchemeAwareSessionInterface` uses cookie `pp_session` over HTTP and
  `__Secure-pp_session` over HTTPS, because a Secure cookie cannot be set over HTTP.
  `SameSite=Strict`, 4-hour lifetime. An optional remember cookie lasts 30 days.
- Login: bcrypt password, optional TOTP, lockout after 5 failures per source IP in 15 minutes. The
  login identity includes a fingerprint of the password hash (`User.get_id`), so changing the
  password signs out every other session.
- CSRF: Flask-WTF. Forms carry `csrf_token`; `fetch` calls use `csrfHeaders()` from `base.html`
  (`X-CSRFToken` + `Referer`).
- Database: SQLite via Flask-SQLAlchemy, tables created with `db.create_all()` at start. There are
  no migrations in use.
- Audit: `_audit()` writes an `AuditLog` row chained with HMAC-SHA256 over the previous row
  (`services/audit_chain.py`).
- Templates load no external resources; `tests/e2e.sh` checks this.
- The sidebar in `templates/base.html` defines which pages users see. `/privacy`, `/advanced`,
  `/schedule` and `/anomalies` exist as routes but are not linked.

## Privileged scripts and the sandbox

The app never runs anything as root directly.

1. `services/runner.py: run_script(name, args, stdin=None, timeout=30)` looks `name` up in
   `Config.ALLOWED_SCRIPTS`, rejects arguments that are not printable ASCII strings, and runs
   `sudo -n <path> <args…>` without a shell.
2. `/etc/sudoers.d/privacypi` lets user `privacypi` run exactly the listed scripts (and a few fixed
   `systemctl` commands) as root without a password.
3. Secrets go through **stdin**: the script takes `-` in place of the secret and reads it
   (`ap-config.sh set <ssid> -`, `wan-config.sh set-wifi <ssid> -`). This keeps them out of
   `/proc/<pid>/cmdline`.
4. Scripts answer with one JSON object on stdout, usually `{"ok":true,…}` or
   `{"ok":false,"error":"plain-language message"}`.

`privacypi-flask.service` is sandboxed: `ProtectSystem=strict`, `ProtectHome=true`,
`PrivateTmp=true`, and an explicit `ReadWritePaths=` list. **Scripts started through sudo stay inside
this sandbox.** Consequences:

- A script can only write to paths in `ReadWritePaths` (currently `/var/lib/privacypi`,
  `/var/log/privacypi`, `/run`, `/etc/iptables`, `/etc/privacypi`, `/etc/tor`, `/etc/wireguard`,
  `/etc/wpa_supplicant`, `/etc/systemd/network`, `/etc/hostapd`, `/etc/unbound/unbound.conf.d`,
  `/boot/firmware`, `/etc/chrony/conf.d`, `/var/lib/tor`). Writing elsewhere fails with "read-only file system",
  even as root.
- `/tmp` is private to the service. Tools that exchange sockets through `/tmp` do not work
  (see `wpa_cli` below).
- Work that needs the whole system (apt in `extras.sh`, the reboot in `setup-finish.sh`, factory
  reset) is handed to `systemd-run`, which runs it as a transient unit outside the sandbox.
- `NoNewPrivileges` must stay `false`, or sudo cannot work.

## Adding a privileged script

1. Create `opt/privacypi/scripts/<name>.sh`. Start with `set -uo pipefail` and
   `source /opt/privacypi/scripts/lib/site.sh`. Take interfaces, subnets and ports from there.
   Validate every argument. Print JSON.
2. Add it to `ALLOWED_SCRIPTS` in `app/privacypi_app/config.py`.
3. Add its path to `system/etc/sudoers.d/privacypi` (mind the `, \` line continuations;
   `install.sh` refuses an invalid file via `visudo -cf`).
4. If it writes outside the current `ReadWritePaths`, add the path to
   `system/etc/systemd/system/privacypi-flask.service` (prefix `-` if the path may not exist), or
   move that part of the work behind `systemd-run`.
5. Call it with `run_script("<name>", [...], stdin=secret)` from a `@login_required` route, and
   record the action with `_audit()`. Never put secrets in the audit detail.
6. If it is a new systemd unit that must start at boot, add it to `ENABLE_UNITS` in `install.sh`.
   The preset file disables every other `privacypi-*` unit on first boot.
7. Add a check to `tests/e2e.sh`.

`install.sh` marks every `*.sh` and `*.py` in the scripts directory executable.

## Building the image

```bash
./build-image.sh      # → build/privacypi-<version>.img.xz and .sha256
```

Requirements: Docker (macOS or Linux), running. Nothing else. On a non-ARM host Docker must be able
to run `linux/arm64` containers (emulation), which is slow.

What happens:

1. `build-image.sh` downloads the pinned base image
   (`2026-09-15-raspios-trixie-arm64-lite.img.xz`) into `build/cache` and verifies its SHA-256.
2. It starts a privileged `debian:trixie` arm64 container with the repo mounted read-only and a
   Docker volume as scratch space.
3. `tools/build-image-inner.sh` unpacks the image, grows the root partition by 2200 MB, mounts both
   partitions, and runs `install.sh` in a chroot with `PRIVACYPI_IMAGE_BUILD=1`.
4. In image-build mode `install.sh` installs everything but generates no secrets and starts nothing.
5. Cleanup: apt caches, logs, SSH host keys and the random seed are removed; `machine-id` is put back
   to its never-booted value.
6. A verification step fails the build if any secret, `hostapd.conf`, the database, host keys or an
   initialised machine-id is left in the image, or if gunicorn, AdGuard Home or
   `privacypi-config.txt` is missing.
7. The root filesystem is shrunk to its minimum plus 300 MB, the partition table is rewritten, and
   the image is compressed with xz.

Flash with Raspberry Pi Imager → **Use custom**, answering **No** to OS customisation, or with
balenaEtcher. Bumping the base image or the pinned third-party versions (`AGH_VER`, `SS_VER`,
`XRAY_VER`, `T2S_VER` in `install.sh`) should be followed by a hardware re-test.

### Developer install on a running Pi

On Raspberry Pi OS Lite 64-bit:

```bash
git clone <this-repo> privacypi && cd privacypi
sudo bash install.sh && sudo reboot
```

Developer mode provisions immediately. Network changes take effect at the reboot, so an SSH session
is not cut. `install.sh` is idempotent; its log is `/var/log/privacypi-install.log`.

## The fast development loop

No image rebuild and no reflash:

1. On the SD card's `bootfs` partition, edit `privacypi-config.txt` and set
   `ssh_password=<something>`. Boot the Pi. User `pi` can now log in over SSH and has passwordless
   sudo. The firewall accepts port 22 on every interface, so this works from the PrivacyPi WiFi
   (`ssh pi@10.10.10.1`) and from the upstream network. Use this on development devices only.
2. `tools/dev-push.sh` uses the key `~/.ssh/privacypi_dev`. Create it and copy it over once:

   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/privacypi_dev
   ssh-copy-id -i ~/.ssh/privacypi_dev.pub pi@<pi-address>
   ```

3. Push the working tree:

   ```bash
   tools/dev-push.sh <pi-address>
   ```

   It rsyncs the tree to `/tmp/privacypi-src` on the Pi, re-runs `install.sh` there (about a
   minute; the Pi needs internet for `apt-get update`), reloads systemd and restarts
   `privacypi-flask`. Changes to networking, units or the firewall need a reboot to take effect.

Useful on the device:

```bash
journalctl -b -u privacypi-init          # boot-init, net-roles, provision output
/opt/privacypi/scripts/net-roles.sh detect
sudo /opt/privacypi/scripts/vpn-connect.sh status
sudo /opt/privacypi/scripts/diag.sh      # rewrite the status report now
cat /var/lib/privacypi/active-vpn /var/log/privacypi/mode.log
```

The journal is persistent (capped at 60 MB), so a crash leaves evidence for the next boot.

## Tests

All tests run in Docker. None needs a Pi.

| Test | Command | What it does |
|---|---|---|
| End to end | `tests/e2e.sh` (`--keep` leaves the container running) | Builds `tests/Dockerfile.e2e` (Debian 13 + systemd + `install.sh` in image-build mode), boots it with systemd as PID 1 as a never-booted image, and plays a WiFi client from a network namespace bridged onto the LAN. |
| End to end on the real image | `./build-image.sh && tests/e2e-image.sh` | Extracts the root filesystem from `build/privacypi-<version>.img.xz` and runs the same e2e suite against that userland. Catches differences between plain Debian and Raspberry Pi OS. |
| Radio roles | see below | Runs `net-roles.sh` against a fake sysfs and a fake `iw`. |

```bash
docker run --rm -v "$PWD":/repo:ro debian:trixie-slim bash -c \
  "mkdir -p /opt/privacypi && cp -r /repo/opt/privacypi/scripts /opt/privacypi/ && bash /repo/tests/test-net-roles.sh"
```

`tests/e2e.sh` covers, in order: first-boot provisioning and that nothing stray got enabled; LAN
bridge and firewall; DHCP for the client; captive DNS and the redirect of Apple/Android probes; the
whole wizard including validation; the reboot after Finish; SSID, password and country applied;
real DNS, NAT and ad blocking; login and every sidebar page; the kill switch; Tor mode
(`check.torproject.org`); VPN connect against a local OpenVPN server (`tests/vpn-server.sh`) with
wrong and right passwords, a broken config, config sanitising, tunnel drop (client blocked),
automatic reconnect, restore after a container restart, disconnect; WAN-side ports closed;
`wan-watch` repairing table 100; factory reset; the status report containing no passwords.
It needs internet access and privileged containers.

`tests/test-net-roles.sh` cases: Pi only; Pi plus AP-capable USB adapter; USB adapter without AP
mode; swapped interface names; no radio at all; WiFi-WAN following a rename; adapter unplugged;
external-only radio; `ROLE_LOCK=1`.

**Not covered by any test:**

- Anything involving a real radio: hostapd, drivers, firmware, the Pi kernel.
- Whether real phones pop up the captive-portal sheet.
- First-boot timing on an SD card together with Raspberry Pi OS's own first-boot steps.
- WiFi-WAN (`wan-config.sh scan` / `set-wifi`) and the SD-card WiFi preset.
- Real VPN providers, the NordVPN API path, and the WireGuard client path.
- Backup/restore, Extras installation, proxies, the WireGuard travel server, per-device routing,
  two-step login, and every inactive feature.

There is no Python unit-test suite in the repository at present.

## Coding conventions

Taken from the existing code; follow them in new code.

**Shell**

- `#!/usr/bin/env bash`, `set -uo pipefail` (add `-e` only where every failure should abort).
- A header comment with purpose, usage lines and any safety behaviour.
- `source /opt/privacypi/scripts/lib/site.sh`; never hardcode interface names, subnets or ports.
  Change `site.conf` with `site_conf_set KEY VALUE`.
- Idempotent. Write files atomically (`mktemp` then `install -m … -o … -g …`).
- JSON on stdout for anything the dashboard calls. Error text is written for end users.
- Validate arguments with a strict regex before use. Secrets on stdin, not argv.
- Paths and tools overridable by environment where a test needs it (`SYSFS`, `IW`, `SITE_CONF`, …
  in `net-roles.sh`).
- Comments explain *why*, especially when the reason was found on hardware or in a test.

**Python / Flask**

- Routes are thin: validate input, call `run_script`, `_audit`, return JSON.
- Every state-changing route is `@login_required`, CSRF-protected and audited.
- No external assets in templates (fonts, scripts, CDNs).
- User-visible wording is plain language. Refer to pages by their sidebar names.

**General**

- Pin third-party downloads to a version.
- Do not add a unit, timer or feature to the image "enabled but untested". Leave it disabled and
  list it in `STATUS.md`.
- Commit subjects follow `type: summary` (`fix: …`, `feat(v2.6.0): …`).

## Known pitfalls

Each of these is recorded in a code comment and cost time once.

| Area | Pitfall |
|---|---|
| Unbound | After switching the forwarder file, **restart** Unbound. A reload does not load the TLS certificate bundle, so DoT silently fails (`route-mode.sh`, checked in `tests/e2e.sh`). |
| `wpa_cli` | It opens its reply socket under `/tmp`. The dashboard has `PrivateTmp`, so the answer never arrives and each call hangs about 10 s (the wizard's "timeout" on hardware). `wan-config.sh` uses `iw dev <if> link` instead. |
| First-boot presets | On the very first boot of an image systemd applies unit presets and **enables every installed unit that no preset disables** (caddy-api, chronyd-restricted, rsync… came up in tests). `install.sh` writes `95-privacypi.preset` listing what to enable and `disable *` for the rest. A new unit must be added to `ENABLE_UNITS`. |
| Boot ordering | `systemctl enable` during boot does not add a unit to the boot already under way. `boot-init.sh` and `net-roles.sh` also `start --no-block` the `wpa_supplicant@` unit. |
| hostapd ordering | hostapd must start after the captive portal, DNS, DHCP and dashboard. Otherwise early phones conclude "no internet" and never show the sign-in page. |
| hostapd restart | Restarting hostapd on the Edimax EW-7811Un (rtl8192cu) froze the Pi. The built-in brcmfmac radio restarts safely. The wizard therefore finishes with a reboot. |
| Radio names | The kernel may swap `wlan0`/`wlan1` between boots, and the built-in radio's firmware loads asynchronously. Roles are re-detected every boot and `NET_ROLES_WAIT` waits for a radio. |
| Clock | A Pi 4 has no battery clock. With a wrong clock DNSSEC and TLS fail, which blocks DNS, which blocks NTP. Mitigations: the wizard posts the browser's time (`set-time.sh`), and chrony has NTP servers by IP address. |
| Block lists | AdGuard Home downloads its lists at start and does not retry for 24 h if there was no internet. `wan-watch.sh` triggers a refresh once the uplink works. |
| OpenVPN options | `--ignore-unknown-option` only applies to options after it, so it must precede `--config` (`openvpn-run.sh`). |
| DNS in tunnels | NordVPN blocks port 853 inside the tunnel, hence plain DNS in VPN modes. |
| Tor | Tor binds `0.0.0.0` so it can start before the bridge has its address; the firewall limits access to the LAN. In Tor mode traffic to the Pi itself is exempt from the redirect, or the dashboard becomes unreachable. |
| Cookies | A Secure cookie cannot be set over HTTP and a non-Secure cookie may not overwrite a Secure one of the same name; hence one cookie name per scheme. |
| gunicorn workers | Workers race to create tables on a new database; `create_app` retries `db.create_all()`. |
| Image build | The image must look never-booted (machine-id `uninitialized`, no SSH host keys), or root-resize and per-device IDs break. `policy-rc.d` prevents services starting in the chroot. Loop devices on a macOS bind mount are unreliable, so the build uses a Docker volume. |
| AdGuard tarball | It ships world-writable; `install.sh` fixes ownership and modes. |
| networkd wait-online | Overridden to `--any --timeout=15`, so boot does not stall two minutes without a cable. |
| e2e VPN test on Docker Desktop | Docker Desktop hands the VPN server packets with unverified checksums, which a userspace tunnel delivers broken. TCP to real internet hosts through the test tunnel therefore fails; the test uses a local web container "beyond" the VPN server instead. |
| Secrets in argv | `vpn-write.sh auth` and `backup-create.sh`/`backup-restore.sh` still receive passwords as arguments. New code should use stdin. |

## Inactive and legacy code

- **Units shipped but not enabled** (never tested on a fresh install): `privacypi-anomaly`,
  `privacypi-alert-rules`, `privacypi-daily-digest`, `privacypi-domain-router`,
  `privacypi-schedule`, `privacypi-rotate-blocklists`, `privacypi-mac-rotate`,
  `privacypi-vpn-health`, `privacypi-vpn-update`. Their dashboard pages load but stay idle.
- **`self-update.sh`** is a placeholder. Updating means flashing a new image.
- **`scripts/`** at the repository root (`00-system-update.sh` … `verify-*.sh`) are SSH-driven
  provisioning and verification scripts from the earlier version. `install.sh` does not use them.
- **`system/etc/ssh/sshd_config.d/10-privacypi.conf`**, the apt and audit snippets under
  `system/etc` are copied to `/opt/privacypi/system` but are not installed into `/etc` by
  `install.sh`.
- Many scripts in `opt/privacypi/scripts` behind the unlinked `/privacy` and `/advanced` pages
  (`dns-trap.sh`, `ntp-trap.sh`, `ap-harden.sh`, `captive-portal.sh`, `onion-ssh.sh`,
  `wstunnel.sh`, …) and behind parts of the System page (`onion-admin.sh`, `doh-server.sh`,
  `tether-wan.sh`) were carried over and have not been re-verified on 2.6.0.
