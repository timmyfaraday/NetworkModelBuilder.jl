"""
SessionStart hook: inject STATE.md and remember where the session started.

Records the current HEAD in ``.git/agent-session/<session>.json`` so the Stop hook can tell what
this session changed, then adds the state file to the conversation as context.
"""

from __future__ import annotations

import sys

sys.dont_write_bytecode = True  # keep __pycache__ out of the working tree

import datetime as dt  # noqa: E402
import json  # noqa: E402
from typing import Any  # noqa: E402

from _common import ROOT, SESSION_DIR, config, emit, git, run, session_file  # noqa: E402


def main(event: dict[str, Any]) -> None:
    cfg = config()
    SESSION_DIR.mkdir(parents=True, exist_ok=True)
    head = git("rev-parse", "HEAD").strip()
    record = {
        "start_sha": head,
        "started": dt.datetime.now().isoformat(timespec="seconds"),
        "nagged": False,
    }
    text = json.dumps(record)
    session_file(event).write_text(text, encoding="utf-8")
    (SESSION_DIR / "latest.json").write_text(text, encoding="utf-8")

    state_path = ROOT / cfg["state_file"]
    state = state_path.read_text(encoding="utf-8") if state_path.exists() else "(STATE.md missing)"
    emit(
        {
            "hookSpecificOutput": {
                "hookEventName": "SessionStart",
                "additionalContext": f"{cfg['session_context_header']}\n\n{state}",
            }
        }
    )


if __name__ == "__main__":
    run(main, "session_start")
