"""Main UI pages (post-wizard)."""
import json, os, subprocess
from datetime import datetime
from flask import Blueprint, render_template, request, jsonify, current_app, abort, Response
from flask_login import login_required, current_user
from .extensions import db
from .models import AuditLog, Setting, Proxy, ProxyChain, DomainRoute, WebAuthnCredential, User, LoginAttempt, AlertRule, AlertConfig
from .services.runner import run_script
from .services.crypto import vault_encrypt, vault_decrypt

bp = Blueprint("pages", __name__)

def _audit(action, detail=None):
    """Insert an audit row and update the HMAC chain hash."""
    from .services.audit_chain import compute_hash
    user = current_user.username if current_user.is_authenticated else "(anon)"
    prev = db.session.query(AuditLog.row_hash).order_by(AuditLog.id.desc()).first()
    prev_hash = prev[0] if prev else None
    row = AuditLog(user=user, action=action, detail=detail,
                   ip=request.remote_addr, prev_hash=prev_hash)
    db.session.add(row)
    db.session.flush()  # populate row.id + timestamp
    row.row_hash = compute_hash(prev_hash, row)
    db.session.commit()

@bp.get("/")
@login_required
def dashboard():
    rc, out, err = run_script("vpn-status")
    try:
        status = json.loads(out)
    except Exception:
        status = {"mode": "?", "error": err or "no status"}
    profile = db.session.get(Setting, "profile")
    return render_template("pages/dashboard.html", status=status,
                           profile=profile.value if profile else "(none)")

@bp.get("/modes")
@login_required
def modes():
    return render_template("pages/modes.html",
                           allowed_modes=current_app.config["ALLOWED_MODES"])

@bp.get("/vpn")
@login_required
def vpn():
    providers = ["nordvpn","expressvpn","mullvad","protonvpn","ivpn",
                 "surfshark","airvpn","custom-ovpn","custom-wg"]
    return render_template("pages/vpn.html", providers=providers)

@bp.get("/tor")
@login_required
def tor():
    return render_template("pages/tor.html")

@bp.get("/dns")
@login_required
def dns():
    profiles = ["Light", "Standard", "Strict", "Family"]
    current = db.session.get(Setting, "adguard_profile")
    return render_template("pages/dns.html",
                           profiles=profiles,
                           current=current.value if current else "Standard")

@bp.get("/diagnostics")
@login_required
def diagnostics():
    return render_template("pages/diagnostics.html")

@bp.post("/api/diag/<tool>")
@login_required
def run_diag(tool):
    target = request.json.get("target", "") if request.is_json else request.form.get("target","")
    target = "".join(c for c in target if c.isalnum() or c in ".-:")
    cmd_map = {
        "ping": ["ping", "-c", "3", "-W", "2", target or "1.1.1.1"],
        "traceroute": ["traceroute", "-w", "2", "-q", "1", target or "1.1.1.1"],
        "dig": ["dig", "+short", target or "cloudflare.com"],
    }
    if tool not in cmd_map: abort(400)
    try:
        p = subprocess.run(cmd_map[tool], capture_output=True, text=True, timeout=25)
    except FileNotFoundError:
        return jsonify({"stdout": "", "stderr": f"{tool} is not installed on this device", "rc": 127})
    except subprocess.TimeoutExpired:
        return jsonify({"stdout": "", "stderr": "timed out — no answer", "rc": 124})
    _audit(f"diag.{tool}", target)
    return jsonify({"stdout": p.stdout, "stderr": p.stderr, "rc": p.returncode})

# --- WAN (internet uplink: Ethernet vs WiFi client) -------------------------
def _script_json(out, err):
    """Parse a privileged script's JSON stdout into a dict for jsonify."""
    try:
        return json.loads(out)
    except Exception:
        return {"ok": False, "error": (err or out or "no output").strip()}

@bp.get("/network")
@login_required
def network():
    rc, out, err = run_script("wan-config", ["status"])
    return render_template("pages/network.html", wan=_script_json(out, err))

@bp.get("/api/wan/status")
@login_required
def wan_status():
    rc, out, err = run_script("wan-config", ["status"])
    return jsonify(_script_json(out, err))

@bp.get("/api/wan/scan")
@login_required
def wan_scan():
    rc, out, err = run_script("wan-config", ["scan"], timeout=20)
    return jsonify(_script_json(out, err))

@bp.post("/api/wan/ethernet")
@login_required
def wan_ethernet():
    rc, out, err = run_script("wan-config", ["set-ethernet"], timeout=45)
    _audit("wan.ethernet")
    return jsonify(_script_json(out, err))

@bp.post("/api/wan/wifi")
@login_required
def wan_wifi():
    ssid = (request.form.get("ssid") or "").strip()
    psk = request.form.get("psk") or ""
    # SSID: 1-32 chars, no shell metacharacters / control chars.
    if not (1 <= len(ssid) <= 32) or any(c in ssid for c in ";|&$`\\\n\r") \
       or not all(0x20 <= ord(c) < 0x7f for c in ssid):
        return jsonify({"ok": False, "error": "invalid SSID"}), 400
    if not (8 <= len(psk) <= 63):
        return jsonify({"ok": False, "error": "WiFi password must be 8-63 characters"}), 400
    # PSK travels via stdin only — never argv, never the audit log.
    rc, out, err = run_script("wan-config", ["set-wifi", ssid, "-"], stdin=psk, timeout=45)
    _audit("wan.wifi", ssid)
    return jsonify(_script_json(out, err))

@bp.get("/system")
@login_required
def system():
    info = {}
    try:
        with open("/proc/loadavg") as f: info["load"] = f.read().strip()
        with open("/sys/class/thermal/thermal_zone0/temp") as f: info["temp"] = round(int(f.read())/1000, 1)
    except Exception:
        info["load"] = "?"; info["temp"] = "?"
    p = subprocess.run(["uptime","-p"], capture_output=True, text=True)
    info["uptime"] = p.stdout.strip() or "?"
    return render_template("pages/system.html", info=info)

@bp.get("/audit")
@login_required
def audit():
    rows = db.session.query(AuditLog).order_by(AuditLog.id.desc()).limit(200).all()
    return render_template("pages/audit.html", rows=rows)


@bp.get("/api/audit/verify")
@login_required
def audit_verify():
    """Walk the entire audit log and verify the HMAC chain."""
    from .services.audit_chain import verify_chain
    rows = db.session.query(AuditLog).order_by(AuditLog.id.asc()).all()
    ok, bad_id, total = verify_chain(rows)
    return jsonify({"ok": ok, "first_bad_id": bad_id, "total_checked": total})


@bp.post("/api/recovery/export")
@login_required
def recovery_export():
    """Show 24-word BIP-39 mnemonic of master.key. Requires admin password
    re-confirmation each call (no caching). Audited."""
    pw = request.form.get("password", "")
    import bcrypt
    if not bcrypt.checkpw(pw.encode(), current_user.password_hash.encode()):
        _audit("recovery.export.fail", "wrong password")
        return jsonify({"ok": False, "error": "wrong password"}), 401
    try:
        from .services.recovery import export_mnemonic
        words = export_mnemonic()
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500
    _audit("recovery.export.ok", "mnemonic shown to admin")
    return jsonify({"ok": True, "mnemonic": words,
                    "warning": "Write these down on paper, store offline. Never paste online."})


