"""
Shared helpers for the agent hooks.

Hooks must never break the agent's work: every entry point catches all errors, logs them to
``.git/agent-hooks.log`` and exits 0 with no output (fail open). Standard library only, so the
hooks run with any Python 3.9+ on Windows, macOS and Linux.

Paths and budgets are read from ``hook_config.json`` next to this file, so another repository can
reuse the scripts by editing that file only.
"""

from __future__ import annotations

import datetime as _dt
import json
import subprocess
import sys
import traceback
from collections.abc import Callable
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent


def repo_root() -> Path:
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=5,
            check=True,
        )
        return Path(out.stdout.strip())
    except Exception:
        return HERE.parents[2]


ROOT = repo_root()
GIT_DIR = ROOT / ".git"
SESSION_DIR = GIT_DIR / "agent-session"
LOG_FILE = GIT_DIR / "agent-hooks.log"


def config() -> dict[str, Any]:
    return json.loads((HERE / "hook_config.json").read_text(encoding="utf-8"))


def read_event() -> dict[str, Any]:
    raw = sys.stdin.read()
    return json.loads(raw) if raw.strip() else {}


def log(kind: str, message: str) -> None:
    try:
        stamp = _dt.datetime.now().isoformat(timespec="seconds")
        with LOG_FILE.open("a", encoding="utf-8") as fh:
            fh.write(f"{stamp}\t{kind}\t{message}\n")
    except Exception:
        pass


def git(*args: str) -> str:
    out = subprocess.run(["git", *args], capture_output=True, text=True, timeout=15, cwd=ROOT, check=True)
    return out.stdout


def session_file(event: dict[str, Any]) -> Path:
    sid = str(event.get("session_id") or "latest")
    safe = "".join(c for c in sid if c.isalnum() or c in "-_") or "latest"
    return SESSION_DIR / f"{safe}.json"


def emit(payload: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload))


def run(main: Callable[[dict[str, Any]], None], name: str) -> None:
    try:
        main(read_event())
    except Exception:
        log(f"{name}:error", traceback.format_exc().replace("\n", " | "))
    sys.exit(0)
