"""Master-key recovery: BIP-39 24-word mnemonic.

The master.key (Fernet 32 bytes, base64-url-encoded → 44 ASCII chars) holds
the symmetric key for vault_encrypt/decrypt. If the SD card dies, all
encrypted secrets (Proxy URLs, future encrypted credentials) are lost
unless the user has the key off-device.

BIP-39 encodes 32 bytes of entropy as 24 English words with a built-in
4-bit checksum. The user prints these and stores them physically (safe,
locked drawer, paper-wallet). To rebuild, paste the 24 words back in.

We don't display the words on first run — only on demand from /trust or
/system. The user must explicitly request, then we wipe the page after
display.
"""
from __future__ import annotations
from base64 import urlsafe_b64decode, urlsafe_b64encode
from pathlib import Path
from mnemonic import Mnemonic

_KEY_PATH = Path("/etc/privacypi/master.key")
_M = Mnemonic("english")


def _read_key() -> bytes:
    if not _KEY_PATH.exists():
        raise RuntimeError("master.key not found")
    raw = _KEY_PATH.read_bytes().strip()
    # Fernet keys are urlsafe-base64 of 32 random bytes.
    return urlsafe_b64decode(raw)


def export_mnemonic() -> str:
    """24-word BIP-39 mnemonic for the current master.key."""
    entropy = _read_key()
    if len(entropy) != 32:
        raise RuntimeError(f"unexpected key length: {len(entropy)}")
    return _M.to_mnemonic(entropy)


def restore_from_mnemonic(words: str) -> bool:
    """Replace master.key with the key derived from `words` via privileged script."""
    words = " ".join(words.lower().split())
    if not _M.check(words):
        raise ValueError("invalid mnemonic (checksum mismatch)")
    entropy = _M.to_entropy(words)
    fernet_key = urlsafe_b64encode(entropy).decode()
    # Privileged write via shell helper (Flask user can't write /etc/privacypi)
    from .runner import run_script
    rc, out, err = run_script("master-key-write", [], stdin=fernet_key)
    if rc != 0:
        raise RuntimeError(err or out or "master-key-write failed")
    return True
