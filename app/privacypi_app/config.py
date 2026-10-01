import os
import secrets

class Config:
    SECRET_KEY = os.environ.get("PRIVACYPI_SECRET_KEY") or secrets.token_hex(32)
    SQLALCHEMY_DATABASE_URI = os.environ.get(
        "PRIVACYPI_DB_URI", "sqlite:////var/lib/privacypi/privacypi.db"
    )
    SQLALCHEMY_TRACK_MODIFICATIONS = False
    # Cookie name + Secure flag are chosen per request (HTTP on the LAN vs
    # HTTPS) by SchemeAwareSessionInterface in __init__.py.
    SESSION_COOKIE_SECURE = False
    SESSION_COOKIE_HTTPONLY = True
    SESSION_COOKIE_SAMESITE = "Strict"
    PERMANENT_SESSION_LIFETIME = 60 * 60 * 4  # 4 hours
    WTF_CSRF_TIME_LIMIT = None  # session-bound

    # Allowed modes for /api/mode/<m>
    ALLOWED_MODES = ["direct", "openvpn", "wireguard", "tor", "proxy", "killswitch"]

    # Privileged scripts the runner is allowed to invoke
    ALLOWED_SCRIPTS = {
        "route-mode": "/opt/privacypi/scripts/route-mode.sh",
        "wan-config": "/opt/privacypi/scripts/wan-config.sh",
        "vpn-status": "/opt/privacypi/scripts/vpn-status.sh",
        "proxy-up": "/opt/privacypi/scripts/proxy-up.sh",
        "proxy-down": "/opt/privacypi/scripts/proxy-down.sh",
        "killswitch": "/opt/privacypi/scripts/killswitch.sh",
        "vpn-write": "/opt/privacypi/scripts/vpn-write.sh",
        "system-action": "/opt/privacypi/scripts/system-action.sh",
        "backup-create": "/opt/privacypi/scripts/backup-create.sh",
        "backup-restore": "/opt/privacypi/scripts/backup-restore.sh",
        "list-clients": "/opt/privacypi/scripts/list-clients.sh",
        "device-route": "/opt/privacypi/scripts/device-route.sh",
        "speedtest": "/opt/privacypi/scripts/speedtest.sh",
        "self-update": "/opt/privacypi/scripts/self-update.sh",
        "wg-server": "/opt/privacypi/scripts/wg-server.sh",
        "tor-dns": "/opt/privacypi/scripts/tor-dns.sh",
        "tor-bridges": "/opt/privacypi/scripts/tor-bridges.sh",
        "rotate-mac": "/opt/privacypi/scripts/rotate-mac.sh",
        "anomaly-detect": "/opt/privacypi/scripts/anomaly-detect.py",
        "proxy-write": "/opt/privacypi/scripts/proxy-write.sh",
        "proxy-test": "/opt/privacypi/scripts/proxy-test.sh",
        "onion-admin": "/opt/privacypi/scripts/onion-admin.sh",
        "doh-server": "/opt/privacypi/scripts/doh-server.sh",
        "tether-wan": "/opt/privacypi/scripts/tether-wan.sh",
        "tls-bootstrap": "/opt/privacypi/scripts/tls-bootstrap.sh",
        "captive-portal": "/opt/privacypi/scripts/captive-portal.sh",
        "dns-trap": "/opt/privacypi/scripts/dns-trap.sh",
        "ntp-trap": "/opt/privacypi/scripts/ntp-trap.sh",
        "ap-harden": "/opt/privacypi/scripts/ap-harden.sh",
        "master-key-write": "/opt/privacypi/scripts/master-key-write.sh",
        "dns-tail": "/opt/privacypi/scripts/dns-tail.sh",
        "mac-traffic": "/opt/privacypi/scripts/mac-traffic.sh",
        "onion-ssh": "/opt/privacypi/scripts/onion-ssh.sh",
        "wstunnel": "/opt/privacypi/scripts/wstunnel.sh",
        "tor-circuits": "/opt/privacypi/scripts/tor-circuits.sh",
        "domain-router": "/opt/privacypi/scripts/domain-router.py",
        "alert-rules": "/opt/privacypi/scripts/alert-rules.py",
        "daily-digest": "/opt/privacypi/scripts/daily-digest.sh",
        "rotate-blocklists": "/opt/privacypi/scripts/rotate-blocklists.sh",
        "rotate-wg-psk": "/opt/privacypi/scripts/rotate-wg-psk.sh",
        "ap-config": "/opt/privacypi/scripts/ap-config.sh",
        "setup-finish": "/opt/privacypi/scripts/setup-finish.sh",
        "set-time": "/opt/privacypi/scripts/set-time.sh",
        "extras": "/opt/privacypi/scripts/extras.sh",
        "vpn-connect": "/opt/privacypi/scripts/vpn-connect.sh",
        "net-roles": "/opt/privacypi/scripts/net-roles.sh",
        "diag": "/opt/privacypi/scripts/diag.sh",
    }
