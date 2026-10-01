# Megaplan A — Network Visibility (Plans 13+14+15)

**Goal:** Connected devices widget, per-device routing override, bandwidth tracking. End state: dashboard shows live list of devices on PrivacyPi WiFi with vendor name, current routing override, and bandwidth chart.

**Tasks:**
1. Install vnstat for per-interface bandwidth
2. Pi-side `list-clients.sh` reads dnsmasq leases + arp + MAC OUI vendor DB → JSON
3. Pi-side `device-route.sh` — atomic per-MAC iptables override
4. Flask `/devices` page with live SSE table
5. Per-device override action: `POST /api/device/<mac>/mode/<m>` → writes ipset rule
6. Bandwidth widget on dashboard via vnstat JSON
7. Verify

**Tag:** plan-A-complete
