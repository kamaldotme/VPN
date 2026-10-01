"""Safe wrapper around sudo subprocess for privileged operations."""
import subprocess
from typing import Sequence
from flask import current_app

class RunnerError(Exception):
    pass

def _validated_cmd(name: str, args: Sequence[str]) -> list[str]:
    scripts = current_app.config["ALLOWED_SCRIPTS"]
    if name not in scripts:
        raise RunnerError(f"script not allowed: {name}")
    path = scripts[name]
    safe = []
    for a in args:
        if not isinstance(a, str):
            raise RunnerError("non-string arg")
        # passwords/file-content can include any printable; allow more chars
        if not all(0x20 <= ord(c) < 0x7f for c in a) or '\n' in a:
            raise RunnerError(f"unsafe arg: {a!r}")
        safe.append(a)
    return ["sudo", "-n", path, *safe]

def run_script(name, args=(), stdin: str | None = None, timeout: int = 30):
    """Text-mode invocation. Returns (rc, stdout, stderr).

    `stdin` lets callers pass secrets that must not appear in argv (and so
    not in /proc/<pid>/cmdline or auditd). The script must read stdin when
    its corresponding arg is "-".
    """
    cmd = _validated_cmd(name, args)
    # Ensure stdin is newline-terminated so bash `read -r` succeeds under set -e.
    if stdin is not None and not stdin.endswith("\n"):
        stdin = stdin + "\n"
    try:
        p = subprocess.run(cmd, input=stdin, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"

def run_script_bin(name, args=()):
    """Binary-mode invocation. Returns (rc, stdout_bytes, stderr_text)."""
    cmd = _validated_cmd(name, args)
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=60)
        return p.returncode, p.stdout, p.stderr.decode("utf-8", errors="replace")
    except subprocess.TimeoutExpired:
        return 124, b"", "timeout"
