"""HMAC-chained audit log.

Each AuditLog row carries:
  - prev_hash: the row_hash of the immediately preceding row (sorted by id)
  - row_hash:  HMAC-SHA256(master_key, prev_hash || canonical_row_bytes)

A tampering attempt that modifies/deletes any past row breaks the chain at
the next row. `verify_chain()` walks the table and returns the first index
where the actual hash doesn't match the recomputed hash.

The HMAC key is the master.key (already mode 0640 root:privacypi). An
attacker without root can't forge a valid hash even with DB write.
"""
from __future__ import annotations
import hmac, hashlib
from pathlib import Path
from typing import Optional, Tuple

_KEY_PATH = Path("/etc/privacypi/master.key")


def _key() -> bytes:
    return _KEY_PATH.read_bytes().strip() if _KEY_PATH.exists() else b"dev-fallback"


def _canon(row) -> bytes:
    """Canonical byte representation. Order is fixed and stable."""
    parts = [
        str(row.id or ""),
        row.timestamp.isoformat() if row.timestamp else "",
        row.user or "",
        row.action or "",
        row.detail or "",
        row.ip or "",
    ]
    return "\x1f".join(parts).encode()  # unit-separator delimits


def compute_hash(prev_hash: Optional[str], row) -> str:
    msg = (prev_hash or "").encode() + b"\x1e" + _canon(row)
    return hmac.new(_key(), msg, hashlib.sha256).hexdigest()


def verify_chain(rows) -> Tuple[bool, Optional[int], int]:
    """Walk rows in id order and verify each hash.

    Returns (ok, first_bad_id, total_checked).
    """
    prev = None
    n = 0
    for r in rows:
        n += 1
        expected = compute_hash(prev, r)
        if r.row_hash != expected:
            return False, r.id, n
        prev = r.row_hash
    return True, None, n
