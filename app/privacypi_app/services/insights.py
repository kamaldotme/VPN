"""Turn raw AdGuard / system data into a human narrative.

The dashboard wants sentences like:
  "Yesterday you blocked 4,210 trackers. The top tracker was doubleclick.net
   at 21%. You saved approximately 38 MB of ads and 12 minutes of load time."

We compute these on demand from AdGuard's stats API + audit log.
"""
from __future__ import annotations
import base64, json, os, urllib.request

ADG = "http://127.0.0.1:3000/control/stats"
CRED_FILE = "/etc/privacypi/adguard.cred"

# Conservative numbers. We're not trying to exaggerate.
BYTES_PER_AD = 25 * 1024  # 25 KB average per blocked ad request
MS_PER_AD    = 180        # 180 ms median delay per blocked tracker per page


def _adg_get(path: str) -> dict | None:
    if not os.path.exists(CRED_FILE):
        return None
    cred = open(CRED_FILE).read().strip()
    auth = "Basic " + base64.b64encode(cred.encode()).decode()
    req = urllib.request.Request(f"http://127.0.0.1:3000{path}",
                                 headers={"Authorization": auth})
    try:
        with urllib.request.urlopen(req, timeout=4) as r:
            return json.loads(r.read())
    except Exception:
        return None


def _fmt_bytes(n: int) -> str:
    n = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} PB"


def _fmt_minutes(s: int) -> str:
    if s < 60:
        return f"{s}s"
    m = s // 60
    if m < 60:
        return f"{m}m"
    return f"{m // 60}h {m % 60}m"


def get_dashboard_insights() -> dict:
    """Single call returning all insight metrics for the dashboard."""
    stats = _adg_get("/control/stats") or {}
    total = int(stats.get("num_dns_queries", 0) or 0)
    blocked = int(stats.get("num_blocked_filtering", 0) or 0)
    safebrowsing = int(stats.get("num_replaced_safebrowsing", 0) or 0)
    parental = int(stats.get("num_replaced_parental", 0) or 0)
    avg_ms = float(stats.get("avg_processing_time", 0) or 0) * 1000
    top_blocked = stats.get("top_blocked_domains", [])[:5]
    # Leave out the Pi itself (its own lookups arrive from loopback / the gateway address).
    from .site import read_site_conf
    own = {"127.0.0.1", "::1", read_site_conf().get("LAN_GW", "10.10.10.1")}
    top_clients = [d for d in stats.get("top_clients", [])
                   if not (isinstance(d, dict) and d and list(d.keys())[0] in own)][:5]

    saved_bytes = blocked * BYTES_PER_AD
    saved_ms = blocked * MS_PER_AD

    threat_total = blocked + safebrowsing + parental

    return {
        "totals": {
            "queries": total,
            "blocked": blocked,
            "threats": safebrowsing + parental,
            "block_rate_pct": round(100 * blocked / total, 1) if total else 0,
        },
        "narrative": {
            "headline": (
                f"Blocked {blocked:,} trackers across {total:,} queries"
                if blocked else "Network running clean — no traffic to filter yet."
            ),
            "saved_bandwidth": _fmt_bytes(saved_bytes),
            "saved_time": _fmt_minutes(saved_ms // 1000),
            "avg_response_ms": round(avg_ms, 1),
        },
        "top_blocked_domains": [
            {"name": list(d.keys())[0], "count": list(d.values())[0]}
            if isinstance(d, dict) else {"name": str(d), "count": 0}
            for d in top_blocked
        ],
        "top_clients": [
            {"ip": list(d.keys())[0], "count": list(d.values())[0]}
            if isinstance(d, dict) else {"ip": str(d), "count": 0}
            for d in top_clients
        ],
    }


def get_24h_summary() -> dict:
    """24h summary suitable for a daily digest message."""
    insights = get_dashboard_insights()
    t = insights["totals"]
    n = insights["narrative"]
    lines = [
        f"PrivacyPi · last 24h",
        f"━━━━━━━━━━━━━━━━━━━━",
        f"Queries:         {t['queries']:,}",
        f"Blocked:         {t['blocked']:,}  ({t['block_rate_pct']}%)",
        f"Threats stopped: {t['threats']:,}",
        f"Bandwidth saved: {n['saved_bandwidth']}",
        f"Time saved:      {n['saved_time']}",
    ]
    if insights["top_blocked_domains"]:
        lines.append("")
        lines.append("Top blocked:")
        for d in insights["top_blocked_domains"][:3]:
            lines.append(f"  · {d['name']}  ({d['count']})")
    return {
        "summary_text": "\n".join(lines),
        "raw": insights,
    }
