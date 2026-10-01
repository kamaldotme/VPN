"""First-boot setup wizard.

Runs over plain HTTP on the out-of-box setup WiFi. Five short screens:
welcome → admin password → internet → your WiFi → privacy mode → done.
Nothing here needs a terminal, an IP address or an authenticator app.
"""
import json
import re
import time
import bcrypt
from flask import Blueprint, render_template, request, redirect, url_for, session, flash, abort, jsonify
from .extensions import db
from .models import User, Setting, AuditLog
from .services.runner import run_script
from .services.site import read_site_conf

bp = Blueprint("wizard", __name__, url_prefix="/setup")

MIN_ADMIN_PW = 8
STEPS = ["welcome", "admin", "internet", "wifi", "mode", "done"]

MODES = {
    "direct": {
        "label": "Ad-blocking + private DNS",
        "icon": "🛡️",
        "description": "Blocks ads and trackers and encrypts DNS lookups for every device. "
                       "Fastest. Add a VPN from the dashboard whenever you like.",
    },
    "tor": {
        "label": "Tor",
        "icon": "🧅",
        "description": "Sends everything through the Tor network. Most anonymous, but slow, "
                       "and some sites block it.",
    },
}

# ISO 3166-1 alpha-2 codes offered for the WiFi regulatory domain.
COUNTRIES = [
    ("AR", "Argentina"), ("AU", "Australia"), ("AT", "Austria"), ("BD", "Bangladesh"),
    ("BE", "Belgium"), ("BR", "Brazil"), ("BG", "Bulgaria"), ("CA", "Canada"), ("CL", "Chile"),
    ("CN", "China"), ("CO", "Colombia"), ("HR", "Croatia"), ("CZ", "Czechia"), ("DK", "Denmark"),
    ("EG", "Egypt"), ("EE", "Estonia"), ("FI", "Finland"), ("FR", "France"), ("DE", "Germany"),
    ("GR", "Greece"), ("HK", "Hong Kong"), ("HU", "Hungary"), ("IS", "Iceland"), ("IN", "India"),
    ("ID", "Indonesia"), ("IE", "Ireland"), ("IL", "Israel"), ("IT", "Italy"), ("JP", "Japan"),
    ("KE", "Kenya"), ("KR", "Korea (South)"), ("LV", "Latvia"), ("LT", "Lithuania"),
    ("LU", "Luxembourg"), ("MY", "Malaysia"), ("MX", "Mexico"), ("MA", "Morocco"),
    ("NP", "Nepal"), ("NL", "Netherlands"), ("NZ", "New Zealand"), ("NG", "Nigeria"),
    ("NO", "Norway"), ("PK", "Pakistan"), ("PE", "Peru"), ("PH", "Philippines"), ("PL", "Poland"),
    ("PT", "Portugal"), ("QA", "Qatar"), ("RO", "Romania"), ("RU", "Russia"),
    ("SA", "Saudi Arabia"), ("RS", "Serbia"), ("SG", "Singapore"), ("SK", "Slovakia"),
    ("SI", "Slovenia"), ("ZA", "South Africa"), ("ES", "Spain"), ("LK", "Sri Lanka"),
    ("SE", "Sweden"), ("CH", "Switzerland"), ("TW", "Taiwan"), ("TH", "Thailand"),
    ("TR", "Türkiye"), ("UA", "Ukraine"), ("AE", "United Arab Emirates"),
    ("GB", "United Kingdom"), ("US", "United States"), ("VN", "Vietnam"),
]
COUNTRY_CODES = {c for c, _ in COUNTRIES}
SSID_RE = re.compile(r"^[A-Za-z0-9 _.\-]{1,32}$")


def _setup_done() -> bool:
    s = db.session.get(Setting, "setup_complete")
    return bool(s and s.value == "true")


def _save_setting(key: str, value: str):
    s = db.session.get(Setting, key)
    if s is None:
        db.session.add(Setting(key=key, value=value))
    else:
        s.value = value


def _json_out(out, err):
    try:
        return json.loads(out)
    except Exception:
        return {"ok": False, "error": (err or out or "no response").strip()[:300]}


def _wizard_user():
    uid = session.get("wizard_uid")
    return db.session.get(User, uid) if uid else None


def _audit(action, detail=None):
    from .services.audit_chain import compute_hash
    prev = db.session.query(AuditLog.row_hash).order_by(AuditLog.id.desc()).first()
    prev_hash = prev[0] if prev else None
    row = AuditLog(user="admin", action=action, detail=detail,
                   ip=request.remote_addr, prev_hash=prev_hash)
    db.session.add(row)
    db.session.flush()
    row.row_hash = compute_hash(prev_hash, row)


@bp.before_request
def guard():
    if _setup_done():
        abort(404)
    # Everything after the password step belongs to whoever set the password.
    open_endpoints = {"wizard.home", "wizard.welcome", "wizard.admin", "wizard.clock"}
    if request.endpoint not in open_endpoints and _wizard_user() is None:
        return redirect(url_for("wizard.admin"))


@bp.context_processor
def inject_steps():
    return {"steps_total": len(STEPS) - 1}


@bp.get("")
@bp.get("/")
def home():
    return redirect(url_for("wizard.welcome"))


@bp.route("/welcome", methods=["GET", "POST"])
def welcome():
    if request.method == "POST":
        return redirect(url_for("wizard.admin"))
    return render_template("wizard/welcome.html")


@bp.post("/clock")
def clock():
    """The Pi has no battery clock; the browser tells it the time (see set-time.sh)."""
    try:
        epoch = int(request.form.get("epoch", "0"))
    except ValueError:
        return jsonify({"ok": False}), 400
    if abs(epoch - time.time()) < 90:
        return jsonify({"ok": True, "changed": False})
    rc, out, err = run_script("set-time", [str(epoch)])
    return jsonify(_json_out(out, err))


