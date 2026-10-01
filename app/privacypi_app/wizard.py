"""First-boot setup wizard. Captures admin password + TOTP + profile preset."""
import secrets
import bcrypt, pyotp, qrcode
from io import BytesIO
from base64 import b64encode
from datetime import datetime
from flask import Blueprint, render_template, request, redirect, url_for, session, flash, current_app, abort
from .extensions import db
from .models import User, Setting, AuditLog

bp = Blueprint("wizard", __name__, url_prefix="/setup")

PROFILES = {
    "just-privacy": {
        "label": "Just Privacy",
        "description": "VPN-ready + ad/tracker blocking. Good for most people.",
        "icon": "🛡️",
        "settings": {"adguard_profile": "Standard", "default_mode": "direct", "leak_guards": "on"},
    },
    "maximum": {
        "label": "Maximum Privacy",
        "description": "Tor on by default + strict blocking. Slowest, most anonymous.",
        "icon": "🔒",
        "settings": {"adguard_profile": "Strict", "default_mode": "tor", "leak_guards": "on"},
    },
    "family": {
        "label": "Family-Friendly",
        "description": "Adult content blocked, social media schedules, parental controls.",
        "icon": "👨‍👩‍👧",
        "settings": {"adguard_profile": "Family", "default_mode": "direct", "leak_guards": "on"},
    },
    "power": {
        "label": "Power User",
        "description": "All toggles exposed, no presets applied. For tinkerers.",
        "icon": "⚙️",
        "settings": {"adguard_profile": "Standard", "default_mode": "direct", "leak_guards": "on"},
    },
    "travel": {
        "label": "Travel",
        "description": "Anti-DPI on, proxy-ready, kill switch by default.",
        "icon": "✈️",
        "settings": {"adguard_profile": "Standard", "default_mode": "killswitch", "leak_guards": "on"},
    },
    "censored": {
        "label": "Censored Region",
        "description": "Tor with obfs4/snowflake/webtunnel bridges + WireGuard via wstunnel. Maximum bypass.",
        "icon": "🚧",
        "settings": {"adguard_profile": "Strict", "default_mode": "tor", "leak_guards": "on",
                     "tor_bridges": "auto", "wstunnel_enabled": "true"},
    },
}

def _setup_done() -> bool:
    s = db.session.get(Setting, "setup_complete")
    return bool(s and s.value == "true")

def _mark_done():
    s = db.session.get(Setting, "setup_complete")
    if s is None:
        db.session.add(Setting(key="setup_complete", value="true"))
    else:
        s.value = "true"
    db.session.commit()

def _save_setting(key: str, value: str):
    s = db.session.get(Setting, key)
    if s is None:
        db.session.add(Setting(key=key, value=value))
    else:
        s.value = value

@bp.before_request
def block_when_done():
    if _setup_done():
        abort(404)

@bp.get("")
@bp.get("/")
def home():
    return redirect(url_for("wizard.welcome"))

@bp.route("/welcome", methods=["GET", "POST"])
def welcome():
    if request.method == "POST":
        return redirect(url_for("wizard.admin"))
    return render_template("wizard/welcome.html")

@bp.route("/admin", methods=["GET", "POST"])
def admin():
    if request.method == "POST":
        pw1 = request.form.get("password", "")
        pw2 = request.form.get("password2", "")
        if len(pw1) < 12:
            flash("Password must be at least 12 characters", "error")
            return render_template("wizard/admin.html")
        if pw1 != pw2:
            flash("Passwords don't match", "error")
            return render_template("wizard/admin.html")
        # Replace bootstrap admin password
        u = db.session.query(User).filter_by(username="admin").first()
        if not u:
            u = User(username="admin", is_admin=True,
                     password_hash=bcrypt.hashpw(pw1.encode(), bcrypt.gensalt()).decode())
            db.session.add(u)
        else:
            u.password_hash = bcrypt.hashpw(pw1.encode(), bcrypt.gensalt()).decode()
        # Create TOTP secret
        u.totp_secret = pyotp.random_base32()
        u.totp_enabled = True
        db.session.commit()
        session["wizard_uid"] = u.id
        return redirect(url_for("wizard.totp"))
    return render_template("wizard/admin.html")

@bp.route("/totp", methods=["GET", "POST"])
def totp():
    uid = session.get("wizard_uid")
    u = db.session.get(User, uid) if uid else None
    if not u:
        return redirect(url_for("wizard.admin"))
    if request.method == "POST":
        code = request.form.get("code", "").strip()
        if pyotp.TOTP(u.totp_secret).verify(code, valid_window=1):
            return redirect(url_for("wizard.profile"))
        flash("Invalid code, try again", "error")
    # Generate provisioning URI + QR
    uri = pyotp.TOTP(u.totp_secret).provisioning_uri(name="admin", issuer_name="PrivacyPi")
    img = qrcode.make(uri)
    buf = BytesIO()
    img.save(buf, format="PNG")
    qr_b64 = b64encode(buf.getvalue()).decode()
    return render_template("wizard/totp.html", qr_b64=qr_b64, secret=u.totp_secret)

@bp.route("/profile", methods=["GET", "POST"])
def profile():
    if request.method == "POST":
        choice = request.form.get("profile")
        if choice not in PROFILES:
            flash("Pick a profile", "error")
            return render_template("wizard/profile.html", profiles=PROFILES)
        for k, v in PROFILES[choice]["settings"].items():
            _save_setting(k, v)
        _save_setting("profile", choice)
        db.session.commit()
        return redirect(url_for("wizard.done"))
    return render_template("wizard/profile.html", profiles=PROFILES)

@bp.route("/done", methods=["GET", "POST"])
def done():
    if request.method == "POST":
        _mark_done()
        from .services.audit_chain import compute_hash
        prev = db.session.query(AuditLog.row_hash).order_by(AuditLog.id.desc()).first()
        prev_hash = prev[0] if prev else None
        row = AuditLog(user="admin", action="wizard.complete",
                       detail=f"profile={db.session.get(Setting,'profile').value}",
                       ip=request.remote_addr, prev_hash=prev_hash)
        db.session.add(row)
        db.session.flush()
        row.row_hash = compute_hash(prev_hash, row)
        db.session.commit()
        return redirect(url_for("auth.login"))
    return render_template("wizard/done.html")
