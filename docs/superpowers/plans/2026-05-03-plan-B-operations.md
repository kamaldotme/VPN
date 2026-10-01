# Megaplan B — Operations (Plans 16+17+21)

> Per superpowers:executing-plans, this is the work order. Each task ends with verification.

**Goal:** Three operational features that make the router maintainable and observable: apprise notifications for incidents, in-UI speed test, in-UI self-update.

**Tech:** apprise (already installed), speedtest-cli, git pull + systemctl restart.

---

## Task 1: Apprise alerts infrastructure

### Files
- Create: `app/privacypi_app/services/alerts.py`
- Modify: `app/privacypi_app/models.py` (add AlertConfig table)
- Create: `app/privacypi_app/templates/pages/alerts.html`
- Modify: `app/privacypi_app/pages.py` (add /alerts route + APIs)
- Modify: `app/privacypi_app/templates/base.html` (sidebar nav)

### Steps
1. Add `AlertConfig` model: `id, label, url (encrypted), trigger_set (JSON), enabled`
2. `alerts.py`: `send(message, level)` reads enabled configs and dispatches via apprise
3. Wire into existing audit points: `mode.killswitch` triggers alert, `login.password.fail` (3 in 10min) triggers alert
4. UI: list configs, add new (label + URL + which triggers), test button
5. `POST /api/alerts/test/<id>` sends "test from PrivacyPi"

### Verification
- AlertConfig table exists in DB
- `/alerts` page renders
- Test alert via curl returns 200 with body containing "queued"

## Task 2: Speed test in UI

### Files
- Create: `opt/privacypi/scripts/speedtest.sh`
- Modify: `app/privacypi_app/config.py` (add to ALLOWED_SCRIPTS)
- Modify: `system/etc/sudoers.d/privacypi` (whitelist)
- Modify: `app/privacypi_app/templates/pages/diagnostics.html` (add speed test card)
- Modify: `app/privacypi_app/pages.py` (add /api/speedtest endpoint)
- Add: `SpeedTestResult` model

### Steps
1. Install `speedtest-cli` via apt on Pi
2. `speedtest.sh` runs `speedtest-cli --json` and prints
3. Wire `/api/speedtest` POST endpoint that runs script with 60s timeout
4. UI: button on diagnostics, show download/upload/ping in card
5. Save results to DB for historical view

### Verification
- speedtest-cli installed
- /api/speedtest returns JSON with download/upload keys
- Result saved to DB

## Task 3: Self-update from UI

### Files
- Create: `opt/privacypi/scripts/self-update.sh`
- Modify: `app/privacypi_app/config.py` (ALLOWED_SCRIPTS)
- Modify: `system/etc/sudoers.d/privacypi`
- Modify: `app/privacypi_app/pages.py` (/api/system/update-check, /api/system/update-apply)
- Modify: `app/privacypi_app/templates/pages/system.html` (add Updates card)

### Steps
1. `self-update.sh check` — runs `git fetch && git log HEAD..origin/main --oneline | head -20`. Returns JSON with `commits_behind`, `messages`.
2. `self-update.sh apply` — `git pull && pip install -r requirements.txt && systemctl restart privacypi-flask`
3. UI: "Check for updates" button → shows diff. "Apply update" button (confirm) → applies.

### Verification
- update-check returns JSON with `commits_behind`
- check via UI works
- (Don't actually apply during test; just smoke the endpoint)

---

## Task 4: Megaplan B verification suite

`scripts/verify-megaplan-B.sh` runs:
- alerts: page renders, AlertConfig table exists, test endpoint reachable
- speedtest: binary installed, /api/speedtest reachable, returns JSON
- update: /api/system/update-check returns valid JSON

Aim for 8+ checks.

---

## Done

Tag `plan-B-complete`. Update TRACKER.
