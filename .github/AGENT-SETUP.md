# Working with the agent on NetworkModelBuilder.jl

For people, not for the agent. How the VS Code agent setup in this repo works and how to use it
well. Owner: Tom Van Acker.

## What's here

| Path | What it is | Who edits it |
| --- | --- | --- |
| `copilot-instructions.md` | Always-loaded rules (~50 lines) | Tom approves changes |
| `instructions/*.instructions.md` | Rules that load when the agent touches matching files | Tom approves |
| `skills/*/SKILL.md` | Procedures, invoked with `/name` or picked up automatically | Tom approves |
| `hooks/` | Python scripts VS Code runs at session start, before tool calls and at stop | Tom approves |
| `context/` | The project's memory: state, decisions, backlog, lessons | Anyone, via their work |

The agent keeps `context/` up to date as part of each task.

## Daily use

- **One chat per task.** Old history costs tokens and dilutes context. The next chat picks up from
  `STATE.md`, which a hook injects automatically.
- **Finish with `/wrap-up`.** If you forget, the Stop hook asks the agent once to do it.
- **Decisions**: when you decide something, say so plainly ("let's go with X"); the agent records
  it with `/record-decision` and cites the id in the commit.
- **Useful skills**: `/new-spec` (writes into `plans/`), `/pr-description`, `/setup-review`,
  `/probe-environment`, `/new-run-prompt` and `/review-run-report` (for a task handed to an
  unattended/overnight agent run).
- **Before asking the agent to re-explain something**, check `context/INDEX.md`; point it at the
  right file instead.

## Keeping costs down

- `.vscode/settings.json` keeps `docs/build/`, `runs/`, `scratch/` and the Manifests out of search
  results.
- Big test-run output goes to `scratch/` (gitignored), not into the chat.

## How the setup improves

The agent logs friction (`context/setup-feedback.md`) at every wrap-up. When an issue repeats, it
proposes a change with evidence; nothing in the setup changes without Tom's OK (a hook enforces
the prompt). Approved changes are logged in `context/setup-changelog.md`. Run `/setup-review`
occasionally, or once `setup-feedback.md` has 10+ open entries.

## First time on a machine

1. Julia ≥1.10 on PATH (`juliaup`), then `julia --project=. -e "using Pkg; Pkg.instantiate()"`.
2. A Python 3.9+ interpreter on PATH — the agent hooks are Python scripts (stdlib only, no
   `.venv` needed). Without one they fail silently: no `STATE.md` injection, no
   `.git/agent-hooks.log`.
3. Open the repo in VS Code, start an agent chat, and check that the first answer knows the
   project state (SessionStart hook worked).
4. Run `/probe-environment`.

## Reusing this in another repo

See `TRANSFER-SETUP.md`.
