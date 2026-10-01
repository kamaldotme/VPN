from flask import Flask, redirect, url_for, request, has_request_context
from flask.sessions import SecureCookieSessionInterface
from flask_sqlalchemy import SQLAlchemy
from werkzeug.middleware.proxy_fix import ProxyFix
from .extensions import db, login_manager, csrf
from .config import Config


class SchemeAwareSessionInterface(SecureCookieSessionInterface):
    """The dashboard is served over plain HTTP on the PrivacyPi WiFi (no
    certificate warning for non-technical users) and over HTTPS for those who
    install the root certificate. A Secure cookie cannot be set over HTTP, and a
    non-Secure cookie may not overwrite a Secure one of the same name — so each
    scheme gets its own cookie."""

    def get_cookie_secure(self, app):
        return has_request_context() and request.is_secure

    def get_cookie_name(self, app):
        if has_request_context() and request.is_secure:
            return "__Secure-pp_session"
        return "pp_session"


def create_app(config_class=Config):
    app = Flask(__name__)
    app.config.from_object(config_class)
    app.session_interface = SchemeAwareSessionInterface()

    # Trust X-Forwarded-* headers from the loopback Caddy reverse proxy
    # (proto/host/for). Lets Flask see the real https scheme even though
    # gunicorn binds plain HTTP on 127.0.0.1:8443. Only one hop (Caddy).
    app.wsgi_app = ProxyFix(app.wsgi_app, x_proto=1, x_host=1, x_for=1)

    db.init_app(app)
    login_manager.init_app(app)
    login_manager.login_view = "auth.login"
    csrf.init_app(app)

    from .auth import bp as auth_bp
    from .pages import bp as pages_bp
    from .sse import bp as sse_bp
    from .wizard import bp as wizard_bp
    app.register_blueprint(auth_bp)
    app.register_blueprint(pages_bp)
    app.register_blueprint(sse_bp)
    app.register_blueprint(wizard_bp)

    with app.app_context():
        # Several gunicorn workers start at once; on a brand-new database they
        # race to create the tables. The loser retries and finds them present.
        from sqlalchemy.exc import OperationalError
        for attempt in (1, 2, 3):
            try:
                db.create_all()
                break
            except OperationalError:
                if attempt == 3:
                    raise
                import time
                time.sleep(0.5)

    # Site-config context processor — every template gets host_ip / host_mdns.
    @app.context_processor
    def inject_site():
        from .services.site import read_site_conf
        site = read_site_conf()
        return {
            "host_ip": site.get("HOST_IP", "your-pi-ip"),
            "host_mdns": site.get("HOST_MDNS", "privacypi.local"),
            "wan_mode": site.get("WAN_MODE", "ethernet"),
            "wan_wifi_ssid": site.get("WAN_WIFI_SSID", ""),
            "lan_gw": site.get("LAN_GW", "10.10.10.1"),
        }

    @app.before_request
    def redirect_to_wizard_if_setup_pending():
        from .models import Setting
        from .services.site import read_site_conf
        s = db.session.get(Setting, "setup_complete")
        if s and s.value == "true":
            return None
        # Setup mode: the setup network answers every DNS name with our address,
        # so phones' connectivity probes (captive.apple.com, connectivitycheck…)
        # land here. Redirecting them to the wizard is what makes the phone pop
        # up its "sign in to network" page.
        site = read_site_conf()
        lan_gw = site.get("LAN_GW", "10.10.10.1")
        host = (request.host or "").split(":")[0].lower()
        ours = {lan_gw, site.get("HOST_MDNS", "privacypi.local").lower(), "localhost", "127.0.0.1"}
        if site.get("HOST_IP"):
            ours.add(site["HOST_IP"])
        if host not in ours:
            return redirect(f"http://{lan_gw}/setup/", code=302)
        if not request.path.startswith("/setup") and not request.path.startswith("/static"):
            return redirect(url_for("wizard.home"))

    return app