# ============================================================
# Real-time DNS query stream (SSE) + per-MAC traffic.
# ============================================================
def _adguard_to_ui(r):
    """Project AdGuard's verbose query record to the slim shape the UI uses."""
    q = r.get("question") or {}
    rules = r.get("rules") or []
    return {
        "t": r.get("time", ""),
        "host": q.get("name", ""),
        "type": q.get("type", ""),
        "client": r.get("client", ""),
        "blocked": r.get("reason", "").startswith("Filtered"),
        "ms": float(r.get("elapsedMs", 0) or 0),
        "rule": (rules[0].get("text") if rules else ""),
    }


@bp.get("/api/dns/recent")
@login_required
def dns_recent():
    rc, out, err = run_script("dns-tail", ["recent", "100"])
    try:
        rows = json.loads(out).get("data", [])
    except Exception:
        rows = []
    return jsonify({"queries": [_adguard_to_ui(r) for r in rows]})


@bp.get("/api/dns/stream")
@login_required
def dns_stream():
    """Server-Sent Events: poll AdGuard's API every 2s and emit new queries.

    Uses AdGuard's in-memory log (real-time), not the file (buffered).
    """
    import time
    last_seen = ""

    def gen():
        nonlocal last_seen
        yield "event: hello\ndata: {}\n\n"
        # First emit recent N
        rc, out, err = run_script("dns-tail", ["recent", "20"])
        try:
            rows = list(reversed(json.loads(out).get("data", [])))
        except Exception:
            rows = []
        for r in rows:
            ui = _adguard_to_ui(r)
            last_seen = max(last_seen, ui["t"])
            yield f"data: {json.dumps(ui)}\n\n"

        while True:
            time.sleep(2)
            rc, out, err = run_script("dns-tail", ["since", last_seen or "1970"])
            try:
                rows = list(reversed(json.loads(out).get("data", [])))
            except Exception:
                rows = []
            for r in rows:
                ui = _adguard_to_ui(r)
                last_seen = max(last_seen, ui["t"])
                yield f"data: {json.dumps(ui)}\n\n"
            yield ": ping\n\n"  # keep-alive

    return Response(gen(), mimetype="text/event-stream", headers={
        "Cache-Control": "no-cache",
        "X-Accel-Buffering": "no",
    })


@bp.post("/api/mac-traffic/refresh")
@login_required
def mac_traffic_refresh():
    rc, out, err = run_script("mac-traffic", ["refresh"])
    return jsonify({"ok": rc == 0, "raw": (out + err)[:300]})


@bp.get("/api/mac-traffic")
@login_required
def mac_traffic():
    rc, out, err = run_script("mac-traffic", ["stats"])
    try:
        rows = json.loads(out)
    except Exception:
        rows = []
    # Enrich with friendly device labels from Setting (if user has named MACs)
    labels = {}
    for s in db.session.query(Setting).filter(Setting.key.like("device.label.%")).all():
        labels[s.key.replace("device.label.", "").lower()] = s.value
    for r in rows:
        r["label"] = labels.get(r["mac"].lower(), "")
    return jsonify({"devices": rows})


@bp.post("/api/recovery/restore")
@login_required
def recovery_restore():
    """Replace master.key from a 24-word mnemonic. DANGEROUS — invalidates
    every existing encrypted credential unless they were encrypted with
    the SAME key the mnemonic represents."""
    pw = request.form.get("password", "")
    words = (request.form.get("mnemonic") or "").strip()
    import bcrypt
    if not bcrypt.checkpw(pw.encode(), current_user.password_hash.encode()):
        return jsonify({"ok": False, "error": "wrong password"}), 401
    try:
        from .services.recovery import restore_from_mnemonic
        restore_from_mnemonic(words)
    except ValueError as e:
        return jsonify({"ok": False, "error": str(e)}), 400
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500
    _audit("recovery.restore", "master.key replaced from mnemonic")
    return jsonify({"ok": True, "note": "Restart privacypi-flask for the new key to take effect."})

# JSON endpoints (the existing /api/mode and /api/status remain)
@bp.post("/api/mode/<mode>")
@login_required
def set_mode(mode):
    if mode not in current_app.config["ALLOWED_MODES"]:
        abort(400, "invalid mode")
    if mode in ("openvpn", "wireguard"):
        # A VPN mode needs a tunnel: reconnect the provider used last.
        last = db.session.get(Setting, "vpn_last_provider")
        if not last or not last.value:
            return jsonify({"ok": False, "stderr": "Set up a VPN first: open VPN providers, add your account and press Connect."}), 400
        rc, out, err = run_script("vpn-connect", ["up", last.value], timeout=80)
        res = _script_json(out, err)
        _audit(f"mode.{mode}", detail=(out + err)[:500])
        return jsonify({"ok": bool(res.get("ok")), "stdout": out, "stderr": res.get("error", err)})
    run_script("vpn-connect", ["stop-tunnels"], timeout=30)
    rc, out, err = run_script("route-mode", [mode])
    _audit(f"mode.{mode}", detail=(out + err)[:500])
    return jsonify({"ok": rc == 0, "stdout": out, "stderr": err})

@bp.get("/api/status")
@login_required
def status():
    rc, out, err = run_script("vpn-status")
    if rc != 0:
        return jsonify({"ok": False, "error": err}), 500
    try:
        return jsonify(json.loads(out))
    except Exception as e:
        return jsonify({"ok": False, "error": str(e), "raw": out}), 500


# ====== Plan 10 wiring routes ======
import bcrypt
from werkzeug.utils import secure_filename
from base64 import b64encode

@bp.post("/api/vpn/<provider>/credentials")
@login_required
def vpn_creds(provider):
    if provider not in ("nordvpn","expressvpn","mullvad","protonvpn","ivpn",
                        "surfshark","airvpn","custom-ovpn","custom-wg"):
        abort(400)
    u = request.form.get("username","").strip()
    p = request.form.get("password","")
    if not u or not p:
        return jsonify({"ok": False, "error": "username + password required"}), 400
    rc, out, err = run_script("vpn-write", ["auth", provider, u, p])
    _audit(f"vpn.creds.{provider}", "set")
    return jsonify({"ok": rc == 0, "stdout": out, "stderr": err})

@bp.post("/api/vpn/<provider>/upload")
@login_required
def vpn_upload(provider):
    f = request.files.get("file")
    if not f:
        return jsonify({"ok": False, "error": "no file"}), 400
    name = secure_filename(f.filename)
    if not name or not name.endswith((".ovpn", ".conf")):
        return jsonify({"ok": False, "error": "must be .ovpn or .conf"}), 400
    content = f.read()
    if len(content) > 200_000:
        return jsonify({"ok": False, "error": "file too large"}), 400
    b64 = b64encode(content).decode()
    rc, out, err = run_script("vpn-write", ["server", provider, name, b64])
    _audit(f"vpn.upload.{provider}", name)
    return jsonify({"ok": rc == 0, "stdout": out, "stderr": err, "filename": name})

@bp.post("/api/system/<action>")
@login_required
def system_action(action):
    if action not in ("reboot","shutdown","restart-flask","factory-reset"):
        abort(400)
    rc, out, err = run_script("system-action", [action])
    _audit(f"system.{action}")
    return jsonify({"ok": rc == 0, "stdout": out, "stderr": err})

@bp.post("/api/password")
@login_required
def change_password():
    cur = request.form.get("current","")
    new = request.form.get("new","")
    new2 = request.form.get("new2","")
    if not bcrypt.checkpw(cur.encode(), current_user.password_hash.encode()):
        return jsonify({"ok": False, "error": "current password wrong"}), 400
    if new != new2 or len(new) < 8:
        return jsonify({"ok": False, "error": "The new passwords must match and be at least 8 characters."}), 400
    user = current_user._get_current_object()
    user.password_hash = bcrypt.hashpw(new.encode(), bcrypt.gensalt()).decode()
    db.session.commit()
    # The login identity includes a password fingerprint: every other device is
    # signed out by the change; keep THIS browser signed in.
    from flask_login import login_user
    login_user(user)
    _audit("password.change")
    return jsonify({"ok": True})

