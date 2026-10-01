# PrivacyPi — Plan 7: Flask App Core

**Goal:** Stand up the Flask backend that the UI plans will build on. Auth (password + TOTP), SQLite + SQLAlchemy, sudoers-whitelisted privileged-script invocation, SSE live status, audit log. End state: Flask serves a basic "Hello, $username" page after login, can call `route-mode.sh` via the wrapper, audit log records every action.

**Architecture:**
```
Browser → https://10.10.10.1 (self-signed)
  → Gunicorn :443
    → Flask app
      ├── /login, /logout, /2fa
      ├── /api/mode/<m>          (POSTs that wrap route-mode.sh)
      ├── /api/status            (calls vpn-status.sh)
      ├── /sse/status            (live updates)
      └── /api/audit             (audit log viewer)

systemd: privacypi-flask.service runs Gunicorn as the privacypi user.
sudoers: privacypi may run /opt/privacypi/scripts/* without password.
```

**Tech Stack:** Flask 3.x, Flask-Login, Flask-WTF (CSRF), pyotp (TOTP), bcrypt, SQLAlchemy 2.x, Alembic (migrations), Gunicorn, Werkzeug, cryptography (Fernet at-rest), apprise (notifications, Plan 11).

---

## File Structure

```
/opt/privacypi/app/                   (deployed from app/ in repo)
├── pyproject.toml
├── requirements.txt
├── alembic.ini
├── migrations/
│   └── env.py
├── privacypi_app/
│   ├── __init__.py             ← app factory
│   ├── config.py
│   ├── extensions.py
│   ├── models.py               ← User, Setting, AuditLog
│   ├── auth.py                 ← login + TOTP
│   ├── api.py                  ← mode/status endpoints
│   ├── sse.py                  ← Server-Sent Events
│   ├── services/
│   │   ├── runner.py           ← sudo subprocess wrapper
│   │   └── crypto.py           ← Fernet helpers
│   ├── templates/              ← base + login (Plan 8/9 add more)
│   └── static/
└── wsgi.py
```

```
system/etc/
├── privacypi/sudoers           → /etc/sudoers.d/privacypi
├── systemd/system/privacypi-flask.service
└── ssl/privacypi/              ← self-signed cert
```

---

## Tasks (high-level)

1. **Create app skeleton** — pyproject, requirements, app factory, config, models, migrations
2. **Auth** — User model with bcrypt + TOTP fields; /login, /2fa-setup, /2fa-verify, /logout
3. **Sudoers whitelist** — `privacypi` can run `route-mode.sh`, `proxy-up.sh`, `proxy-down.sh`, `vpn-status.sh`, `firewall-base.sh` only, NOPASSWD
4. **Runner service** — `services/runner.py` wraps subprocess with safe arg validation
5. **Audit log middleware** — every POST/PUT/DELETE writes a row to `audit_log`
6. **Mode endpoints** — `POST /api/mode/<m>` validates m in allowed set, calls runner
7. **Status endpoints** — `GET /api/status` returns vpn-status.sh JSON
8. **SSE channel** — `GET /sse/status` pushes JSON every 5s
9. **Self-signed HTTPS cert** — generated at `/etc/ssl/privacypi/`
10. **Gunicorn systemd unit** — runs as `privacypi` user
11. **First-boot admin bootstrap** — on initial DB migration, create admin user with random password (printed to journal once)
12. **Verification suite** — login flow, mode switch via API, audit row written, SSE channel responds

---

## Done

End state: Flask backend operational. Plan 8 builds the first-boot wizard; Plan 9 builds the rest of the UI.

**Next:** Plan 8 — First-Boot Wizard.
