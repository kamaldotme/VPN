#!/usr/bin/env python3
"""DNS query anomaly detector using IsolationForest on AdGuard query log.
Reads recent queries, vectorizes (per-client query rate, unique-tld count, top-domain hash).
Flags anomalies — likely malware C2, phone-home, or compromised device.

Usage: anomaly-detect.py [--window-minutes 60] [--out /var/lib/privacypi/anomalies.json]
"""
import argparse, json, os, sys
from collections import defaultdict, Counter
from datetime import datetime, timedelta

try:
    import numpy as np
    from sklearn.ensemble import IsolationForest
except ImportError:
    print(json.dumps({"error": "scikit-learn not installed"}))
    sys.exit(1)

QUERY_LOG = "/opt/AdGuardHome/data/querylog.json"

def load_queries(window_minutes=60):
    if not os.path.exists(QUERY_LOG):
        return []
    cutoff = datetime.utcnow() - timedelta(minutes=window_minutes)
    out = []
    try:
        # AdGuard writes one JSON object per line
        with open(QUERY_LOG) as f:
            for line in f:
                try:
                    q = json.loads(line)
                    ts = datetime.fromisoformat(q.get("T","").replace("Z","+00:00").replace("+00:00",""))
                    if ts > cutoff:
                        out.append(q)
                except Exception:
                    pass
    except Exception as e:
        return []
    return out

def vectorize(queries):
    """Group by client IP. Return (client_ips, feature_matrix)."""
    by_client = defaultdict(list)
    for q in queries:
        ip = q.get("IP", "?")
        by_client[ip].append(q)
    
    rows = []
    ips = []
    for ip, qs in by_client.items():
        if len(qs) < 5:  # skip sparse clients
            continue
        domains = [q.get("QH","") for q in qs]
        tlds = set(d.rsplit(".",1)[-1] if "." in d else d for d in domains)
        unique_domains = len(set(domains))
        blocked = sum(1 for q in qs if q.get("Result", {}).get("IsFiltered", False))
        rows.append([
            len(qs),                # total queries
            unique_domains,         # unique domains
            len(tlds),              # unique TLDs
            blocked,                # blocked count
            blocked / max(1, len(qs)),  # block ratio
            unique_domains / max(1, len(qs))  # diversity ratio
        ])
        ips.append(ip)
    return ips, np.array(rows) if rows else np.zeros((0, 6))

def detect(X):
    if X.shape[0] < 3:
        return []
    clf = IsolationForest(contamination=0.1, random_state=42)
    clf.fit(X)
    scores = clf.score_samples(X)  # higher = more normal
    threshold = np.percentile(scores, 10)
    return [(i, float(s)) for i, s in enumerate(scores) if s < threshold]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--window-minutes", type=int, default=60)
    ap.add_argument("--out", default="/var/lib/privacypi/anomalies.json")
    args = ap.parse_args()
    
    qs = load_queries(args.window_minutes)
    ips, X = vectorize(qs)
    anomalies = detect(X)
    result = {
        "timestamp": datetime.utcnow().isoformat(),
        "window_minutes": args.window_minutes,
        "queries_analyzed": len(qs),
        "clients_analyzed": len(ips),
        "anomalies": [
            {"client_ip": ips[i], "anomaly_score": s,
             "features": {"queries": int(X[i][0]), "unique_domains": int(X[i][1]),
                          "block_ratio": round(float(X[i][4]), 3)}}
            for i, s in anomalies
        ]
    }
    with open(args.out, "w") as f:
        json.dump(result, f, indent=2)
    print(json.dumps(result, indent=2))

if __name__ == "__main__":
    main()
