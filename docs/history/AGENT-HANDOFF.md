> **Historical snapshot (May 2026).** Kept for reference only — IPs, ports and steps here may be stale. Current state lives in [`STATUS.md`](../../STATUS.md); setup in [`README.md`](../../README.md).

# Agent Handoff Document

> **Read this first if you are a new agent picking up this project mid-build.**
> Last updated: 2026-05-03 by Claude Opus 4.7
> Status: v1.0 shipped (140/140 verifications). Building Extensions A-D.

---

## What this project is

**PrivacyPi** — a privacy-focused WiFi router built on Raspberry Pi 4B. Devices connect to WiFi `PrivacyPi`, get DHCP from `10.10.10.x`, and route through chosen privacy mode (Direct / OpenVPN / WireGuard / Tor / Proxy / Killswitch). Admin via browser.

**Repo:** `/Users/mogli/Desktop/VPN/` on the user's Mac (macOS Darwin).
**Pi:** `192.168.1.155` reachable via SSH key as `privacypi@` (also `ubuntu@` fallback). Stored in `~/.privacypi-host`.
**Pi role:** AP on `wlan1` (Edimax USB) → broadcasts SSID `PrivacyPi`. WAN currently `eth0` (deferred wlan0-as-client to later phase).

---

## Critical context — read before doing anything

### 1. The user's communication style
- **Wants speed.** Earlier sessions pivoted from subagent-driven to inline execution because subagent overhead annoyed them.
- **Hates verbose explanations.** Give status, do work, commit, move on.
- **"Layman first" is the spec's prime directive.** Every UI decision optimizes for non-technical users.
- They will say "do all" and mean it. Don't ask "are you sure" repeatedly.
- They will explicitly ask for status updates if pace seems slow. Provide a status line every step.

