"""
Run one hook script of the sma-coding-second-brain engine from this repository's hooks.

The repository commits this launcher and ``agent-hooks.json``; the scripts live in the plugin.
Everything fails open: a missing engine or any error here exits 0 and never blocks the agent.
A missing engine is reported once per session through the SessionStart context.

The engine runs with the repo's ``.venv`` interpreter; without a ``.venv`` it falls back to the
interpreter that started this launcher and SessionStart tells the user the venv is missing.

Usage: ``python .github/hooks/launch.py <session_start|guard|stop_check>``
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

PLUGIN = "sma-coding-second-brain"
CONFIG = Path(".github") / "hooks" / "hook_config.json"
VENDORED = Path(".github") / "engine"
MAX_DEPTH = 5


def is_engine(path: Path) -> bool:
    return (path / "engine" / "hooks" / "_common.py").is_file()


def find_engine(repo: Path) -> Path | None:
    env = os.environ.get("SMA_SECOND_BRAIN_HOME")
    for candidate in (Path(env) if env else None, repo / VENDORED):
        if candidate and is_engine(candidate):
            return candidate
    base = Path.home() / ".vscode" / "agent-plugins"
    if not base.is_dir():
        return None
    for dirpath, dirnames, _ in os.walk(base):
        depth = len(Path(dirpath).relative_to(base).parts)
        if PLUGIN in dirnames and is_engine(Path(dirpath) / PLUGIN):
            return Path(dirpath) / PLUGIN
        dirnames[:] = [d for d in dirnames if not d.startswith(".")] if depth < MAX_DEPTH else []
    return None


def engine_version(engine: Path) -> str:
    try:
        manifest = json.loads((engine / ".claude-plugin" / "plugin.json").read_text(encoding="utf-8"))
        return str(manifest.get("version", ""))
    except Exception:
        return ""


def pinned_version(repo: Path) -> str:
    try:
        return str(json.loads((repo / CONFIG).read_text(encoding="utf-8")).get("engine_version", ""))
    except Exception:
        return ""


def session_note(text: str) -> str:
    payload = {"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": text}}
    return json.dumps(payload)


def venv_python(repo: Path) -> Path | None:
    for rel in (Path(".venv") / "Scripts" / "python.exe", Path(".venv") / "bin" / "python"):
        if (repo / rel).is_file():
            return repo / rel
    return None


def main(name: str) -> None:
    repo = Path.cwd()
    stdin = sys.stdin.read()
    engine = find_engine(repo)
    if engine is None:
        if name == "session_start":
            sys.stdout.write(
                session_note(
                    f"Agent memory is NOT active: the '{PLUGIN}' plugin was not found. Install it from the team's "
                    "Azure DevOps repository (see .github/AGENT-SETUP.md), then restart the chat. "
                    "Until then read .github/context/STATE.md yourself."
                )
            )
        return

    python = venv_python(repo)
    result = subprocess.run(
        [str(python or sys.executable), str(engine / "engine" / "hooks" / f"{name}.py")],
        input=stdin,
        capture_output=True,
        text=True,
        encoding="utf-8",
        cwd=repo,
        timeout=30,
    )
    out = result.stdout
    notes = []
    if python is None:
        notes.append("No .venv found at the repo root: tell the user to create it (see the project's setup steps).")
    installed, pinned = engine_version(engine), pinned_version(repo)
    if installed and pinned and installed != pinned:
        notes.append(f"This repo pins {PLUGIN} {pinned} but {installed} is installed. Update the plugin or the engine_version in .github/hooks/hook_config.json.")
    if name == "session_start" and notes:
        data = json.loads(out) if out.strip() else {"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": ""}}
        data["hookSpecificOutput"]["additionalContext"] += "\n\nNote: " + " ".join(notes)
        out = json.dumps(data)
    sys.stdout.write(out)


if __name__ == "__main__":
    try:
        sys.stdin.reconfigure(encoding="utf-8")
        main(sys.argv[1])
    except Exception:
        pass
    sys.exit(0)