@bp.post("/api/dns/profile")
@login_required
def set_dns_profile():
    p = request.form.get("profile","")
    if p not in ("Light","Standard","Strict","Family"):
        return jsonify({"ok": False, "error": "invalid profile"}), 400
    # Actually apply it to AdGuard Home — storing the name alone changes nothing.
    rc, out, err = run_script("dns-profile", [p], timeout=60)
    res = _script_json(out, err)
    if not res.get("ok"):
        return jsonify(res), 502
    s = db.session.get(Setting, "adguard_profile")
    if s is None:
        db.session.add(Setting(key="adguard_profile", value=p))
    else:
        s.value = p
    db.session.commit()
    _audit("dns.profile", p)
    return jsonify({"ok": True, "profile": p})


# ====== Plan 11 backup + leak tests ======
import socket, urllib.request
from flask import send_file
from io import BytesIO

@bp.get("/backup")
@login_required
def backup_page():
    return render_template("pages/backup.html")

@bp.post("/api/backup/download")
@login_required
def backup_download():
    pw = request.form.get("password","")
    if not bcrypt.checkpw(pw.encode(), current_user.password_hash.encode()):
        return jsonify({"ok": False, "error": "wrong password"}), 401
    from .services.runner import run_script_bin
    rc, out, err = run_script_bin("backup-create", [pw])
    if rc != 0:
        return jsonify({"ok": False, "error": err}), 500
    _audit("backup.download")
    return Response(out, mimetype="application/octet-stream",
                    headers={"Content-Disposition": "attachment; filename=privacypi-backup.bin"})

@bp.get("/api/leak-test")
@login_required
def leak_test():
    """Compare AdGuard's view of public IP vs Pi's tunnel-routed lookup."""
    results = {}
    try:
        with urllib.request.urlopen("https://api.ipify.org", timeout=5) as r:
            results["public_ip"] = r.read().decode().strip()
    except Exception as e:
        results["public_ip_err"] = str(e)
    rc, out, err = run_script("vpn-status")
    try:
        import json as _json
        results["status"] = _json.loads(out)
    except Exception:
        results["status_err"] = err
    return jsonify(results)



# ====== Megaplan A: Network Visibility ======
@bp.get("/devices")
@login_required
def devices():
    return render_template("pages/devices.html")

@bp.get("/api/devices")
@login_required
def list_devices():
    rc, out, err = run_script("list-clients")
    if rc != 0:
        return jsonify({"clients": [], "error": err}), 500
    try:
        return jsonify(json.loads(out))
    except Exception as e:
        return jsonify({"clients": [], "error": str(e), "raw": out[:200]}), 500

@bp.post("/api/device/<mac>/mode/<mode>")
@login_required
def device_set_mode(mac, mode):
    if mode not in ("direct", "tor", "killswitch", "none"):
        abort(400, "invalid mode")
    rc, out, err = run_script("device-route", ["assign", mac, mode])
    _audit(f"device.assign.{mode}", mac)
    return jsonify({"ok": rc == 0, "stdout": out.strip(), "stderr": err})

@bp.get("/api/bandwidth")
@login_required
def bandwidth():
    """Return vnstat JSON for the LAN bridge, the AP radio and the wired uplink."""
    import subprocess as sp
    from .services.site import read_site_conf
    site = read_site_conf()
    out = {}
    for iface in (site.get("LAN_BRIDGE", "br-vlan10"), site.get("AP_IFACE", ""), site.get("ETH_IFACE", "eth0")):
        if not iface:
            continue
        try:
            p = sp.run(["vnstat", "-i", iface, "--json"], capture_output=True, text=True, timeout=5)
            out[iface] = json.loads(p.stdout) if p.returncode == 0 else {"error": p.stderr.strip()}
        except Exception as e:
            out[iface] = {"error": str(e)}
    return jsonify(out)



# ====== Megaplan B: Alerts ======
import json as _json_alerts
@bp.get("/alerts")
@login_required
def alerts_page():
    from .models import AlertConfig
    configs = db.session.query(AlertConfig).all()
    return render_template("pages/alerts.html",
                           configs=configs,
                           valid_triggers=sorted(["mode.killswitch","vpn.drop","login.fail.repeated",
                                                  "system.reboot","system.factory-reset","wizard.complete",
                                                  "intrusion.detected"]))

@bp.post("/api/alerts")
@login_required
def alerts_create():
    from .models import AlertConfig
    label = request.form.get("label","").strip() or "Unnamed"
    url = request.form.get("url","").strip()
    triggers = request.form.getlist("triggers")
    if not url:
        return jsonify({"ok": False, "error": "URL required"}), 400
    cfg = AlertConfig(label=label[:64], url=url[:512],
                      triggers=_json_alerts.dumps(triggers), enabled=True)
    db.session.add(cfg); db.session.commit()
    _audit("alert.create", label)
    return jsonify({"ok": True, "id": cfg.id})

@bp.post("/api/alerts/<int:cfg_id>/delete")
@login_required
def alerts_delete(cfg_id):
    from .models import AlertConfig
    cfg = db.session.get(AlertConfig, cfg_id)
    if not cfg: return jsonify({"ok": False}), 404
    db.session.delete(cfg); db.session.commit()
    _audit("alert.delete", str(cfg_id))
    return jsonify({"ok": True})

@bp.post("/api/alerts/<int:cfg_id>/test")
@login_required
def alerts_test(cfg_id):
    from .models import AlertConfig
    from .services.alerts import test_one
    cfg = db.session.get(AlertConfig, cfg_id)
    if not cfg: return jsonify({"ok": False}), 404
    sent = test_one(cfg.url, cfg.label)
    _audit("alert.test", cfg.label)
    return jsonify({"ok": bool(sent), "queued": True})



# ====== Megaplan B Tasks 2+3: Speed test + Self-update ======
@bp.post("/api/speedtest")
@login_required
def api_speedtest():
    rc, out, err = run_script("speedtest")
    try:
        result = json.loads(out)
    except Exception:
        result = {"error": "couldn't parse speedtest output", "raw": out[:300]}
    if rc == 0 and "download" in result:
        # Save to DB. speedtest-cli format: {download: bps, upload: bps, ping: ms, server: {...}}
        from .models import SpeedTestResult
        active = db.session.get(Setting, "default_mode")
        try:
            mbps_dl = (result.get("download", 0) or 0) / 1_000_000
            mbps_ul = (result.get("upload", 0) or 0) / 1_000_000
            ping = (result.get("ping", 0) or 0)
            server = (result.get("server", {}) or {}).get("sponsor", "?")
        except Exception:
            mbps_dl = mbps_ul = ping = 0; server = "?"
        r = SpeedTestResult(mode=active.value if active else "direct",
                            download_mbps=mbps_dl, upload_mbps=mbps_ul,
                            ping_ms=ping, server=server[:128] if server else None)
        db.session.add(r); db.session.commit()
        _audit("speedtest", f"{mbps_dl:.1f}/{mbps_ul:.1f}Mbps")
    return jsonify(result)

@bp.get("/api/speedtest/history")
@login_required
def speedtest_history():
    from .models import SpeedTestResult
    rows = db.session.query(SpeedTestResult).order_by(SpeedTestResult.id.desc()).limit(20).all()
    return jsonify({"results": [
        {"timestamp": r.timestamp.isoformat(), "mode": r.mode,
         "download_mbps": r.download_mbps, "upload_mbps": r.upload_mbps,
         "ping_ms": r.ping_ms, "server": r.server}
        for r in rows
    ]})