### 2. Hardware constraints already discovered
- **WiFi adapters cap at 1 AP BSS each.** Both `rtl8192cu` (Edimax) and `brcmfmac` (Pi built-in) only support 1 simultaneous SSID per radio. Original spec called for 6 simultaneous SSIDs — **scoped to single SSID + per-MAC iptables overrides**.
- **macOS TCC blocks Bash tool from writing to `/dev/rdisk*`.** Disk imaging requires user runs `sudo dd` in their own Terminal (Bash agent's parent process lacks Full Disk Access).
- **Python on macOS lacks `crypt` module** (Python 3.13). Use `openssl passwd -6` for password hashes.
- **Sudoers files written from Mac via rsync show as uid 501.** Always `sudo chown root:root /etc/sudoers.d/privacypi && sudo chmod 440` after push.

### 3. Permission gotchas (you WILL hit these)
- `/etc/privacypi/` is `privacypi:privacypi 750` — `ubuntu` user can't read it (need `sudo`)
- `/opt/privacypi/scripts/` is `root:root 755` — Flask sudo's the scripts via sudoers whitelist
- Flask systemd unit has `ProtectSystem=strict` and `ReadWritePaths=/var/lib/privacypi /var/log/privacypi /run /etc/iptables /etc/privacypi /etc/tor` — extending to a new path requires updating the unit
- Flask runs as `privacypi` user, **not root**. Sudo is the bridge.
- `NoNewPrivileges=true` on systemd services breaks sudo — set `false` if the unit needs to spawn sudo

### 4. Flask app gotchas
- **Flask-WTF requires `Referer` header on HTTPS POSTs** — when testing via Python `requests`, always pass `Referer`
- **CSRF tokens come from two places**: form pages have `csrf_token()` in the form; AJAX uses `<meta name="csrf-token">` from base.html (read in JS, send as `X-CSRFToken` header)
- **Admin user has TOTP enabled** (set during wizard). Login is 2-step: `/login` (password) → `/2fa` (6-digit code). Test scripts use `pyotp.TOTP(secret).now()`.
- **`Response` must be imported in pages.py** for binary downloads. Already in current state.
- **`run_script` (text mode) corrupts binary data.** Use `run_script_bin` for backup file streams.

### 5. Network gotchas
- **iptables rules are persisted to `/etc/iptables/rules.v4` after every `route-mode.sh` call.** systemd service `privacypi-firewall` restores on boot.
- **`route-mode.sh` flushes `FWD-br-vlan10` and re-adds leak prevention rules every call.** Don't add iptables rules that need to survive — bake them into the script.
- **AdGuard Home owns port 53.** dnsmasq runs DHCP-only with `port=0`.
- **Tor TransPort is `127.0.0.1:9040`** (and `10.10.10.1:9040`). DNSPort `5353`. ControlPort `9051`.
- **`ip rule from 10.10.10.0/24 table 100`** — VLAN routing table is 100.

### 6. Don't trust unattended-upgrades during a build session
- It can hold the apt lock for 5+ minutes during a session, blocking other apt operations
- Wait for it to finish (`pgrep unattended` returns empty) before running `apt install`

---

## Credentials snapshot (current test deployment)

| Service | URL / Address | User | Auth |
|---|---|---|---|
| Flask Admin | https://192.168.1.155/ (Caddy → loopback Flask :8443) | `admin` | [redacted — see CREDENTIALS.local.md] ⚠️ reset 2026-05-04 + TOTP (secret [redacted — see CREDENTIALS.local.md], unchanged) |
| AdGuard Home | http://192.168.1.155:3000 | `admin` | [redacted — see CREDENTIALS.local.md] |
| WiFi | SSID `PrivacyPi` | — | [redacted — see CREDENTIALS.local.md] |
| SSH | `192.168.1.155` | `privacypi` (preferred) or `ubuntu` | SSH key |

> Mac-side files: `/tmp/privacypi-flask-creds.txt`, `/tmp/adguard-creds.txt`.

---

## Repo layout (mental model)

```
/Users/mogli/Desktop/VPN/
├── README.md                               ← published v1.0 readme
├── AGENT-HANDOFF.md                        ← THIS FILE
├── TRACKER.md                              ← session log + phase status
├── docs/
│   ├── superpowers/
│   │   ├── specs/2026-05-01-privacypi-design.md   ← original v2.0 spec
│   │   └── plans/                                  ← 12 base + 4 megaplans
│   └── ops/
│       ├── plan-01-runbook.md              ← SD card flash runbook
│       └── optional-hardening.md
├── system/etc/                             ← Pi /etc/ files mirrored
├── opt/privacypi/scripts/                  ← privileged shell helpers
│   └── route-mode.sh                       ← THE atomic mode switcher
├── app/                                    ← Flask app (deployed to Pi)
│   └── privacypi_app/
│       ├── __init__.py     ← app factory + wizard redirect hook
│       ├── auth.py         ← login + TOTP 2FA
│       ├── pages.py        ← all post-wizard routes
│       ├── wizard.py       ← 5-step first-boot wizard
│       ├── sse.py          ← /sse/status streaming endpoint
│       ├── models.py       ← User, Setting, AuditLog (SQLAlchemy)
│       ├── extensions.py
│       ├── config.py       ← ALLOWED_MODES, ALLOWED_SCRIPTS
│       ├── services/
│       │   ├── runner.py   ← sudo subprocess wrapper (text + binary modes)
│       │   └── crypto.py
│       └── templates/
│           ├── base.html   ← sidebar nav + CSRF meta
│           ├── login.html, totp.html
│           ├── wizard/
│           └── pages/
└── scripts/                                ← Mac-side deploy + verify
    ├── lib/ssh-helpers.sh                  ← pi_ssh, pi_rsync, pi_sudo
    ├── 00-system-update.sh ... 11-watchdog.sh
    └── verify-{foundation,network,dns,vpn,anonymity,proxies,
                 flask,wizard,ui,wiring,backup-leak}.sh
```

---

## Execution conventions (follow these)

### Deploy pattern
```bash
# Stage local file in repo
vim system/etc/<thing>/foo.conf

# Push to Pi via rsync with sudo
rsync -az --rsync-path="sudo rsync" -e ssh \
  system/etc/<thing>/foo.conf \
  $PI_USER@$PI_HOST:/etc/<thing>/foo.conf

# Fix ownership if needed
pi_ssh 'sudo chown root:root /etc/<thing>/foo.conf && sudo chmod 644 /etc/<thing>/foo.conf'

# Reload service
pi_ssh 'sudo systemctl restart <service>'

# Verify
pi_ssh 'sudo systemctl is-active <service>'
```

### Adding a new privileged script
1. Write the script in `opt/privacypi/scripts/`
2. Add it to `app/privacypi_app/config.py:ALLOWED_SCRIPTS`
3. Add it to `system/etc/sudoers.d/privacypi` (both NOPASSWD line and Defaults!)
4. Push, fix ownership, validate with `sudo visudo -c -f /etc/sudoers.d/privacypi`
5. Restart Flask

### Adding a new Flask page
1. Add a route to `app/privacypi_app/pages.py`
2. Add a template under `app/privacypi_app/templates/pages/<page>.html`
3. Add a sidebar link in `app/privacypi_app/templates/base.html`
4. Push, restart Flask
5. Test with the Python `requests` snippet in `scripts/verify-ui.sh`

### Verification pattern
Each plan ends with `scripts/verify-<plan>.sh`. The script uses `pi_ssh` and the `report` helper to run checks and tally pass/fail. **Aim for ≥10 checks per plan.**

### Commit message style
```
feat: execute Plan N — <name> (<X>/<Y> pass)

- bullet point what was added
- bullet point design decisions
- bullet point trade-offs

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

### Tag style
- `plan-NN-complete` after each plan
- `v1.0` at first ship; `v1.X` for extension batches

---

## Where we are now

### ✅ Done — v1.0 shipped (140 verifications passing)

| # | Plan | Status |
|---|---|---|
| 1 | Foundation (OS hardening) | ✅ 25/25 |
| 2 | Network & Routing (multi-SSID, kill switch) | ✅ 17/17 |
| 3 | DNS Stack (AdGuard + Unbound) | ✅ 14/14 |
| 4 | VPN Layer (OpenVPN + WireGuard scaffolding) | ✅ 23/23 |
| 5 | Anonymity Networks (Tor + I2P + Lokinet + Yggdrasil) | ✅ 16/16 |
| 6 | Censorship Bypass Proxies (shadowsocks/xray/tun2socks) | ✅ 10/10 |
| 7 | Flask App Core (auth + sudoers + SSE) | ✅ 9/9 |
| 8 | First-Boot Wizard (5 steps) | ✅ 5/5 |
| 9 | UI Core Pages (8 pages) | ✅ 11/11 |
| 10 | Wiring & Integration (creds, upload, password) | ✅ 5/5 |
| 11 | Diagnostics + Backup (encrypted backup) | ✅ 5/5 |
| 12 | Testing & Release | ✅ shipped, cold-boot tested |

### 🔄 In progress — Extensions

| # | Megaplan | Plans | Status |
|---|---|---|---|
| **A** | Network Visibility | 13 (devices) + 14 (per-device routing) + 15 (bandwidth) | 🔄 IN PROGRESS — vnstat installed |
| **B** | Operations | 16 (alerts) + 17 (speed test) + 21 (self-update) | ⏳ next |
| **C** | Travel + Automation | 18 (WG server) + 19 (auto-failover) + 20 (schedules) + 22 (split tunnel) | ⏳ queued |
| **D** | Privacy Maximalist | 23 (DNS-over-Tor + hnsd) + 24 (bridges) + 25 (fingerprint rotation) + 26 (LLM anomaly detection) | ⏳ queued |

### ⏳ Deferred — known follow-ups

- Plan 3.5: hnsd Handshake DNS (rolled into Megaplan D as Plan 23)
- Plan 11.5: apprise alerts + backup-restore UI (apprise rolled into Megaplan B as Plan 16)
- GoodbyeDPI / zapret kernel modules (defer until needed)

---

## How to resume mid-extension

If you are picking up Megaplan A:
1. Run `./scripts/verify-foundation.sh` first to confirm Pi is healthy. Should be 25/25.
2. Check `tail TRACKER.md` for last session log entry.
3. Last commit determines progress: `git log --oneline -5`.
4. Megaplan A's progress markers:
   - vnstat installed: `pi_ssh 'systemctl is-active vnstat'` → `active`
   - `list-clients.sh` exists: `pi_ssh 'test -x /opt/privacypi/scripts/list-clients.sh && echo OK'`
   - `/devices` page reachable: `curl -k https://192.168.1.155:8443/devices`
5. Continue from the next missing piece.

---

## Common debugging recipes

### Flask 500 errors
```bash
ssh privacypi@192.168.1.155 'sudo journalctl -u privacypi-flask -n 50 --no-pager'
```

### Sudo denied for script
```bash
ssh privacypi@192.168.1.155 'sudo visudo -c -f /etc/sudoers.d/privacypi'
ssh privacypi@192.168.1.155 'sudo -u privacypi sudo -n /opt/privacypi/scripts/<script>.sh args'
```

### iptables rules wrong after mode switch
```bash
ssh privacypi@192.168.1.155 'sudo iptables -L FWD-br-vlan10 -n -v && sudo iptables -t nat -L POSTROUTING -n -v && cat /var/lib/privacypi/active-vpn'
```

### Wizard stuck redirecting
```bash
ssh privacypi@192.168.1.155 '
sudo -u privacypi /opt/privacypi/venv/bin/python -c "
import sys; sys.path.insert(0, \"/opt/privacypi/app\")
from privacypi_app import create_app
from privacypi_app.extensions import db
from privacypi_app.models import Setting
app = create_app()
with app.app_context():
    s = db.session.get(Setting, \"setup_complete\")
    print(s.value if s else \"missing\")
"'
```

---

## Session-to-session etiquette

When you finish a session:
1. Update this file's "Where we are now" section
2. Add a session log entry to TRACKER.md
3. Commit and tag if a milestone (e.g., `plan-A-complete`)
4. Make sure `git status` is clean

Then leave a clear closeout message that includes:
- What was done
- What's next
- Any blockers / open questions for the user

---

## The one rule that supersedes everything

**The user has been in this build for hours. They want to see real progress. If you find yourself:**
- Writing more docs than code
- Asking the user for trivial confirmations
- Re-explaining things that have been decided
- Burning time on cosmetic edge cases

**...stop and ship something testable. Then iterate.** The user has explicitly said: "stop being naive, keep it simple."

---

*End of handoff. Build well.*
