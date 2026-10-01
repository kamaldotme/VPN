from datetime import datetime
from sqlalchemy import String, DateTime, Boolean, Integer, Text
from sqlalchemy.orm import Mapped, mapped_column
from flask_login import UserMixin
from .extensions import db

class User(UserMixin, db.Model):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    username: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    password_hash: Mapped[str] = mapped_column(String(128), nullable=False)
    totp_secret: Mapped[str | None] = mapped_column(String(64))
    totp_enabled: Mapped[bool] = mapped_column(Boolean, default=False)
    is_admin: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    last_login_at: Mapped[datetime | None] = mapped_column(DateTime)

class Setting(db.Model):
    __tablename__ = "settings"
    key: Mapped[str] = mapped_column(String(64), primary_key=True)
    value: Mapped[str] = mapped_column(Text)
    updated_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

class AuditLog(db.Model):
    __tablename__ = "audit_log"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    timestamp: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow, index=True)
    user: Mapped[str] = mapped_column(String(64))
    action: Mapped[str] = mapped_column(String(128))
    detail: Mapped[str | None] = mapped_column(Text)
    ip: Mapped[str | None] = mapped_column(String(45))
    # HMAC chain: prev_hash is the row_hash of the immediately-preceding row
    # (sorted by id ASC). row_hash = HMAC-SHA256(master_key, prev_hash || row_data).
    # If any earlier row is altered/deleted, the chain breaks at the next row
    # and the verifier reports the first index where it diverges.
    prev_hash: Mapped[str | None] = mapped_column(String(64))
    row_hash: Mapped[str | None] = mapped_column(String(64))



class AlertConfig(db.Model):
    __tablename__ = "alert_configs"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    label: Mapped[str] = mapped_column(String(64))
    url: Mapped[str] = mapped_column(Text)  # apprise URL
    triggers: Mapped[str] = mapped_column(Text, default="[]")  # JSON list of trigger names
    enabled: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)


class AlertRule(db.Model):
    """User-defined alert rules.
    Evaluated by the rules daemon every 60s against audit_log + AdGuard.

    kind:
      audit.action       — fires when an audit row matches `pattern` (LIKE)
      dns.host           — fires when the AdGuard log shows host matching pattern
      dns.client_blocked — fires when a client's blocked-query rate exceeds threshold
      threshold.fails    — fires when login fails >= threshold in window_minutes
    """
    __tablename__ = "alert_rules"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    label: Mapped[str] = mapped_column(String(64))
    kind: Mapped[str] = mapped_column(String(32))
    pattern: Mapped[str] = mapped_column(String(255))
    threshold: Mapped[int] = mapped_column(Integer, default=1)
    window_minutes: Mapped[int] = mapped_column(Integer, default=60)
    cooldown_minutes: Mapped[int] = mapped_column(Integer, default=60)
    enabled: Mapped[bool] = mapped_column(Boolean, default=True)
    last_fired_at: Mapped[datetime | None] = mapped_column(DateTime)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)


class SpeedTestResult(db.Model):
    __tablename__ = "speedtest_results"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    timestamp: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow, index=True)
    mode: Mapped[str | None] = mapped_column(String(32))
    download_mbps: Mapped[float | None] = mapped_column(db.Float)
    upload_mbps: Mapped[float | None] = mapped_column(db.Float)
    ping_ms: Mapped[float | None] = mapped_column(db.Float)
    server: Mapped[str | None] = mapped_column(String(128))


class LoginAttempt(db.Model):
    """Failed login source-IP tracker. Cleared on success."""
    __tablename__ = "login_attempts"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    ip: Mapped[str] = mapped_column(String(45), index=True)
    timestamp: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow, index=True)
    username: Mapped[str | None] = mapped_column(String(64))
    user_agent: Mapped[str | None] = mapped_column(String(256))


class WebAuthnCredential(db.Model):
    """Stored WebAuthn (hardware key / passkey) credentials per user."""
    __tablename__ = "webauthn_credentials"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(Integer, index=True)
    credential_id: Mapped[str] = mapped_column(String(512), unique=True)
    public_key: Mapped[str] = mapped_column(Text)  # base64 COSE pubkey
    sign_count: Mapped[int] = mapped_column(Integer, default=0)
    label: Mapped[str | None] = mapped_column(String(64))
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    last_used_at: Mapped[datetime | None] = mapped_column(DateTime)


class DomainRoute(db.Model):
    """Per-domain egress override. Daemon polls AdGuard log and adds the
    resolved IPs into the matching ipset for policy routing."""
    __tablename__ = "domain_routes"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    domain: Mapped[str] = mapped_column(String(255), unique=True)
    mode: Mapped[str] = mapped_column(String(16))  # direct|vpn|tor|proxy|killswitch
    enabled: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)


class Proxy(db.Model):
    """Outbound SOCKS5 / Shadowsocks / VLESS / Trojan / Hysteria2 / SSH-D endpoint.

    `url_encrypted` holds the connection URL encrypted with the master key
    (see services.crypto.vault_encrypt). The plaintext URL never hits disk
    in unencrypted form once it's been saved.
    """
    __tablename__ = "proxies"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    label: Mapped[str] = mapped_column(String(64), unique=True)
    kind: Mapped[str] = mapped_column(String(16))   # socks5|ss|vless|vmess|trojan|hysteria2|ssh
    url_encrypted: Mapped[str] = mapped_column(Text)
    note: Mapped[str | None] = mapped_column(String(256))
    enabled: Mapped[bool] = mapped_column(Boolean, default=True)
    is_active: Mapped[bool] = mapped_column(Boolean, default=False)
    last_test_ok: Mapped[bool | None] = mapped_column(Boolean)
    last_test_at: Mapped[datetime | None] = mapped_column(DateTime)
    last_test_detail: Mapped[str | None] = mapped_column(String(256))
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)


class ProxyChain(db.Model):
    """Stack of proxies/VPN/Tor to compose an outbound path.

    `links` is JSON: e.g. [{"type":"vpn","name":"nordvpn"},{"type":"proxy","id":3}]
    Order matters; first link is closest to the Pi, last link is the exit.
    """
    __tablename__ = "proxy_chains"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    label: Mapped[str] = mapped_column(String(64), unique=True)
    links: Mapped[str] = mapped_column(Text)  # JSON list
    is_active: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