@bp.get("/api/system/update-check")
@login_required
def system_update_check():
    rc, out, err = run_script("self-update", ["check"])
    try:
        return jsonify(json.loads(out))
    except Exception:
        return jsonify({"error": err or "couldn't parse", "raw": out[:300]}), 500

@bp.post("/api/system/update-apply")
@login_required
def system_update_apply():
    rc, out, err = run_script("self-update", ["apply"])
    _audit("system.update.apply")
    return jsonify({"ok": rc == 0, "stdout": out, "stderr": err})



# ====== Megaplan C: WG server, schedules ======
@bp.get("/wg-server")
@login_required
def wg_server_page():
    rc, out, err = run_script("wg-server", ["status"])
    try: status = json.loads(out)
    except: status = {"running": False}
    rc, peers_out, _ = run_script("wg-server", ["list-peers"])
    try: peers = json.loads(peers_out).get("peers", [])
    except: peers = []
    return render_template("pages/wg_server.html", status=status, peers=peers)

@bp.post("/api/wg-server/init")
@login_required
def wg_init():
    rc, out, err = run_script("wg-server", ["init"])
    _audit("wg-server.init")
    try: return jsonify(json.loads(out))
    except: return jsonify({"ok": False, "error": err})

@bp.post("/api/wg-server/start")
@login_required
def wg_start():
    rc, out, err = run_script("wg-server", ["start"])
    _audit("wg-server.start")
    return jsonify({"ok": rc == 0, "out": out, "err": err})

@bp.post("/api/wg-server/stop")
@login_required
def wg_stop():
    rc, out, err = run_script("wg-server", ["stop"])
    _audit("wg-server.stop")
    return jsonify({"ok": rc == 0, "out": out, "err": err})

@bp.post("/api/wg-server/peer")
@login_required
def wg_add_peer():
    name = request.form.get("name","").strip()
    if not name or not name.replace("-","").replace("_","").isalnum():
        return jsonify({"ok": False, "error": "name required (alphanumeric/-/_)"}), 400
    rc, out, err = run_script("wg-server", ["add-peer", name])
    _audit("wg-server.add-peer", name)
    try: return jsonify(json.loads(out))
    except: return jsonify({"ok": False, "error": err})

@bp.get("/api/wg-server/peer/<name>/qr")
@login_required
def wg_peer_qr(name):
    if not name.replace("-","").replace("_","").isalnum():
        abort(400)
    rc, out, err = run_script("wg-server", ["show-config", name])
    if rc != 0 or not out.strip():
        return jsonify({"ok": False, "error": err}), 404
    try:
        import qrcode
        from io import BytesIO
        from base64 import b64encode
        img = qrcode.make(out)
        buf = BytesIO(); img.save(buf, format="PNG")
        return jsonify({"ok": True, "qr_b64": b64encode(buf.getvalue()).decode(), "config": out})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)})

@bp.post("/api/wg-server/peer/<name>/delete")
@login_required
def wg_remove_peer(name):
    if not name.replace("-","").replace("_","").isalnum():
        abort(400)
    rc, out, err = run_script("wg-server", ["remove-peer", name])
    _audit("wg-server.remove-peer", name)
    return jsonify({"ok": rc == 0})

# ====== Schedules ======
@bp.get("/schedule")
@login_required
def schedule_page():
    import os, json as _j
    sched = []
    if os.path.exists("/etc/privacypi/schedule.json"):
        try:
            with open("/etc/privacypi/schedule.json") as f: sched = _j.load(f)
        except: pass
    return render_template("pages/schedule.html", schedule=sched)

@bp.post("/api/schedule")
@login_required
def schedule_save():
    """Save schedule.json. Body is JSON list of rules."""
    data = request.get_json() or []
    # Validate
    for r in data:
        if not all(k in r for k in ("name", "mode", "start", "end")):
            return jsonify({"ok": False, "error": "missing fields"}), 400
        if r["mode"] not in current_app.config["ALLOWED_MODES"]:
            return jsonify({"ok": False, "error": f"bad mode: {r['mode']}"}), 400
    import json as _j, os
    os.makedirs("/etc/privacypi", exist_ok=True)
    with open("/etc/privacypi/schedule.json", "w") as f:
        _j.dump(data, f, indent=2)
    _audit("schedule.save", f"{len(data)} rules")
    return jsonify({"ok": True})



# ====== Megaplan D: DNS-over-Tor, bridges, anomaly ======
@bp.post("/api/dns/tor-mode")
@login_required
def dns_tor_mode():
    state = request.form.get("state","off")
    if state not in ("on","off"):
        return jsonify({"ok": False}), 400
    rc, out, err = run_script("tor-dns", [state])
    _audit(f"dns.tor.{state}")
    return jsonify({"ok": rc == 0, "out": out, "err": err})

@bp.post("/api/tor/bridges")
@login_required
def tor_bridges_set():
    bridges_text = request.form.get("bridges","")
    # Pipe to script via stdin; runner doesn't support stdin so we use direct subprocess
    import subprocess
    p = subprocess.run(["sudo","-n","/opt/privacypi/scripts/tor-bridges.sh","set"],
                       input=bridges_text, capture_output=True, text=True, timeout=15)
    try: result = json.loads(p.stdout)
    except: result = {"ok": p.returncode == 0, "stdout": p.stdout, "stderr": p.stderr}
    _audit("tor.bridges.set", f"{bridges_text.count(chr(10))} lines")
    return jsonify(result)

@bp.get("/api/tor/bridges")
@login_required
def tor_bridges_status():
    rc, out, err = run_script("tor-bridges", ["status"])
    try: return jsonify(json.loads(out))
    except: return jsonify({"error": err})

@bp.get("/api/anomalies")
@login_required
def anomalies_get():
    """Read latest anomaly detection result."""
    import os
    path = "/var/lib/privacypi/anomalies.json"
    if not os.path.exists(path):
        return jsonify({"timestamp": None, "anomalies": [], "queries_analyzed": 0})
    try:
        with open(path) as f: return jsonify(json.load(f))
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@bp.post("/api/anomalies/run")
@login_required
def anomalies_run():
    rc, out, err = run_script("anomaly-detect", ["--window-minutes","60","--out","/var/lib/privacypi/anomalies.json"])
    _audit("anomaly.run")
    try: return jsonify(json.loads(out))
    except: return jsonify({"error": err})

@bp.get("/anomalies")
@login_required
def anomalies_page():
    return render_template("pages/anomalies.html")



# ====== Internal alert hook (called from privileged shell scripts) ======
# Bound to localhost only via firewall; no CSRF/auth (scripts can't easily
# authenticate). Signed via shared secret in /etc/privacypi/alert.secret.
from .extensions import csrf as _csrf

