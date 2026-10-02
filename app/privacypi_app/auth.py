from datetime import datetime, timedelta
from flask import Blueprint, render_template, request, redirect, url_for, flash, session, jsonify
from flask_login import login_user, logout_user, login_required, current_user
import bcrypt, pyotp
from .extensions import db, login_manager
from .models import User, AuditLog, LoginAttempt

LOCKOUT_FAILS = 5
LOCKOUT_WINDOW = timedelta(minutes=15)


def _is_locked_out(ip: str) -> bool:
    if not ip:
        return False
    cutoff = datetime.utcnow() - LOCKOUT_WINDOW
    n = db.session.query(LoginAttempt).filter(
        LoginAttempt.ip == ip,
        LoginAttempt.timestamp >= cutoff,
    ).count()
    return n >= LOCKOUT_FAILS


def _record_fail(ip: str, username: str = "", ua: str = ""):
    db.session.add(LoginAttempt(ip=ip or "?", username=username[:64], user_agent=ua[:256]))
    db.session.commit()


def _clear_fails(ip: str):
    db.session.query(LoginAttempt).filter(LoginAttempt.ip == ip).delete()
    db.session.commit()

bp = Blueprint("auth", __name__)

@login_manager.user_loader
def load_user(uid):
    try:
        raw_id, _, fp = str(uid).partition(".")
        u = db.session.get(User, int(raw_id))
    except (ValueError, TypeError):
        return None
    # The fingerprint must match the current password (see User.get_id).
    if u is None or u.get_id() != str(uid):
        return None
    return u

def _audit(user: str, action: str, detail: str = None):
    from .services.audit_chain import compute_hash
    prev = db.session.query(AuditLog.row_hash).order_by(AuditLog.id.desc()).first()
    prev_hash = prev[0] if prev else None
    row = AuditLog(
        timestamp=datetime.utcnow(), user=user, action=action,
        detail=detail, ip=request.remote_addr, prev_hash=prev_hash,
    )
    db.session.add(row)
    db.session.flush()
    row.row_hash = compute_hash(prev_hash, row)
    db.session.commit()

@bp.route("/login", methods=["GET", "POST"])
def login():
    if current_user.is_authenticated:
        return redirect(url_for("pages.dashboard"))
    src_ip = request.remote_addr or ""
    if _is_locked_out(src_ip):
        _audit("(blocked)", "login.locked_out", detail=f"ip={src_ip}")
        flash("Too many failed attempts. Try again in 15 minutes.", "error")
        return render_template("login.html"), 429
    if request.method == "POST":
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "")
        u: User | None = db.session.query(User).filter_by(username=username).first()
        if u and bcrypt.checkpw(password.encode(), u.password_hash.encode()):
            _clear_fails(src_ip)
            session["pre_2fa_uid"] = u.id
            # "Keep me signed in on this device": a long-lived cookie, so the
            # user is not asked again after closing the browser or a Pi restart.
            remember = request.form.get("remember") == "1"
            session["pre_2fa_remember"] = remember
            _audit(username, "login.password.ok")
            if u.totp_enabled:
                return redirect(url_for("auth.totp"))
            login_user(u, remember=remember)
            u.last_login_at = datetime.utcnow()
            db.session.commit()
            return redirect(url_for("pages.dashboard"))
        _record_fail(src_ip, username or "", request.headers.get("User-Agent", ""))
        _audit(username or "(blank)", "login.password.fail", detail=f"ip={src_ip}")
        flash("Wrong username or password.", "error")
    return render_template("login.html")

@bp.route("/2fa", methods=["GET", "POST"])
def totp():
    uid = session.get("pre_2fa_uid")
    if not uid:
        return redirect(url_for("auth.login"))
    u: User | None = db.session.get(User, uid)
    if request.method == "POST":
        code = request.form.get("code", "").strip()
        if u and u.totp_secret and pyotp.TOTP(u.totp_secret).verify(code, valid_window=1):
            session.pop("pre_2fa_uid", None)
            login_user(u, remember=bool(session.pop("pre_2fa_remember", False)))
            u.last_login_at = datetime.utcnow()
            db.session.commit()
            _audit(u.username, "login.totp.ok")
            return redirect(url_for("pages.dashboard"))
        _audit(u.username if u else "(none)", "login.totp.fail")
        flash("That code didn't work. Try the newest one from your app.", "error")
    return render_template("totp.html")

@bp.route("/logout")
@login_required
def logout():
    _audit(current_user.username, "logout")
    logout_user()
    return redirect(url_for("auth.login"))
