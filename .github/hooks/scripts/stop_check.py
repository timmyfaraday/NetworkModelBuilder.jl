"""
Stop hook: ask for a wrap-up when this session changed code but not the state file.

Blocks the stop at most once per session (and never when ``stop_hook_active`` is set), so a
forgotten wrap-up costs one extra turn, not a loop. Also reports files over their line budget.
"""

from __future__ import annotations

import sys

sys.dont_write_bytecode = True  # keep __pycache__ out of the working tree

import json  # noqa: E402
from typing import Any  # noqa: E402

from _common import ROOT, SESSION_DIR, config, emit, git, log, run, session_file  # noqa: E402


def changed_since(sha: str) -> set[str]:
    files = set(git("diff", "--name-only", sha).split())
    files |= set(git("ls-files", "--others", "--exclude-standard").split())
    return {f.replace("\\", "/") for f in files}


def over_budget(budgets: dict[str, int]) -> list[str]:
    issues = []
    for pattern, limit in budgets.items():
        for path in sorted(ROOT.glob(pattern)):
            n = len(path.read_text(encoding="utf-8").splitlines())
            if n > limit:
                issues.append(f"{path.relative_to(ROOT).as_posix()} has {n} lines (budget {limit})")
    return issues


def main(event: dict[str, Any]) -> None:
    if event.get("stop_hook_active"):
        return
    cfg = config()
    path = session_file(event)
    if not path.exists():
        path = SESSION_DIR / "latest.json"
    if not path.exists():
        return
    record = json.loads(path.read_text(encoding="utf-8"))
    if record.get("nagged"):
        return

    changed = changed_since(record["start_sha"])
    skip = tuple(cfg["memory_prefixes"]) + tuple(cfg["ignored_prefixes"])
    code_changed = sorted(f for f in changed if not f.startswith(skip) and "__pycache__" not in f)
    state_changed = cfg["state_file"] in changed
    issues = over_budget(cfg["budgets"])

    reasons = []
    if code_changed and not state_changed:
        reasons.append(
            f"This session changed {len(code_changed)} file(s) (e.g. {code_changed[0]}) but not "
            f"{cfg['state_file']}. Run the wrap-up skill before stopping; if the task isn't "
            "finished, record in STATE.md where it stopped and the next step."
        )
    if issues:
        reasons.append("Over budget: " + "; ".join(issues) + ". Condense or propose a split.")
    if not reasons:
        return

    record["nagged"] = True
    path.write_text(json.dumps(record), encoding="utf-8")
    reason = " ".join(reasons) + " (This check runs once per session.)"
    log("stop:block", reason[:200])
    emit(
        {
            "decision": "block",
            "reason": reason,
            "hookSpecificOutput": {"hookEventName": "Stop", "decision": "block", "reason": reason},
        }
    )


if __name__ == "__main__":
    run(main, "stop_check")
