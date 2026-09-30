"""
PreToolUse hook: two guards.

1. A git commit whose command carries an AI attribution trailer is denied.
2. An edit to a setup file (instructions, skills, hooks, VS Code settings) asks the user first.

Tool names differ between harnesses and versions, so the guard looks at what the tool call
contains (paths, commands) rather than trusting a fixed list of tool names.
"""

from __future__ import annotations

import sys

sys.dont_write_bytecode = True  # keep __pycache__ out of the working tree

import re  # noqa: E402
from collections.abc import Iterator  # noqa: E402
from typing import Any  # noqa: E402

from _common import config, emit, log, run  # noqa: E402

READ_WORDS = (
    "read",
    "search",
    "find",
    "list",
    "grep",
    "fetch",
    "view",
    "get",
    "usages",
    "problems",
    "codebase",
    "semantic",
    "glob",
    "open",
)
WRITE_WORDS = (
    "edit",
    "write",
    "create",
    "replace",
    "insert",
    "apply",
    "delete",
    "rename",
    "move",
    "patch",
    "terminal",
    "run",
    "exec",
    "shell",
    "command",
    "notebook",
)
SHELL_WRITES = re.compile(
    r"(set-content|add-content|out-file|new-item|remove-item|move-item|copy-item|rename-item"
    r"|\bdel\b|\brm\b|\bmv\b|\bcp\b|\bcopy\b|\bmove\b|git\s+(mv|rm|checkout|restore|apply)"
    r"|sed\s+-i|>>?|\.write_text|open\([^)]*['\"]w)",
    re.IGNORECASE,
)


def strings(value: Any) -> Iterator[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for v in value.values():
            yield from strings(v)
    elif isinstance(value, (list, tuple)):
        for v in value:
            yield from strings(v)


def commands(tool_input: Any) -> list[str]:
    if isinstance(tool_input, dict):
        keys = ("command", "cmd", "script")
        return [v for k, v in tool_input.items() if k.lower() in keys and isinstance(v, str)]
    return []


def main(event: dict[str, Any]) -> None:
    cfg = config()
    tool = str(event.get("tool_name", "")).lower()
    tool_input = event.get("tool_input", {})
    texts = [s.replace("\\", "/") for s in strings(tool_input)]
    cmds = commands(tool_input)

    # 1. AI attribution in a commit.
    blob = "\n".join(texts)
    if re.search(r"git\s+commit", blob, re.IGNORECASE) or "commit" in tool:
        for pattern in cfg["forbidden_commit_patterns"]:
            if re.search(pattern, blob, re.IGNORECASE):
                log("guard:deny-commit", f"{tool}: {pattern}")
                emit(
                    {
                        "hookSpecificOutput": {
                            "hookEventName": "PreToolUse",
                            "permissionDecision": "deny",
                            "permissionDecisionReason": ("Commit messages carry no AI attribution (no Co-authored-by for a tool, no 'Generated with'). Remove it and commit again."),
                        }
                    }
                )
                return

    # 2. Edits to setup files.
    setup = [p.lower() for p in cfg["setup_paths"]]
    touched = [t for t in texts if any(p in t.lower() for p in setup)]
    if not touched:
        return
    is_read_tool = any(w in tool for w in READ_WORDS) and not any(w in tool for w in WRITE_WORDS)
    if is_read_tool:
        return
    if cmds:
        writes = any(SHELL_WRITES.search(c) and any(p in c.replace("\\", "/").lower() for p in setup) for c in cmds)
        if not writes:
            return
    log("guard:ask-setup", f"{tool}: {touched[0][:120]}")
    emit(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "ask",
                "permissionDecisionReason": (
                    f"This changes the agent setup ({touched[0][:80]}). Setup changes need approval from {cfg['setup_owner']}; see .github/instructions/setup-files.instructions.md."
                ),
            }
        }
    )


if __name__ == "__main__":
    run(main, "guard")
