# PrivacyPi — Plan 11: Diagnostics, Backup, Alerts

**Goal:** Three operational pieces: deeper diagnostics tools (DNS leak / IPv6 leak / WebRTC test), encrypted backup/restore (download a zip, restore from upload), and alerting via apprise (Telegram/email/ntfy/Discord).

---

## Tasks

1. **Diagnostics extras** — server-side leak checks (compare `/api/status` IP vs `dig +short myip.opendns.com @resolver1.opendns.com`), IPv6 reachability test, simple speed test (curl to a CDN measuring throughput)
2. **Backup**:
   - `backup-create.sh` — tars `/etc/privacypi/`, `/var/lib/privacypi/privacypi.db`, `/etc/tor/torrc`, encrypts with admin password via `age` or `openssl enc`
   - `backup-restore.sh` — reverse
   - Flask: `GET /api/backup/download` → file download; `POST /api/backup/restore` → multipart upload + apply
3. **Alerts**:
   - Settings table stores apprise URLs (encrypted)
   - Trigger points: VPN drop (kill switch armed), tunnel reconnect, login attempt, system update available
   - `alert.py` helper that renders + dispatches via apprise
4. **Verify**: backup roundtrip works, alert dispatch returns success, leak tests run

---

## Done

End state: operational tooling complete. Plan 12 = end-to-end + ship.

**Next:** Plan 12.
