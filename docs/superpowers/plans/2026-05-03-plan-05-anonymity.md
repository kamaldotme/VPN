# PrivacyPi — Plan 5: Anonymity Networks Implementation Plan

**Goal:** Install Tor (with all major pluggable transports), I2P, Lokinet, and Yggdrasil. Extend `route-mode.sh` with a `tor` mode that pins all client traffic through Tor's TransPort. End state: each anonymity network runnable as a service; Flask UI in Plan 9 lets the user pick a mode.

**Architecture:**
```
br-vlan10 → (route-mode.sh tor) → iptables REDIRECT to 127.0.0.1:9040
                                  → tor TransPort → Tor circuit → exit
                                  → DNS via Tor's DNSPort 5353
```

For Tor specifically: **all DNS goes through Tor too** (resolved via Tor's DNSPort), so AdGuard upstream changes from Unbound → Tor when in tor-mode.

I2P, Lokinet, Yggdrasil are runnable services — actual integration into routing comes in Plan 9 via Flask. This plan installs and verifies they all start cleanly.

---

## Tasks

1. **Install Tor + transports** (`apt install tor obfs4proxy`; build snowflake-client; verify meek)
2. **Configure Tor** — TransPort, DNSPort, ControlPort, no SocksPort exposed externally
3. **Install i2pd** (apt)
4. **Install Lokinet** (binary install from Oxen repo)
5. **Install Yggdrasil** (apt or binary)
6. **Extend `route-mode.sh`** — add `tor` mode that REDIRECTs to Tor TransPort
7. **Verify** all services installable and startable; Tor circuit reachable
8. **Tag** `plan-05-complete`

---

## Done

End state: 4 anonymity networks installed, `route-mode.sh tor` works (when Tor service is running), Flask UI can flip them in Plan 9.

**Next:** Plan 6 — Censorship Bypass Proxies.
