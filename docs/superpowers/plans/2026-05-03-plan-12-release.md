# PrivacyPi — Plan 12: Testing & Release

**Goal:** Run the full verification suite end-to-end, smoke test the cold-boot path (reboot Pi, verify everything comes back up automatically), update TRACKER with release status, write a README, tag `v1.0`.

---

## Tasks

1. Run **all** verify scripts in sequence: foundation → network → DNS → VPN → anonymity → proxies → flask → wizard → UI → wiring → backup-leak. Aggregate results.
2. **Cold boot test**: reboot the Pi, wait for it to come back, verify all services up, hostapd broadcasting, AdGuard responding, Flask reachable.
3. Add a top-level `README.md` summarizing the project, setup steps, repo layout.
4. Final TRACKER cleanup.
5. Tag `v1.0`.

---

## Done

End state: shipped.