@bp.post("/api/alert/internal/<trigger>")
@_csrf.exempt
def alert_internal(trigger):
    import os
    secret_path = "/etc/privacypi/alert.secret"
    if not os.path.exists(secret_path):
        return jsonify({"ok": False, "error": "no secret configured"}), 503
    with open(secret_path) as f:
        expected = f.read().strip()
    presented = request.headers.get("X-Internal-Secret","").strip()
    if presented != expected:
        return jsonify({"ok": False, "error": "bad secret"}), 401
    # Only accept from loopback
    if request.remote_addr not in ("127.0.0.1", "::1", "10.10.10.1"):
        return jsonify({"ok": False, "error": "not local"}), 403

    from .services.alerts import send
    msg = request.form.get("message", f"Triggered: {trigger}")
    level = request.form.get("level", "warn")
    sent = send(msg, level=level, trigger=trigger)
    from .services.audit_chain import compute_hash
    prev = db.session.query(AuditLog.row_hash).order_by(AuditLog.id.desc()).first()
    prev_hash = prev[0] if prev else None
    row = AuditLog(user="(internal)", action=f"alert.{trigger}",
                   detail=msg, ip=request.remote_addr, prev_hash=prev_hash)
    db.session.add(row)
    db.session.flush()
    row.row_hash = compute_hash(prev_hash, row)
    db.session.commit()
    return jsonify({"ok": True, "sent": bool(sent)})


# ====== Backup restore upload ======
@bp.post("/api/backup/restore")
@login_required
def backup_restore():
    # The typed password is the one the BACKUP was made with (it decrypts the
    # file) — it need not equal today's dashboard password, e.g. after a
    # factory reset. A wrong password simply fails to decrypt.
    pw = request.form.get("password","")
    if not pw:
        return jsonify({"ok": False, "error": "Enter the password this backup was made with."}), 400
    f = request.files.get("file")
    if not f:
        return jsonify({"ok": False, "error": "no file"}), 400
    # Save to temp + invoke restore script
    import tempfile, subprocess, os
    fd, path = tempfile.mkstemp(suffix=".bin", dir="/tmp")
    try:
        with os.fdopen(fd, "wb") as out:
            out.write(f.read())
        # Restore script reads from stdin
        with open(path, "rb") as inp:
            p = subprocess.run(
                ["sudo","-n","/opt/privacypi/scripts/backup-restore.sh", pw],
                stdin=inp, capture_output=True, timeout=60)
        ok = p.returncode == 0
        _audit("backup.restore", "ok" if ok else "fail")
        return jsonify({"ok": ok, "stdout": p.stdout.decode("utf-8","replace"),
                        "stderr": p.stderr.decode("utf-8","replace")})
    finally:
        os.unlink(path)


# ============================================================
# Proxies — outbound SOCKS5 / Shadowsocks / VLESS / VMess /
# Trojan / Hysteria2 / SSH-Dynamic. Replaces the un-surfaced
# proxy plumbing with a real UI.
# ============================================================
PROXY_KINDS = ("socks5", "ss", "vless", "vmess", "trojan", "hysteria2", "ssh")


def _proxy_to_dict(p, *, reveal=False):
    return {
        "id": p.id,
        "label": p.label,
        "kind": p.kind,
        "note": p.note or "",
        "enabled": p.enabled,
        "is_active": p.is_active,
        "url": vault_decrypt(p.url_encrypted) if reveal else None,
        "url_redacted": _redact_url(vault_decrypt(p.url_encrypted) or ""),
        "last_test_ok": p.last_test_ok,
        "last_test_at": p.last_test_at.isoformat() if p.last_test_at else None,
        "last_test_detail": p.last_test_detail,
    }


def _redact_url(url: str) -> str:
    if "://" not in url:
        return ""
    scheme, rest = url.split("://", 1)
    if "@" in rest:
        creds, host = rest.split("@", 1)
        return f"{scheme}://***@{host}"
    return f"{scheme}://{rest[:24]}…" if len(rest) > 24 else url


@bp.get("/proxies")
@login_required
def proxies_page():
    return render_template("pages/proxies.html", kinds=PROXY_KINDS)


@bp.get("/api/proxies")
@login_required
def proxies_list():
    rows = db.session.query(Proxy).order_by(Proxy.created_at.desc()).all()
    return jsonify({"proxies": [_proxy_to_dict(p) for p in rows]})


@bp.post("/api/proxies")
@login_required
def proxy_create():
    label = (request.form.get("label") or "").strip()
    kind = (request.form.get("kind") or "").strip()
    url = (request.form.get("url") or "").strip()
    note = (request.form.get("note") or "").strip()[:256] or None
    if not label or kind not in PROXY_KINDS or not url:
        return jsonify({"ok": False, "error": "label, kind, url required"}), 400
    if db.session.query(Proxy).filter_by(label=label).first():
        return jsonify({"ok": False, "error": "label already exists"}), 409
    p = Proxy(label=label, kind=kind, url_encrypted=vault_encrypt(url), note=note)
    db.session.add(p)
    db.session.commit()
    _audit("proxy.create", f"label={label} kind={kind}")
    return jsonify({"ok": True, "proxy": _proxy_to_dict(p)})


@bp.delete("/api/proxies/<int:pid>")
@login_required
def proxy_delete(pid):
    p = db.session.get(Proxy, pid)
    if not p:
        return jsonify({"ok": False, "error": "not found"}), 404
    if p.is_active:
        return jsonify({"ok": False, "error": "cannot delete active proxy"}), 409
    db.session.delete(p)
    db.session.commit()
    _audit("proxy.delete", f"label={p.label}")
    return jsonify({"ok": True})


@bp.post("/api/proxies/<int:pid>/test")
@login_required
def proxy_test(pid):
    p = db.session.get(Proxy, pid)
    if not p:
        return jsonify({"ok": False, "error": "not found"}), 404
    url = vault_decrypt(p.url_encrypted)
    if not url:
        return jsonify({"ok": False, "error": "could not decrypt url"}), 500
    rc, out, err = run_script("proxy-test", [p.kind, "-"], stdin=url)
    try:
        result = json.loads(out)
    except Exception:
        result = {"ok": False, "error": "unparsable", "raw": (out + err)[:200]}
    p.last_test_ok = bool(result.get("ok"))
    p.last_test_at = datetime.utcnow()
    p.last_test_detail = (result.get("exit_ip") or result.get("error") or "")[:256]
    db.session.commit()
    return jsonify(result)


@bp.post("/api/proxies/<int:pid>/deactivate")
@login_required
def proxy_deactivate(pid):
    p = db.session.get(Proxy, pid)
    if not p:
        return jsonify({"ok": False, "error": "not found"}), 404
    p.is_active = False
    db.session.commit()
    # Best-effort: blank the active.conf so /modes proxy mode won't pick it up
    try:
        rc, out, err = run_script("proxy-write", ["socks5", "-"], stdin="")
    except Exception:
        pass
    _audit("proxy.deactivate", f"label={p.label}")
    return jsonify({"ok": True, "label": p.label})


@bp.post("/api/proxies/<int:pid>/activate")
@login_required
def proxy_activate(pid):
    p = db.session.get(Proxy, pid)
    if not p:
        return jsonify({"ok": False, "error": "not found"}), 404
    url = vault_decrypt(p.url_encrypted)
    if not url:
        return jsonify({"ok": False, "error": "could not decrypt url"}), 500
    # Persist to /etc/privacypi/proxy/active.conf via privileged script
    rc, out, err = run_script("proxy-write", [p.kind, "-"], stdin=url)
    if rc != 0:
        return jsonify({"ok": False, "error": err or out}), 500
    # Switch all is_active off, then mark this one active
    db.session.query(Proxy).update({Proxy.is_active: False})
    p.is_active = True
    db.session.commit()
    # Bring it up only if router mode is already 'proxy' — otherwise let
    # /modes do the routing. Just ensure active.conf is written.
    _audit("proxy.activate", f"label={p.label}")
    return jsonify({"ok": True, "label": p.label})


# ============================================================
# TLS bootstrap — Caddy frontend with internal CA. Removes the
# self-signed cert warning users see in browsers.
# ============================================================
@bp.get("/trust")
@login_required
def trust_page():
    return render_template("pages/trust.html")


