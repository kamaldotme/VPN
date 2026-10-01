import json, time
from flask import Blueprint, Response, stream_with_context
from flask_login import login_required
from .services.runner import run_script

bp = Blueprint("sse", __name__)

def _stream():
    while True:
        rc, out, err = run_script("vpn-status")
        try:
            data = json.loads(out) if rc == 0 else {"error": err}
        except Exception:
            data = {"raw": out}
        yield f"data: {json.dumps(data)}\n\n"
        time.sleep(5)

@bp.get("/sse/status")
@login_required
def status_stream():
    return Response(stream_with_context(_stream()), mimetype="text/event-stream")
