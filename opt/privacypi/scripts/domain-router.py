#!/usr/bin/env python3
"""Per-domain split routing daemon.

Polls AdGuard's query log (in-memory API) every few seconds. For each query
whose host matches a row in `domain_routes` table, take the resolved IP(s)
and add them to the ipset matching that mode (e.g. `pp_route_tor`,
`pp_route_vpn`, `pp_route_proxy`). The ipsets are already wired into the
firewall by route-mode.sh — adding an IP routes that destination via the
selected egress, regardless of the LAN client.

Usage:
  domain-router.py                # run continuously
  domain-router.py --once         # single sweep then exit (for cron testing)
"""
from __future__ import annotations
import json, os, subprocess, sys, time
import urllib.request, urllib.parse, base64

POLL_S = 5
ADG_URL = "http://127.0.0.1:3000/control/querylog?limit=200"
CRED_FILE = "/etc/privacypi/adguard.cred"
DB_PATH = "/var/lib/privacypi/privacypi.db"

# ipset name per mode (keep in sync with route-mode.sh)
SET_FOR_MODE = {
    "tor":    "pp_route_tor",
    "vpn":    "pp_route_vpn",
    "proxy":  "pp_route_proxy",
    "killswitch": "pp_route_drop",
    # 'direct' = no override needed
}


def adg_get():
    if not os.path.exists(CRED_FILE):
        return []
    with open(CRED_FILE) as f:
        cred = f.read().strip()
    auth = "Basic " + base64.b64encode(cred.encode()).decode()
    req = urllib.request.Request(ADG_URL, headers={"Authorization": auth})
    try:
        with urllib.request.urlopen(req, timeout=4) as r:
            return json.loads(r.read()).get("data", [])
    except Exception as e:
        print(f"adg fetch error: {e}", file=sys.stderr)
        return []


def load_routes():
    """Read domain_routes from the SQLite DB directly (no Flask)."""
    import sqlite3
    if not os.path.exists(DB_PATH):
        return []
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(
            "SELECT domain, mode FROM domain_routes WHERE enabled=1"
        ).fetchall()
        return [(r["domain"].lower(), r["mode"]) for r in rows]
    except sqlite3.OperationalError:
        return []  # table doesn't exist yet
    finally:
        conn.close()


def ensure_sets():
    for s in SET_FOR_MODE.values():
        subprocess.run(
            ["ipset", "create", s, "hash:ip", "timeout", "86400"],
            check=False, capture_output=True,
        )


def matches(host: str, pattern: str) -> bool:
    """Pattern semantics:
    - exact: "example.com" matches only example.com
    - leading-dot or wildcard: ".example.com" or "*.example.com" matches all subdomains
    """
    h = host.lower().rstrip(".")
    p = pattern.lower().lstrip("*").lstrip(".")
    if h == p:
        return True
    return h.endswith("." + p)


def extract_ips(rec) -> list[str]:
    """Pull A/AAAA answers from an AdGuard query record."""
    ips = []
    answer = rec.get("answer") or []
    for a in answer:
        v = a.get("value") or ""
        ttype = a.get("type") or ""
        if ttype in ("A", "AAAA") and v:
            ips.append(v)
    return ips


def add_ip(set_name: str, ip: str):
    subprocess.run(
        ["ipset", "add", set_name, ip, "-exist", "timeout", "86400"],
        check=False, capture_output=True,
    )


def sweep():
    routes = load_routes()
    if not routes:
        return 0
    queries = adg_get()
    added = 0
    for q in queries:
        host = (q.get("question") or {}).get("name", "")
        if not host:
            continue
        for pattern, mode in routes:
            if not matches(host, pattern):
                continue
            set_name = SET_FOR_MODE.get(mode)
            if not set_name:
                continue
            for ip in extract_ips(q):
                add_ip(set_name, ip)
                added += 1
            break  # first matching route wins
    return added


def main():
    once = "--once" in sys.argv
    ensure_sets()
    while True:
        try:
            n = sweep()
            if n:
                print(f"[domain-router] added {n} IPs across routes", flush=True)
        except Exception as e:
            print(f"[domain-router] error: {e}", file=sys.stderr, flush=True)
        if once:
            break
        time.sleep(POLL_S)


if __name__ == "__main__":
    main()
