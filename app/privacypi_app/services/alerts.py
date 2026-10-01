"""Apprise-based alert dispatcher."""
import json
import logging
from typing import Iterable

logger = logging.getLogger(__name__)

VALID_TRIGGERS = {
    "mode.killswitch",
    "vpn.drop",
    "login.fail.repeated",
    "system.reboot",
    "system.factory-reset",
    "wizard.complete",
    "intrusion.detected",
}


def send(message: str, *, level: str = "info", trigger: str = "manual"):
    """Dispatch message to all enabled configs that subscribe to this trigger."""
    try:
        import apprise
    except ImportError:
        logger.warning("apprise not installed; alert dropped: %s", message)
        return False

    from ..extensions import db
    from ..models import AlertConfig

    configs = db.session.query(AlertConfig).filter_by(enabled=True).all()
    sent_count = 0
    apr = apprise.Apprise()

    for cfg in configs:
        try:
            triggers = json.loads(cfg.triggers or "[]")
        except Exception:
            triggers = []
        if trigger != "manual" and trigger not in triggers:
            continue
        apr.add(cfg.url)
        sent_count += 1

    if sent_count == 0:
        return False

    title = f"[PrivacyPi] {level.upper()}"
    return apr.notify(body=message, title=title)


def test_one(url: str, label: str = "test") -> bool:
    """Send a one-off test message to a single apprise URL."""
    try:
        import apprise
    except ImportError:
        return False
    apr = apprise.Apprise()
    apr.add(url)
    return apr.notify(body=f"PrivacyPi test alert ({label}). If you received this, alerts are working.",
                       title="[PrivacyPi] Test")
