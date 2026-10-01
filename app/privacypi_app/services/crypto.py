"""Fernet at-rest encryption helpers.

Two modes:
  - Password-derived (PBKDF2HMAC) — used for backup encryption where the
    user supplies a password each time.
  - Master-key (file-backed) — used for credentials at rest (proxy URLs,
    VPN passwords) where the Flask process needs to read them autonomously
    on startup. Master key is in /etc/privacypi/master.key (mode 0600).
"""
import os
from pathlib import Path
from base64 import urlsafe_b64encode
from cryptography.fernet import Fernet, InvalidToken
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC

# ---- password-derived (used by backup) ----
def derive_key(password: str, salt: bytes) -> bytes:
    kdf = PBKDF2HMAC(algorithm=hashes.SHA256(), length=32, salt=salt, iterations=480000)
    return urlsafe_b64encode(kdf.derive(password.encode()))

def encrypt(value: str, key: bytes) -> str:
    return Fernet(key).encrypt(value.encode()).decode()

def decrypt(token: str, key: bytes) -> str:
    return Fernet(key).decrypt(token.encode()).decode()


# ---- master-key (used by proxy creds, vpn creds) ----
_KEY_PATH = Path("/etc/privacypi/master.key")
_FERNET: Fernet | None = None

def _load_master_key() -> bytes:
    if _KEY_PATH.exists():
        return _KEY_PATH.read_bytes().strip()
    # Bootstrap: try to write under /etc/privacypi (works if permissions allow,
    # i.e. install script pre-created the dir with privacypi:privacypi 0750).
    try:
        _KEY_PATH.parent.mkdir(parents=True, exist_ok=True)
        k = Fernet.generate_key()
        _KEY_PATH.write_bytes(k)
        os.chmod(_KEY_PATH, 0o600)
        return k
    except PermissionError:
        # Dev/first-boot fallback — process-local, lost on restart.
        return Fernet.generate_key()

def _master() -> Fernet:
    global _FERNET
    if _FERNET is None:
        _FERNET = Fernet(_load_master_key())
    return _FERNET

def vault_encrypt(plaintext: str | bytes) -> str:
    if isinstance(plaintext, str):
        plaintext = plaintext.encode()
    return _master().encrypt(plaintext).decode()

def vault_decrypt(token: str | None) -> str | None:
    if not token:
        return None
    try:
        return _master().decrypt(token.encode() if isinstance(token, str) else token).decode()
    except (InvalidToken, ValueError):
        return None
