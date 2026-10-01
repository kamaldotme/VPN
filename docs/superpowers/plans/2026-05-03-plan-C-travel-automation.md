# Megaplan C — Travel + Automation (Plans 18+19+20+22)

**Goal:** Make the privacy stack useful when you're not at home (WG server) and automate routine privacy decisions (failover, schedules, split tunnel).

## Tasks
1. **WireGuard server** — Pi acts as WG server. UI generates per-device peer configs + QR code. User scans on phone, gets routed through Pi's privacy stack from anywhere.
2. **Multi-VPN auto-failover** — health-check script polls active VPN. On drop, tries next OpenVPN config. On final fail, arms killswitch + sends alert.
3. **Time-based schedules** — DB table + cron-style timer. "Tor 22:00-07:00 daily" etc.
4. **Per-app split tunnel** — DNS-pattern based. Set domain → mode mapping (e.g. netflix.com → direct, all else → openvpn). Implemented via dnsmasq tags + per-tag iptables MARK + ip rule.