@bp.get("/api/tls/status")
@login_required
def tls_status():
    rc, out, err = run_script("tls-bootstrap", ["status"])
    try:
        return jsonify(json.loads(out))
    except Exception:
        return jsonify({"ok": False, "error": err or out}), 500


@bp.post("/api/tls/<action>")
@login_required
def tls_action(action):
    if action not in ("setup", "teardown"):
        return jsonify({"ok": False, "error": "invalid action"}), 400
    rc, out, err = run_script("tls-bootstrap", [action], timeout=60)
    try:
        result = json.loads(out)
    except Exception:
        result = {"ok": rc == 0, "raw": (out + err)[:500]}
    _audit(f"tls.{action}", result.get("error") or "ok")
    return jsonify(result)


@bp.get("/pi-root.crt")
def pi_root_cert():
    """Public download of Caddy's internal-CA root cert.

    Unauthenticated on purpose: a user landing on the trust page over an
    untrusted TLS connection (the very problem we're fixing) needs the
    cert to make their browser trust us.

    The cert is short — it's the public root, not a private key. We
    re-read on every request in case Caddy regenerates.
    """
    path = "/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt"
    if not os.path.exists(path):
        return Response("Caddy CA not yet generated. Visit /system to enable it.",
                        status=503, mimetype="text/plain")
    with open(path, "rb") as f:
        cert = f.read()
    return Response(cert, mimetype="application/x-x509-ca-cert", headers={
        "Content-Disposition": 'attachment; filename="privacypi-root.crt"',
        "Cache-Control": "no-cache",
    })


# ============================================================
# Privacy hardening — Tier 1+2: DNS-trap, NTP-trap, AP-harden,
# captive portal handler. Each is a bash script with status/apply
# semantics; here we just wrap them as auth-protected JSON APIs.
# ============================================================
def _wrap(script_name, allowed_actions, audit_prefix, endpoint_prefix):
    """Helper: register GET status + POST <action> for a hardening script.

    `endpoint_prefix` makes the inner functions uniquely named so Flask's
    endpoint registry doesn't collide across multiple _wrap calls.
    """
    def status_handler():
        rc, out, err = run_script(script_name, ["status"])
        try:
            return jsonify(json.loads(out))
        except Exception:
            return jsonify({"ok": False, "raw": (out + err)[:300]}), 500

    def action_handler(action):
        if action not in allowed_actions:
            return jsonify({"ok": False, "error": "invalid action"}), 400
        rc, out, err = run_script(script_name, [action], timeout=120)
        try:
            result = json.loads(out)
        except Exception:
            result = {"ok": rc == 0, "raw": (out + err)[:500]}
        _audit(f"{audit_prefix}.{action}", json.dumps(result)[:200])
        return jsonify(result)

    status_handler.__name__ = f"{endpoint_prefix}_status"
    action_handler.__name__ = f"{endpoint_prefix}_action"
    return status_handler, action_handler


_dns_status, _dns_action = _wrap("dns-trap", ("enable", "disable", "status"), "dnstrap", "dnstrap")
bp.add_url_rule("/api/dns-trap", view_func=login_required(_dns_status), methods=["GET"])
bp.add_url_rule("/api/dns-trap/<action>", view_func=login_required(_dns_action), methods=["POST"])

_ntp_status, _ntp_action = _wrap("ntp-trap", ("enable", "disable", "status"), "ntptrap", "ntptrap")
bp.add_url_rule("/api/ntp-trap", view_func=login_required(_ntp_status), methods=["GET"])
bp.add_url_rule("/api/ntp-trap/<action>", view_func=login_required(_ntp_action), methods=["POST"])

_ap_status, _ap_action = _wrap("ap-harden", ("apply", "probe", "status"), "apharden", "apharden")
bp.add_url_rule("/api/ap-harden", view_func=login_required(_ap_status), methods=["GET"])
bp.add_url_rule("/api/ap-harden/<action>", view_func=login_required(_ap_action), methods=["POST"])

_cap_status, _cap_action = _wrap("captive-portal", ("check", "bypass", "restore", "status"), "captive", "captive")
bp.add_url_rule("/api/captive-portal", view_func=login_required(_cap_status), methods=["GET"])
bp.add_url_rule("/api/captive-portal/<action>", view_func=login_required(_cap_action), methods=["POST"])


@bp.get("/privacy")
@login_required
def privacy_page():
    return render_template("pages/privacy.html")


@bp.get("/advanced")
@login_required
def advanced_page():
    return render_template("pages/advanced.html")


@bp.get("/api/insights/dashboard")
@login_required
def insights_dashboard():
    from .services.insights import get_dashboard_insights
    return jsonify(get_dashboard_insights())


@bp.get("/api/insights/digest")
@login_required
def insights_digest():
    from .services.insights import get_24h_summary
    return jsonify(get_24h_summary())


# Alert rules CRUD
ALERT_RULE_KINDS = ("audit.action", "dns.host", "dns.client_blocked", "threshold.fails")


@bp.get("/api/alert-rules")
@login_required
def alert_rules_list():
    rows = db.session.query(AlertRule).order_by(AlertRule.created_at.desc()).all()
    return jsonify({"rules": [{
        "id": r.id, "label": r.label, "kind": r.kind, "pattern": r.pattern,
        "threshold": r.threshold, "window_minutes": r.window_minutes,
        "cooldown_minutes": r.cooldown_minutes, "enabled": r.enabled,
        "last_fired_at": r.last_fired_at.isoformat() if r.last_fired_at else None,
    } for r in rows]})


@bp.post("/api/alert-rules")
@login_required
def alert_rules_create():
    label = (request.form.get("label") or "").strip()[:64]
    kind = (request.form.get("kind") or "").strip()
    pattern = (request.form.get("pattern") or "").strip()[:255]
    if not label or kind not in ALERT_RULE_KINDS or not pattern:
        return jsonify({"ok": False, "error": "label/kind/pattern required"}), 400
    try:
        threshold = max(1, int(request.form.get("threshold", 1)))
        window_m = max(1, int(request.form.get("window_minutes", 60)))
        cooldown_m = max(0, int(request.form.get("cooldown_minutes", 60)))
    except ValueError:
        return jsonify({"ok": False, "error": "numbers required"}), 400
    r = AlertRule(label=label, kind=kind, pattern=pattern,
                  threshold=threshold, window_minutes=window_m,
                  cooldown_minutes=cooldown_m)
    db.session.add(r); db.session.commit()
    _audit("alert_rule.create", f"{label} ({kind})")
    return jsonify({"ok": True, "id": r.id})


@bp.delete("/api/alert-rules/<int:rid>")
@login_required
def alert_rules_delete(rid):
    r = db.session.get(AlertRule, rid)
    if not r:
        return jsonify({"ok": False, "error": "not found"}), 404
    label = r.label
    db.session.delete(r); db.session.commit()
    _audit("alert_rule.delete", label)
    return jsonify({"ok": True})


@bp.post("/api/alert-rules/<int:rid>/toggle")
@login_required
def alert_rules_toggle(rid):
    r = db.session.get(AlertRule, rid)
    if not r:
        return jsonify({"ok": False, "error": "not found"}), 404
    r.enabled = not r.enabled
    db.session.commit()
    _audit("alert_rule.toggle", f"{r.label}={r.enabled}")
    return jsonify({"ok": True, "enabled": r.enabled})


