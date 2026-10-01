#!/usr/bin/env python3
"""Alert rules evaluator daemon.

Runs every 60s. Walks the alert_rules table; for each enabled rule, checks
its condition against:
  - audit_log table (kind=audit.action, threshold.fails)
  - AdGuard query log (kind=dns.host)
  - per-client blocked-query rates (kind=dns.client_blocked)

If condition met AND cooldown elapsed, fire via the internal alert endpoint.
"""
from __future__ import annotations
import base64, json, os, re, sqlite3, sys, time, urllib.request
from datetime import datetime, timedelta

POLL_S = 60
DB = "/var/lib/privacypi/privacypi.db"
SECRET_FILE = "/etc/privacypi/alert.secret"
ADG_CRED_FILE = "/etc/privacypi/adguard.cred"
ALERT_URL = "https://127.0.0.1:8443/api/alert/internal/rule.fired"


def secret() -> str:
    if not os.path.exists(SECRET_FILE):
        return ""
    return open(SECRET_FILE).read().strip()


def adg_recent(limit=200) -> list:
    if not os.path.exists(ADG_CRED_FILE):
        return []
    cred = open(ADG_CRED_FILE).read().strip()
    auth = "Basic " + base64.b64encode(cred.encode()).decode()
    req = urllib.request.Request(
        f"http://127.0.0.1:3000/control/querylog?limit={limit}",
        headers={"Authorization": auth},
    )
    try:
        with urllib.request.urlopen(req, timeout=4) as r:
            return json.loads(r.read()).get("data", [])
    except Exception:
        return []


def fire(label: str, message: str):
    s = secret()
    if not s:
        print("alert.secret missing; cannot fire", file=sys.stderr)
        return False
    import ssl
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    body = urllib.parse.urlencode({
        "message": f"[rule] {label}: {message}",
        "level": "warn",
    }).encode()
    req = urllib.request.Request(ALERT_URL, data=body,
                                 headers={"X-Internal-Secret": s})
    try:
        urllib.request.urlopen(req, timeout=4, context=ctx)
        return True
    except Exception as e:
        print(f"fire failed: {e}", file=sys.stderr)
        return False


def evaluate_rule(conn, rule):
    rid, label, kind, pattern, threshold, window_m, cooldown_m, enabled, last_fired, _created = rule
    if not enabled:
        return None
    if last_fired:
        try:
            last_dt = datetime.fromisoformat(last_fired)
        except Exception:
            last_dt = None
        if last_dt and datetime.utcnow() - last_dt < timedelta(minutes=cooldown_m):
            return None  # still cooling down

    cutoff = (datetime.utcnow() - timedelta(minutes=window_m)).isoformat()
    if kind == "audit.action":
        n = conn.execute(
            "SELECT COUNT(*) FROM audit_log WHERE action LIKE ? AND timestamp >= ?",
            (pattern, cutoff),
        ).fetchone()[0]
        if n >= threshold:
            return f"{n} audit rows matched '{pattern}' in last {window_m}m"
    elif kind == "threshold.fails":
        n = conn.execute(
            "SELECT COUNT(*) FROM login_attempts WHERE timestamp >= ?",
            (cutoff,),
        ).fetchone()[0]
        if n >= threshold:
            return f"{n} login failures in last {window_m}m (threshold {threshold})"
    elif kind == "dns.host":
        recent = adg_recent(200)
        regex = re.compile(pattern.replace(".", "\\.").replace("*", ".*"))
        hits = []
        for r in recent:
            host = (r.get("question") or {}).get("name", "")
            if regex.search(host):
                hits.append((host, r.get("client", ""), r.get("time", "")))
        if len(hits) >= threshold:
            sample = ", ".join(f"{h[1]}→{h[0]}" for h in hits[:3])
            return f"{len(hits)} DNS queries matched '{pattern}' (e.g. {sample})"
    elif kind == "dns.client_blocked":
        recent = adg_recent(200)
        per_client_blocked = {}
        per_client_total = {}
        for r in recent:
            c = r.get("client", "?")
            per_client_total[c] = per_client_total.get(c, 0) + 1
            if r.get("reason", "").startswith("Filtered"):
                per_client_blocked[c] = per_client_blocked.get(c, 0) + 1
        for c, b in per_client_blocked.items():
            t = per_client_total.get(c, 1)
            rate = 100 * b / t
            if rate >= threshold:
                return f"{c} block-rate {rate:.0f}% (threshold {threshold}%)"
    return None


def sweep():
    if not os.path.exists(DB):
        return
    conn = sqlite3.connect(DB)
    try:
        rules = conn.execute(
            "SELECT id,label,kind,pattern,threshold,window_minutes,"
            "cooldown_minutes,enabled,last_fired_at,created_at FROM alert_rules"
        ).fetchall()
    except sqlite3.OperationalError:
        conn.close()
        return  # table not migrated yet

    for rule in rules:
        try:
            msg = evaluate_rule(conn, rule)
        except Exception as e:
            print(f"rule {rule[1]} eval error: {e}", file=sys.stderr)
            continue
        if msg:
            ok = fire(rule[1], msg)
            if ok:
                conn.execute(
                    "UPDATE alert_rules SET last_fired_at=? WHERE id=?",
                    (datetime.utcnow().isoformat(), rule[0]),
                )
                conn.commit()
                print(f"fired: {rule[1]}: {msg}", flush=True)
    conn.close()


def main():
    once = "--once" in sys.argv
    while True:
        try:
            sweep()
        except Exception as e:
            print(f"sweep error: {e}", file=sys.stderr, flush=True)
        if once:
            break
        time.sleep(POLL_S)


if __name__ == "__main__":
    import urllib.parse
    main()