@bp.route("/admin", methods=["GET", "POST"])
def admin():
    if request.method == "POST":
        pw1 = request.form.get("password", "")
        pw2 = request.form.get("password2", "")
        if len(pw1) < MIN_ADMIN_PW:
            flash(f"Use at least {MIN_ADMIN_PW} characters.", "error")
        elif pw1 != pw2:
            flash("The two passwords don't match.", "error")
        else:
            hashed = bcrypt.hashpw(pw1.encode(), bcrypt.gensalt()).decode()
            u = db.session.query(User).filter_by(username="admin").first()
            if not u:
                u = User(username="admin", is_admin=True, password_hash=hashed, totp_enabled=False)
                db.session.add(u)
            else:
                u.password_hash = hashed
                u.totp_enabled = False
                u.totp_secret = None
            db.session.commit()
            session["wizard_uid"] = u.id
            return redirect(url_for("wizard.internet"))
    return render_template("wizard/admin.html", min_pw=MIN_ADMIN_PW)


@bp.route("/internet", methods=["GET", "POST"])
def internet():
    if request.method == "POST":
        return redirect(url_for("wizard.wifi"))
    rc, out, err = run_script("wan-config", ["status"])
    return render_template("wizard/internet.html", wan=_json_out(out, err))


@bp.get("/wan/status")
def wan_status():
    rc, out, err = run_script("wan-config", ["status"])
    return jsonify(_json_out(out, err))


@bp.get("/wan/scan")
def wan_scan():
    rc, out, err = run_script("wan-config", ["scan"], timeout=25)
    return jsonify(_json_out(out, err))


@bp.post("/wan/wifi")
def wan_wifi():
    ssid = (request.form.get("ssid") or "").strip()
    psk = request.form.get("psk") or ""
    if not (1 <= len(ssid) <= 32) or any(c in ssid for c in ";|&$`\\\n\r") \
       or not all(0x20 <= ord(c) < 0x7f for c in ssid):
        return jsonify({"ok": False, "error": "That network name can't be used."}), 400
    if not (8 <= len(psk) <= 63):
        return jsonify({"ok": False, "error": "WiFi passwords are 8–63 characters."}), 400
    rc, out, err = run_script("wan-config", ["set-wifi", ssid, "-"], stdin=psk, timeout=50)
    return jsonify(_json_out(out, err))


@bp.route("/wifi", methods=["GET", "POST"])
def wifi():
    site = read_site_conf()
    form = {"ssid": "", "country": site.get("WIFI_COUNTRY", "US")}
    if request.method == "POST":
        ssid = (request.form.get("ssid") or "").strip()
        psk = request.form.get("psk") or ""
        psk2 = request.form.get("psk2") or ""
        country = (request.form.get("country") or "").upper()
        form = {"ssid": ssid, "country": country}
        if not SSID_RE.match(ssid):
            flash("Network name: 1–32 characters — letters, numbers, spaces, dot, dash or underscore.", "error")
        elif ssid.lower() == "privacypi-setup":
            flash("Pick a name of your own — “PrivacyPi-Setup” is reserved for setup.", "error")
        elif not (8 <= len(psk) <= 63) or not all(0x20 <= ord(c) < 0x7f for c in psk):
            flash("WiFi password: 8–63 characters (plain letters, numbers and symbols).", "error")
        elif psk != psk2:
            flash("The two WiFi passwords don't match.", "error")
        elif psk == "privacypi":
            flash("Pick a password of your own — not the setup password.", "error")
        elif country not in COUNTRY_CODES:
            flash("Choose your country.", "error")
        else:
            # Stored now, applied (WiFi restart) by the last step.
            rc, out, err = run_script("ap-config", ["country", country])
            rc, out, err = run_script("ap-config", ["set", ssid, "-"], stdin=psk)
            res = _json_out(out, err)
            if res.get("ok"):
                session["wizard_ssid"] = ssid
                return redirect(url_for("wizard.mode"))
            flash(res.get("error", "Could not save the WiFi settings."), "error")
    return render_template("wizard/wifi.html", countries=COUNTRIES, form=form)


@bp.route("/mode", methods=["GET", "POST"])
def mode():
    if not session.get("wizard_ssid"):
        return redirect(url_for("wizard.wifi"))
    if request.method == "POST":
        choice = request.form.get("mode")
        if choice not in MODES:
            flash("Pick one of the options.", "error")
        else:
            session["wizard_mode"] = choice
            return redirect(url_for("wizard.done"))
    return render_template("wizard/mode.html", modes=MODES, current=session.get("wizard_mode", "direct"))


@bp.route("/done", methods=["GET", "POST"])
def done():
    ssid = session.get("wizard_ssid")
    choice = session.get("wizard_mode")
    if not ssid:
        return redirect(url_for("wizard.wifi"))
    if choice not in MODES:
        return redirect(url_for("wizard.mode"))
    site = read_site_conf()
    ctx = {"ssid": ssid, "mode": MODES[choice], "lan_gw": site.get("LAN_GW", "10.10.10.1"),
           "host_mdns": site.get("HOST_MDNS", "privacypi.local")}
    if request.method == "POST":
        _save_setting("default_mode", choice)
        _save_setting("setup_complete", "true")
        _audit("wizard.complete", f"mode={choice}")
        db.session.commit()
        # Leaves setup mode, applies the routing mode and restarts the WiFi
        # under its new name a few seconds from now.
        rc, out, err = run_script("setup-finish", [choice])
        session.clear()
        return render_template("wizard/finished.html", **ctx)
    return render_template("wizard/done.html", **ctx)