# ============================================================
# Tier B — onion-ssh, wstunnel, tor circuits, domain-routes,
# webauthn, lockout management.
# ============================================================
_oss_status, _oss_action = _wrap("onion-ssh", ("enable", "disable", "status"), "onion_ssh", "onionssh")
bp.add_url_rule("/api/onion-ssh", view_func=login_required(_oss_status), methods=["GET"])
bp.add_url_rule("/api/onion-ssh/<action>", view_func=login_required(_oss_action), methods=["POST"])

_wst_status, _wst_action = _wrap("wstunnel", ("enable", "disable", "install", "status"), "wstunnel", "wstunnel")
bp.add_url_rule("/api/wstunnel", view_func=login_required(_wst_status), methods=["GET"])
bp.add_url_rule("/api/wstunnel/<action>", view_func=login_required(_wst_action), methods=["POST"])


@bp.get("/api/tor/circuits")
@login_required
def tor_circuits():
    rc, out, err = run_script("tor-circuits", [])
    try:
        return jsonify(json.loads(out))
    except Exception:
        return jsonify({"circuits": [], "error": err or out}), 200


# Domain-route CRUD
@bp.get("/api/domain-routes")
@login_required
def domain_routes_list():
    rows = db.session.query(DomainRoute).order_by(DomainRoute.created_at.desc()).all()
    return jsonify({"routes": [{
        "id": r.id, "domain": r.domain, "mode": r.mode,
        "enabled": r.enabled,
    } for r in rows]})


@bp.post("/api/domain-routes")
@login_required
def domain_routes_create():
    domain = (request.form.get("domain") or "").strip().lower()
    mode = (request.form.get("mode") or "").strip()
    if not domain or mode not in ("direct", "vpn", "tor", "proxy", "killswitch"):
        return jsonify({"ok": False, "error": "domain + valid mode required"}), 400
    if any(c in domain for c in " ;|&$`\n"):
        return jsonify({"ok": False, "error": "invalid domain"}), 400
    if db.session.query(DomainRoute).filter_by(domain=domain).first():
        return jsonify({"ok": False, "error": "domain already routed"}), 409
    r = DomainRoute(domain=domain, mode=mode)
    db.session.add(r); db.session.commit()
    _audit("domain_route.create", f"{domain}->{mode}")
    return jsonify({"ok": True, "id": r.id})


@bp.delete("/api/domain-routes/<int:rid>")
@login_required
def domain_routes_delete(rid):
    r = db.session.get(DomainRoute, rid)
    if not r:
        return jsonify({"ok": False, "error": "not found"}), 404
    domain = r.domain
    db.session.delete(r); db.session.commit()
    _audit("domain_route.delete", domain)
    return jsonify({"ok": True})


# Login lockout — admin can clear bans
@bp.get("/api/lockout")
@login_required
def lockout_list():
    from datetime import datetime, timedelta
    cutoff = datetime.utcnow() - timedelta(minutes=15)
    from sqlalchemy import func
    rows = db.session.query(
        LoginAttempt.ip,
        func.count(LoginAttempt.id).label("fails"),
        func.max(LoginAttempt.timestamp).label("last"),
    ).filter(LoginAttempt.timestamp >= cutoff).group_by(LoginAttempt.ip).all()
    return jsonify({"locked": [
        {"ip": r.ip, "fails": r.fails, "last": r.last.isoformat()}
        for r in rows if r.fails >= 5
    ], "all_recent": [
        {"ip": r.ip, "fails": r.fails, "last": r.last.isoformat()}
        for r in rows
    ]})


@bp.post("/api/lockout/clear")
@login_required
def lockout_clear():
    ip = (request.form.get("ip") or "").strip()
    if not ip:
        db.session.query(LoginAttempt).delete()
    else:
        db.session.query(LoginAttempt).filter(LoginAttempt.ip == ip).delete()
    db.session.commit()
    _audit("lockout.clear", ip or "(all)")
    return jsonify({"ok": True})


# WebAuthn — register & remove credentials. Login flow uses TOTP today;
# WebAuthn is an additional 2FA option, registered while logged in.
_WA_CHALLENGE_KEY = "_wa_challenge"


@bp.get("/api/webauthn/credentials")
@login_required
def webauthn_creds_list():
    creds = db.session.query(WebAuthnCredential).filter_by(user_id=current_user.id).all()
    return jsonify({"credentials": [{
        "id": c.id, "label": c.label, "created_at": c.created_at.isoformat(),
        "last_used_at": c.last_used_at.isoformat() if c.last_used_at else None,
    } for c in creds]})


@bp.post("/api/webauthn/register/begin")
@login_required
def webauthn_register_begin():
    from .services.webauthn_svc import begin_register
    creds = db.session.query(WebAuthnCredential).filter_by(user_id=current_user.id).all()
    options, challenge = begin_register(current_user, request, creds)
    from flask import session
    session[_WA_CHALLENGE_KEY] = challenge
    return jsonify({"options": options})


@bp.post("/api/webauthn/register/finish")
@login_required
def webauthn_register_finish():
    from flask import session
    from .services.webauthn_svc import finish_register
    data = request.get_json(force=True, silent=True) or {}
    challenge = session.pop(_WA_CHALLENGE_KEY, "")
    if not challenge:
        return jsonify({"ok": False, "error": "no challenge in session"}), 400
    label = (data.get("label") or "hardware key").strip()[:64]
    raw = data.get("response")
    try:
        result = finish_register(current_user, request, raw, challenge, label)
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 400
    cred = WebAuthnCredential(
        user_id=current_user.id,
        credential_id=result["credential_id"],
        public_key=result["public_key"],
        sign_count=result["sign_count"],
        label=result["label"],
    )
    db.session.add(cred); db.session.commit()
    _audit("webauthn.register", label)
    return jsonify({"ok": True, "id": cred.id})


@bp.delete("/api/webauthn/credentials/<int:cid>")
@login_required
def webauthn_cred_delete(cid):
    c = db.session.get(WebAuthnCredential, cid)
    if not c or c.user_id != current_user.id:
        return jsonify({"ok": False, "error": "not found"}), 404
    label = c.label
    db.session.delete(c); db.session.commit()
    _audit("webauthn.delete", label)
    return jsonify({"ok": True})


# ============================================================
# Onion service for admin UI (defense-in-depth — admin reachable
# without any inbound port on the WAN).
# ============================================================
@bp.post("/api/onion-admin/<action>")
@login_required
def onion_admin(action):
    if action not in ("enable", "disable", "status"):
        return jsonify({"ok": False, "error": "invalid action"}), 400
    rc, out, err = run_script("onion-admin", [action])
    try:
        result = json.loads(out)
    except Exception:
        result = {"ok": False, "error": err or out}
    if action != "status":
        _audit(f"onion.{action}", result.get("onion") or result.get("error") or "")
    return jsonify(result)


@bp.get("/api/onion-admin")
@login_required
def onion_admin_status():
    rc, out, err = run_script("onion-admin", ["status"])
    try:
        return jsonify(json.loads(out))
    except Exception:
        return jsonify({"ok": False, "error": err or out}), 500


# ============================================================
# DoH server (Caddy on 10.20.0.1:443) — phones over WG can use
# https://10.20.0.1/dns-query as encrypted DNS.
# ============================================================
@bp.post("/api/doh/<action>")
@login_required
def doh_action(action):
    if action not in ("enable", "disable", "status"):
        return jsonify({"ok": False, "error": "invalid action"}), 400
    rc, out, err = run_script("doh-server", [action])
    try:
        result = json.loads(out)
    except Exception:
        result = {"ok": rc == 0, "raw": (out + err)[:300]}
    if action != "status":
        _audit(f"doh.{action}", result.get("status") or result.get("error") or "")
    return jsonify(result)


