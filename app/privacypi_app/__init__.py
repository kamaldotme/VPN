from flask import Flask, redirect, url_for, request
from flask_sqlalchemy import SQLAlchemy
from werkzeug.middleware.proxy_fix import ProxyFix
from .extensions import db, login_manager, csrf
from .config import Config


def create_app(config_class=Config):
    app = Flask(__name__)
    app.config.from_object(config_class)

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
        db.create_all()

    # Site-config context processor — every template gets host_ip / host_mdns.
    @app.context_processor
    def inject_site():
        site = {}
        try:
            with open("/etc/privacypi/site.conf") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    k, _, v = line.partition("=")
                    site[k.strip()] = v.strip().strip('"').strip("'")
        except FileNotFoundError:
            pass
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
        s = db.session.get(Setting, "setup_complete")
        if not (s and s.value == "true"):
            if not request.path.startswith("/setup") and not request.path.startswith("/static"):
                return redirect(url_for("wizard.home"))

    return app