@bp.get("/api/doh")
@login_required
def doh_status():
    rc, out, err = run_script("doh-server", ["status"])
    try:
        return jsonify(json.loads(out))
    except Exception:
        return jsonify({"ok": False, "error": err or out}), 500


# ============================================================
# USB-tether WAN failover (eth0 ↔ usb0).
# ============================================================
@bp.get("/api/tether-wan")
@login_required
def tether_status():
    rc, out, err = run_script("tether-wan", ["status"])
    try:
        return jsonify(json.loads(out))
    except Exception:
        return jsonify({"ok": False, "error": err or out}), 500


@bp.post("/api/tether-wan/switch")
@login_required
def tether_switch():
    target = (request.form.get("target") or "").strip()
    if not target or any(c in target for c in " ;|&$`\n"):
        return jsonify({"ok": False, "error": "invalid target"}), 400
    rc, out, err = run_script("tether-wan", ["switch", target])
    try:
        result = json.loads(out)
    except Exception:
        result = {"ok": rc == 0, "raw": (out + err)[:300]}
    _audit("tether.switch", target)
    return jsonify(result)


# ====== VPN connect / disconnect ======
VPN_PROVIDERS = ("nordvpn", "expressvpn", "mullvad", "protonvpn", "ivpn",
                 "surfshark", "airvpn", "custom-ovpn", "custom-wg")

def _remember_vpn(provider):
    row = db.session.get(Setting, "vpn_last_provider")
    if row is None:
        db.session.add(Setting(key="vpn_last_provider", value=provider))
    else:
        row.value = provider
    db.session.commit()

@bp.get("/api/vpn/state")
@login_required
def vpn_state():
    rc, out, err = run_script("vpn-connect", ["status"])
    return jsonify(_script_json(out, err))

@bp.get("/api/vpn/nord/countries")
@login_required
def vpn_nord_countries():
    rc, out, err = run_script("vpn-connect", ["nord-countries"], timeout=25)
    return jsonify(_script_json(out, err))

@bp.post("/api/vpn/<provider>/connect")
@login_required
def vpn_connect(provider):
    if provider not in VPN_PROVIDERS:
        abort(400)
    country = (request.form.get("country") or "").strip()
    if provider == "nordvpn" and request.form.get("auto", "1") == "1":
        if country and not country.isdigit():
            return jsonify({"ok": False, "error": "bad country"}), 400
        rc, out, err = run_script("vpn-connect", ["nord"] + ([country] if country else []), timeout=90)
    else:
        rc, out, err = run_script("vpn-connect", ["up", provider], timeout=80)
    res = _script_json(out, err)
    if res.get("ok"):
        _remember_vpn(provider)
    _audit(f"vpn.connect.{provider}", "ok" if res.get("ok") else str(res.get("error"))[:200])
    return jsonify(res)

@bp.post("/api/vpn/disconnect")
@login_required
def vpn_disconnect():
    rc, out, err = run_script("vpn-connect", ["down"], timeout=40)
    _audit("vpn.disconnect")
    return jsonify(_script_json(out, err))


# ====== The PrivacyPi WiFi network (name / password / country) ======
import re as _re_ap

@bp.get("/api/ap")
@login_required
def ap_status():
    rc, out, err = run_script("ap-config", ["status"])
    return jsonify(_script_json(out, err))

@bp.post("/api/ap")
@login_required
def ap_set():
    ssid = (request.form.get("ssid") or "").strip()
    psk = request.form.get("psk") or ""
    if not _re_ap.match(r"^[A-Za-z0-9 _.\-]{1,32}$", ssid):
        return jsonify({"ok": False, "error": "WiFi name: 1-32 characters — letters, numbers, spaces, dot, dash or underscore"}), 400
    if not (8 <= len(psk) <= 63) or not all(0x20 <= ord(c) < 0x7f for c in psk):
        return jsonify({"ok": False, "error": "WiFi password must be 8-63 characters"}), 400
    # --defer: the WiFi restarts a few seconds after this response is sent.
    rc, out, err = run_script("ap-config", ["set", ssid, "-", "--defer"], stdin=psk)
    _audit("ap.set", ssid)
    return jsonify(_script_json(out, err))


# ====== Optional two-step login (authenticator app) ======
@bp.get("/api/2fa")
@login_required
def twofa_status():
    return jsonify({"ok": True, "enabled": bool(current_user.totp_enabled)})

@bp.post("/api/2fa/begin")
@login_required
def twofa_begin():
    import pyotp, qrcode
    from io import BytesIO
    from flask import session
    secret = pyotp.random_base32()
    session["pending_totp"] = secret
    uri = pyotp.TOTP(secret).provisioning_uri(name=current_user.username, issuer_name="PrivacyPi")
    buf = BytesIO()
    qrcode.make(uri).save(buf, format="PNG")
    return jsonify({"ok": True, "secret": secret, "qr": b64encode(buf.getvalue()).decode()})

@bp.post("/api/2fa/enable")
@login_required
def twofa_enable():
    import pyotp
    from flask import session
    secret = session.get("pending_totp")
    code = (request.form.get("code") or "").strip()
    if not secret or not pyotp.TOTP(secret).verify(code, valid_window=1):
        return jsonify({"ok": False, "error": "That code is not right — check the app and the Pi's clock."}), 400
    current_user.totp_secret = secret
    current_user.totp_enabled = True
    db.session.commit()
    session.pop("pending_totp", None)
    _audit("2fa.enable")
    return jsonify({"ok": True})

@bp.post("/api/2fa/disable")
@login_required
def twofa_disable():
    if not bcrypt.checkpw((request.form.get("password") or "").encode(), current_user.password_hash.encode()):
        return jsonify({"ok": False, "error": "password wrong"}), 400
    current_user.totp_enabled = False
    current_user.totp_secret = None
    db.session.commit()
    _audit("2fa.disable")
    return jsonify({"ok": True})


# ====== Extras (optional networks installed on demand) ======
EXTRAS = {
    "i2p": {
        "name": "I2P",
        "icon": "🕸️",
        "summary": "A separate anonymous network with its own websites (addresses ending in .i2p).",
        "howto": "After installing: in your browser's network settings, set the HTTP proxy to {gw}, port 4444. Then .i2p addresses open.",
    },
    "yggdrasil": {
        "name": "Yggdrasil",
        "icon": "🌳",
        "summary": "An experimental encrypted network between volunteers' computers. Only useful if you already use it.",
        "howto": "For people who already use Yggdrasil. It needs manual setup on the device afterwards.",
    },
    "lokinet": {
        "name": "Lokinet",
        "icon": "🔗",
        "summary": "Another anonymous network with its own websites (addresses ending in .loki). Experimental.",
        "howto": "Experimental: installation may fail on this system. If it does, nothing else is affected.",
    },
}

@bp.get("/extras")
@login_required
def extras_page():
    return render_template("pages/extras.html", extras=EXTRAS)

@bp.get("/api/extras")
@login_required
def extras_status():
    rc, out, err = run_script("extras", ["status"])
    return jsonify(_script_json(out, err))

@bp.post("/api/extras/<name>/<action>")
@login_required
def extras_action(name, action):
    if name not in EXTRAS or action not in ("install", "remove"):
        abort(400)
    rc, out, err = run_script("extras", [action, name])
    _audit(f"extras.{action}", name)
    return jsonify(_script_json(out, err))

@bp.get("/api/extras/<name>/log")
@login_required
def extras_log(name):
    if name not in EXTRAS:
        abort(400)
    rc, out, err = run_script("extras", ["log", name])
    return jsonify({"ok": True, "log": out[-3000:]})
